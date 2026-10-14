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
    /// 静态主图（JPEG）。
    let photoURL: URL
    /// 动态部分（HEVC / MOV）。
    let videoURL: URL
    let pixelSize: CGSize
    let duration: Double
    let videoFileSize: Int

    var id: String { identifier }

    var resolutionText: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    var fileSizeText: String { Formatters.fileSize(videoFileSize) }
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
/// 保存到相册时之所以还能用 PHAssetCreationRequest 直接配对，是因为 iOS 会读取
/// 这两个文件里的标识自行完成绑定，所以这一步不能省。
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
        keepAudio: Bool
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

        let photoURL = folder.appendingPathComponent("LiveMoment.JPG")
        try writeStillImage(cover, identifier: identifier, to: photoURL)

        // 2) 裁剪 + 转码为 HEVC / MOV，并写入同一个配对标识。
        let videoURL = folder.appendingPathComponent("LiveMoment.MOV")
        try await exportMovie(
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
            photoURL: photoURL,
            videoURL: videoURL,
            pixelSize: CGSize(width: cover.width, height: cover.height),
            duration: selection.duration,
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

    // MARK: - 封面图落盘（含配对标识）

    private func writeStillImage(_ image: CGImage, identifier: String, to url: URL, quality: CGFloat = 0.95) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoError.imageWriteFailed
        }

        let stamp = Formatters.exifDate.string(from: Date())
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "LiveMoment"
        ]

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // 抽帧时已经应用过旋转，这里明确写成 1，避免系统再转一次
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            // ★ 实况照片的配对标识就藏在这里：Apple MakerNote 标签 17
            kCGImagePropertyMakerAppleDictionary: ["17": identifier]
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.imageWriteFailed
        }
    }

    // MARK: - 视频裁剪 + 转码（含 QuickTime 元数据）

    private func exportMovie(
        sourceURL: URL,
        selection: ClipSelection,
        keepAudio: Bool,
        identifier: String,
        to outputURL: URL
    ) async throws {
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let composition = AVMutableComposition()

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivePhotoError.noVideoTrack
        }
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LivePhotoError.noVideoTrack
        }

        let range = selection.timeRange
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        // 旋转信息必须带到合成轨上，否则竖屏素材会被压成横向
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if keepAudio,
           let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw LivePhotoError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }
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
