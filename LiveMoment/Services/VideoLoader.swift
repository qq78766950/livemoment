import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// 源视频的基本信息。
struct VideoInfo {
    let url: URL
    /// 总时长（秒）。
    let duration: Double
    /// 应用了旋转信息之后的显示尺寸。
    let displaySize: CGSize
    let frameRate: Float
    let hasAudio: Bool

    var resolutionText: String {
        "\(Int(displaySize.width)) × \(Int(displaySize.height))"
    }
}

enum VideoLoaderError: LocalizedError {
    case noVideoTrack
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "这个文件里没有找到视频轨道，换一个视频试试。"
        case .invalidDuration:
            return "视频时长异常，无法处理。"
        }
    }
}

/// 负责读取视频信息、生成时间轴缩略图、抽取任意帧作为封面。
enum VideoLoader {

    // MARK: - 基础信息

    static func info(for url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.2 else { throw VideoLoaderError.invalidDuration }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoLoaderError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // 竖屏视频的 naturalSize 是横向的，必须叠加 preferredTransform 才是真实显示尺寸
        let transformed = naturalSize.applying(transform)
        let display = CGSize(
            width: abs(transformed.width).rounded(),
            height: abs(transformed.height).rounded()
        )

        return VideoInfo(
            url: url,
            duration: duration,
            displaySize: display.width > 0 && display.height > 0 ? display : naturalSize,
            frameRate: frameRate > 0 ? frameRate : 30,
            hasAudio: !audioTracks.isEmpty
        )
    }

    // MARK: - 时间轴缩略图

    /// 沿着整段视频均匀抽 `count` 张缩略图，用于时间轴底图。
    static func timelineThumbnails(for url: URL, count: Int, maxPixelSize: CGFloat) async -> [UIImage] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // 缩略图不需要精确到帧，放宽容差换取速度
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

        var images: [UIImage] = []
        for index in 0..<count {
            let ratio = (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: duration * ratio, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                images.append(UIImage(cgImage: result.image))
            }
        }
        return images
    }

    // MARK: - 抽帧

    /// 抽取指定时刻的帧，作为实况照片的静态主图。
    ///
    /// `appliesPreferredTrackTransform = true` 保证竖屏视频抽出来也是竖的，
    /// 这一点很关键——封面和视频方向不一致的话，实况照片在相册里会歪。
    static func coverImage(for url: URL, at seconds: Double, maxPixelSize: CGFloat) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // 封面帧要准，容差收到一帧以内
        let tolerance = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let result = try await generator.image(at: time)
        return result.image
    }
}
