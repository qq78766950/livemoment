import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 一次转换的产物：一对互相配对的文件 + 配对标识。
///
/// 必须满足 `Hashable`：EditorView 用 `navigationDestination(item:)` 推结果页，
/// 而那个 API 要求绑定值是可哈希的。
struct BuiltLivePhoto: Identifiable, Hashable {
    /// 同时写入照片 MakerNote 与视频 QuickTime 元数据的配对标识，两边必须完全一致。
    let identifier: String
    /// 静态主图。扩展名跟着 `stillFormat` 走，可能是 HEIC 也可能是 JPG。
    let photoURL: URL
    /// 静态主图**实际**落盘的编码格式。用户偏好不一定被满足，见 `stillFallbackReason`。
    let stillFormat: StillImageFormat
    /// 配对标识是否已确认写进主图文件。为 false 时配对可能失效。
    let identifierVerified: Bool
    /// 主图格式发生过回退（或标识写入失败）时的说明，正常情况为 nil。
    let stillFallbackReason: String?
    /// 动态部分（HEVC / MOV）。
    let videoURL: URL
    let pixelSize: CGSize
    /// 成品动态时长（已计入变速）。
    let duration: Double
    /// 成品使用的播放倍速。
    let speed: Double
    /// 变速前截取的源片段长度。
    let sourceDuration: Double
    let videoFileSize: Int

    var id: String { identifier }

    var resolutionText: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    var fileSizeText: String { Formatters.fileSize(videoFileSize) }

    /// 只有真正变速过才值得在结果页单独列一行。
    var isRetimed: Bool { abs(speed - 1.0) > 0.001 }
}

enum LivePhotoError: LocalizedError {
    case noVideoTrack
    case exportSessionUnavailable
    case exportFailed(String)
    case imageWriteFailed
    case photoLibraryDenied
    case saveFailed(String)
    case exportFolderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "找不到可用的视频轨道。"
        case .exportSessionUnavailable:
            return "当前设备无法转码这个视频，换一段试试。"
        case .exportFailed(let message):
            return "视频转码失败：\(message)"
        case .imageWriteFailed:
            return "封面图写入失败。"
        case .photoLibraryDenied:
            return "没有相册写入权限，请到「设置 → 隐私 → 照片」里允许后重试。"
        case .saveFailed(let message):
            return "保存到相册失败：\(message)"
        case .exportFolderFailed(let message):
            return "导出目录创建失败：\(message)"
        }
    }
}

/// 视频 → 实况照片的核心引擎。
///
/// 关键点在于：实况照片不是一个新格式，而是「一张图 + 一段视频 + 一对相同的配对标识」。
/// - 照片侧写进 Apple MakerNote 标签 17（0x0011），也就是 kCGImagePropertyMakerAppleDictionary 的 "17" 键；
/// - 视频侧写进 QuickTime 元数据 com.apple.quicktime.content.identifier；
/// - 两侧 UUID 一致，系统才会把它们当成同一张实况照片。
///
/// 静态主图可以写成 HEIC 或 JPEG 两种，具体由 `StillImageFormat` 决定，
/// 编码与「标识是否真的写进去了」的回读校验都交给 `StillImageWriter`。
/// 视频侧永远是 HEVC / MOV，不受主图格式影响——苹果并不接受把动图塞进 HEIF 那一套。
///
/// 保存到相册时之所以还能用 PHAssetCreationRequest 直接配对，是因为 iOS 会读取
/// 这两个文件里的标识自行完成绑定，所以这一步不能省。
///
/// 变速的处理方式和播放器不同：预览阶段靠 `AVPlayer.rate`，
/// 而成品必须把时间轴真正改写掉，所以这里走 `scaleTimeRange`，
/// 再配一条 `audioTimePitchAlgorithm = .spectral` 的音频轨做到变速不变调。
final class LivePhotoBuilder {
    static let shared = LivePhotoBuilder()

    private let root: URL

    private init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveMomentWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
    }

    // MARK: - 对外入口

    func build(
        sourceURL: URL,
        selection: ClipSelection,
        coverTime: Double,
        keepAudio: Bool,
        stillFormat: StillImageFormat
    ) async throws -> BuiltLivePhoto {
        let folder = try makeWorkFolder()
        let identifier = UUID().uuidString

        // 1) 抽封面帧。尺寸取视频原生分辨率，保证与视频轨道一致。
        let info = try await VideoLoader.info(for: sourceURL)
        let longest = max(info.displaySize.width, info.displaySize.height)
        let cover = try await VideoLoader.coverImage(
            for: sourceURL,
            at: coverTime,
            maxPixelSize: longest
        )

        // 2) 写静态主图。格式由 StillImageWriter 决定并负责回读校验，
        //    写不进配对标识时会自动换另一种格式重来。
        let still = try StillImageWriter.write(
            cover,
            identifier: identifier,
            preferring: stillFormat,
            in: folder
        )

        // 3) 裁剪 + 变速 + 转码为 HEVC / MOV，并写入同一个配对标识。
        let videoURL = folder.appendingPathComponent("LiveMoment.MOV")
        let written = try await exportMovie(
            sourceURL: sourceURL,
            selection: selection,
            keepAudio: keepAudio,
            identifier: identifier,
            to: videoURL
        )

        let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        let videoSize = (attributes?[.size] as? Int) ?? 0

        return BuiltLivePhoto(
            identifier: identifier,
            photoURL: still.url,
            stillFormat: still.format,
            identifierVerified: still.identifierVerified,
            stillFallbackReason: still.fallbackReason,
            videoURL: videoURL,
            pixelSize: CGSize(width: cover.width, height: cover.height),
            duration: written.outputDuration,
            speed: written.speed,
            sourceDuration: written.sourceDuration,
            videoFileSize: videoSize
        )
    }

    /// 转换完成后清理这一次的临时目录。
    func cleanUp(after result: BuiltLivePhoto) {
        let folder = result.photoURL.deletingLastPathComponent()
        guard folder.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - 工作目录

    private func makeWorkFolder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - 视频裁剪 + 变速 + 转码（含 QuickTime 元数据）

    /// 实际写进文件的时长参数，回传给调用方填进结果对象。
    private struct WrittenMovie {
        let sourceDuration: Double
        let outputDuration: Double
        let speed: Double
    }

    private func exportMovie(
        sourceURL: URL,
        selection: ClipSelection,
        keepAudio: Bool,
        identifier: String,
        to outputURL: URL
    ) async throws -> WrittenMovie {
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let composition = AVMutableComposition()

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivePhotoError.noVideoTrack
        }

        // 选区理论上一定落在素材内，但时长元数据偶尔比实际可解码内容长一点，
        // 这里再夹一次，避免 insertTimeRange 直接抛错把整个转换带崩。
        let assetSeconds = try await asset.load(.duration).seconds
        let range: CMTimeRange
        if assetSeconds.isFinite, assetSeconds > 0 {
            range = selection.timeRange.intersection(
                CMTimeRange(start: .zero, duration: CMTime(seconds: assetSeconds, preferredTimescale: 600))
            )
        } else {
            range = selection.timeRange
        }
        guard range.duration.seconds > 0.05 else { throw LivePhotoError.noVideoTrack }

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LivePhotoError.noVideoTrack
        }

        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        // 旋转信息必须带到合成轨上，否则竖屏素材会被压成横向
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var audioTrack: AVMutableCompositionTrack?
        if keepAudio,
           let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? track.insertTimeRange(range, of: sourceAudio, at: .zero)
            if track.timeRange.duration.seconds > 0.01 {
                audioTrack = track
            }
        }

        // MARK: 变速
        //
        // scaleTimeRange 把「时间轴上的这一段」压缩或拉伸到目标长度，
        // 也就是把 30 fps 的 6 秒素材变成 60 fps 等效的 3 秒，而不是丢帧。
        // 合成轨不会自动继承这个变换，视频轨和音频轨都得单独调用一次。
        let factor = ClipSelection.normalizedSpeed(selection.speed)
        let isRetimed = abs(factor - 1.0) > 0.001
        let targetDuration = CMTime(seconds: selection.outputDuration, preferredTimescale: 600)

        if isRetimed {
            if videoTrack.timeRange.duration.seconds > 0.01 {
                videoTrack.scaleTimeRange(videoTrack.timeRange, toDuration: targetDuration)
            }
            if let audioTrack, audioTrack.timeRange.duration.seconds > 0.01 {
                audioTrack.scaleTimeRange(audioTrack.timeRange, toDuration: targetDuration)
            }
        }

        // 优先 HEVC（实况照片的推荐编码），拿不到会话就退回 H.264
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw LivePhotoError.exportSessionUnavailable
        }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        // 必须是 MOV 容器：Photos 只接受 .mov 作为 pairedVideo
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false
        session.metadata = [Self.contentIdentifierItem(identifier)]
        // 变速时开启频谱相位声码器，慢放不闷、快放不尖
        if isRetimed {
            session.audioMix = Self.pitchPreservingMix(for: audioTrack)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return WrittenMovie(
                sourceDuration: range.duration.seconds,
                outputDuration: selection.outputDuration,
                speed: factor
            )
        case .cancelled:
            throw CancellationError()
        default:
            throw LivePhotoError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }
    }

    /// 变速不变调：不挂这个的话，2× 快放会变成尖细的“花栗鼠音”，
    /// 0.5× 慢放会变成沉闷的“怪兽音”。
    private static func pitchPreservingMix(for track: AVMutableCompositionTrack?) -> AVAudioMix? {
        guard let track else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = .spectral
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// 构造 `com.apple.quicktime.content.identifier` 元数据项。
    ///
    /// 用 rawValue 而不是 `AVMetadataIdentifier.quickTimeMetadataContentIdentifier`，
    /// 是为了不受 SDK 可用性差异影响，两种写法等价。
    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.content.identifier")
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }
}
