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

    // MARK: - 壁纸模式

    /// 是否按壁纸模式生成（输出被钉在 550/600 秒 + 时间基 600 + 封面帧标记）。
    let isWallpaper: Bool
    /// 壁纸后处理是否真的完成了。为 false 时成品仍是一张可用的实况照片，只是未必能当壁纸。
    let wallpaperApplied: Bool
    /// 壁纸后处理的说明，正常为 nil。
    let wallpaperNote: String?

    // MARK: - 跨平台

    /// 封面帧在成品时间轴上的位置（秒）。
    ///
    /// 安卓动态照片要把它写成微秒时间戳（告诉对方「这张静图对应视频里的哪一刻」），
    /// 壁纸模式的 still-image-time 也用它。变速之后它和源时间轴已经不是一个坐标系，
    /// 所以由引擎按段累加算好再带出来。
    let stillTimeInOutput: Double

    var id: String { identifier }

    var resolutionText: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    var fileSizeText: String { Formatters.fileSize(videoFileSize) }

    /// 只有真正变速过才值得在结果页单独列一行。
    var isRetimed: Bool { abs(speed - 1.0) > 0.001 }

    /// 安卓动态照片 XMP 里的呈现时间戳（微秒）。
    var androidPresentationTimestampUs: Int64 {
        Int64((max(0, stillTimeInOutput) * 1_000_000).rounded())
    }
}

enum LivePhotoError: LocalizedError {
    case noVideoTrack
    case exportSessionUnavailable
    case exportFailed(String)
    case imageWriteFailed
    case photoLibraryDenied
    case saveFailed(String)
    case exportFolderFailed(String)
    case notRecorded

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
        case .notRecorded:
            return "还没有录制内容。"
        }
    }
}

/// 视频 → 实况照片的核心引擎。
///
/// 关键点在于：实况照片不是一个新格式，而是「一张图 + 一段视频 + 一对相同的配对标识」。
/// - 照片侧写进 Apple MakerNote 标签 17（0x0011），也就是 kCGImagePropertyMakerAppleDictionary 的 "17" 键；
/// - 视频侧写进 QuickTime 元数据 `com.apple.quicktime.content.identifier`；
/// - 两侧 UUID 一致，系统才会把它们当成同一张实况照片。
///
/// 静态主图可以写成 HEIC 或 JPEG 两种，具体由 `StillImageFormat` 决定，
/// 编码与「标识是否真的写进去了」的回读校验都交给 `StillImageWriter`。
/// 视频侧永远是 HEVC / MOV，不受主图格式影响——苹果并不接受把动图塞进 HEIF 那一套。
///
/// 时间轴的处理分三层，依次叠加：
/// 1. **逐段裁切 + 逐段缩放**（`ClipSelection.timelineSegments()`）——
///    匀速时只有一段，与引入分段变速之前完全同路；分段变速时每段一个倍速。
/// 2. **壁纸模式归一化**——把整段显式钉到 550/600 秒。逐段缩放理论上已经能得到这个
///    时长（壁纸模式的单段倍速就是反推出来的），但 CMTime 在 600 时间基上取整会差
///    一两个 tick，而 iOS 的判定是精确比对，所以再归一化一次。
/// 3. **重封装**（`WallpaperFinisher`）——只有壁纸模式才做，用来把时间基压到 600
///    并写入 `still-image-time` 时间元数据轨。
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

        let info = try await VideoLoader.info(for: sourceURL)
        let frameInterval = info.frameRate > 0 ? 1.0 / Double(info.frameRate) : 1.0 / 30.0

        // 壁纸模式的封面帧固定在片段**末尾**。
        //
        // 原因是 iOS 播放壁纸时只播「关键帧之前」的那一小段，关键帧标记在哪儿，
        // 画面就从哪儿停住。把关键帧放在末尾，整段 0.9167 秒才播得出来。
        let stillSourceTime = selection.isWallpaper
            ? max(selection.start, selection.end - frameInterval)
            : coverTime

        // 封面帧在**成品**时间轴上的位置。变速之后它和源时间轴不是一个坐标系，
        // 所以统一在这里按段累加算一次：安卓导出的呈现时间戳、壁纸的封面帧标记都用它。
        let stillTimeInOutput = selection.outputTime(forOffset: stillSourceTime - selection.start)

        // 1) 抽封面帧。尺寸取视频原生分辨率，保证与视频轨道一致。
        let longest = max(info.displaySize.width, info.displaySize.height)
        let cover = try await VideoLoader.coverImage(
            for: sourceURL,
            at: stillSourceTime,
            maxPixelSize: longest
        )

        // 2) 写静态主图。壁纸模式强制 HEIC——真实拍摄的实况照片就是 HEIC，
        //    判定壁纸资格时它最稳；写不进去时 StillImageWriter 会自动回退到 JPEG 并说明。
        let wantedFormat: StillImageFormat = selection.isWallpaper ? .heic : stillFormat
        let still = try StillImageWriter.write(
            cover,
            identifier: identifier,
            preferring: wantedFormat,
            in: folder
        )

        // 3) 裁剪 + 分段变速 + 转码为 HEVC / MOV，并写入同一个配对标识。
        let videoURL = folder.appendingPathComponent("LiveMoment.MOV")
        let written = try await exportMovie(
            sourceURL: sourceURL,
            selection: selection,
            keepAudio: keepAudio,
            identifier: identifier,
            to: videoURL
        )

        // 4) 壁纸模式再做一次重封装。失败不致命——成品仍然是一张可用的实况照片，
        //    只是未必能被 iOS 认成壁纸，所以只记一句说明，不往上抛。
        var finalVideoURL = videoURL
        var wallpaperApplied = false
        var wallpaperNote: String?

        if selection.isWallpaper {
            let rewritten = folder.appendingPathComponent("LiveMoment-Wallpaper.MOV")
            do {
                let finished = try await WallpaperFinisher.apply(
                    sourceURL: videoURL,
                    outputURL: rewritten,
                    stillTime: stillTimeInOutput,
                    metadata: Self.metadataItems(identifier: identifier, isWallpaper: true)
                )
                finalVideoURL = finished.url
                wallpaperApplied = true
                wallpaperNote = finished.note
            } catch {
                wallpaperNote = "壁纸后处理没做完（\(error.localizedDescription)），已保留成普通实况照片。"
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: finalVideoURL.path)
        let videoSize = (attributes?[.size] as? Int) ?? 0

        return BuiltLivePhoto(
            identifier: identifier,
            photoURL: still.url,
            stillFormat: still.format,
            identifierVerified: still.identifierVerified,
            stillFallbackReason: still.fallbackReason,
            videoURL: finalVideoURL,
            pixelSize: CGSize(width: cover.width, height: cover.height),
            duration: written.outputDuration,
            speed: selection.displaySpeed,
            sourceDuration: written.sourceDuration,
            videoFileSize: videoSize,
            isWallpaper: selection.isWallpaper,
            wallpaperApplied: wallpaperApplied,
            wallpaperNote: wallpaperNote,
            stillTimeInOutput: stillTimeInOutput
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

    // MARK: - 视频裁剪 + 分段变速 + 转码（含 QuickTime 元数据）

    /// 实际写进文件的时长参数，回传给调用方填进结果对象。
    private struct WrittenMovie {
        let sourceDuration: Double
        let outputDuration: Double
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

        // 时长元数据偶尔比实际可解码内容长一点，逐段插入前会再夹一次，
        // 避免 insertTimeRange 直接抛错把整个转换带崩。
        let assetSeconds = try await asset.load(.duration).seconds

        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let wantsAudio = keepAudio && sourceAudio != nil

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LivePhotoError.noVideoTrack
        }

        // 匀速时这里只有一段，行为与引入分段变速之前完全一致
        let segments = selection.timelineSegments()
        let isRetimed = segments.contains { abs($0.speed - 1.0) > 0.001 }

        var videoCursor = CMTime.zero
        var videoTotal = 0.0

        for segment in segments {
            guard let range = clampedRange(
                start: selection.start + segment.offset,
                duration: segment.duration,
                assetSeconds: assetSeconds
            ) else { continue }

            let target = CMTime(
                seconds: range.duration.seconds / max(segment.speed, 0.01),
                preferredTimescale: 600
            )

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: videoCursor)
            // scaleTimeRange 把「时间轴上的这一段」压缩或拉伸到目标长度，
            // 也就是把 30 fps 的 6 秒素材变成 60 fps 等效的 3 秒，而不是丢帧。
            videoTrack.scaleTimeRange(
                CMTimeRange(start: videoCursor, duration: range.duration),
                toDuration: target
            )
            videoCursor = CMTimeAdd(videoCursor, target)
            videoTotal += target.seconds
        }

        guard videoTotal > 0.05 else { throw LivePhotoError.noVideoTrack }

        // 旋转信息必须带到合成轨上，否则竖屏素材会被压成横向
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        // MARK: 音频
        //
        // 用同一套分段各跑一遍。合成轨**不会**把变速从视频轨继承过来，
        // 少做一次就会出现「画面快放了声音没变」的错位。
        var audioTrack: AVMutableCompositionTrack?
        if wantsAudio, let sourceAudio,
           let track = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            var cursor = CMTime.zero
            for segment in segments {
                guard let range = clampedRange(
                    start: selection.start + segment.offset,
                    duration: segment.duration,
                    assetSeconds: assetSeconds
                ) else { continue }

                let target = CMTime(
                    seconds: range.duration.seconds / max(segment.speed, 0.01),
                    preferredTimescale: 600
                )
                let before = track.timeRange.duration
                // 音轨可能比视频短，插入失败就跳过这一段，别把整条轨道废掉
                try? track.insertTimeRange(range, of: sourceAudio, at: cursor)
                let inserted = CMTimeSubtract(track.timeRange.duration, before)
                if inserted.seconds > 0.01 {
                    track.scaleTimeRange(
                        CMTimeRange(start: cursor, duration: inserted),
                        toDuration: target
                    )
                }
                cursor = CMTimeAdd(cursor, target)
            }

            if track.timeRange.duration.seconds > 0.01 {
                audioTrack = track
            } else {
                composition.removeTrack(track)
            }
        }

        // MARK: 壁纸模式归一化
        //
        // 逐段缩放理论上已经能得到 550/600 秒（壁纸模式的单段倍速就是反推出来的），
        // 但 CMTime 在 600 时间基上取整会差一两个 tick，而 iOS 的判定是精确比对。
        // 所以这里对整段再显式归一化一次，把误差清零。
        if selection.isWallpaper {
            let pinned = CMTime(value: 550, timescale: 600)
            if videoTrack.timeRange.duration.seconds > 0.01 {
                videoTrack.scaleTimeRange(videoTrack.timeRange, toDuration: pinned)
            }
            if let audioTrack, audioTrack.timeRange.duration.seconds > 0.01 {
                audioTrack.scaleTimeRange(audioTrack.timeRange, toDuration: pinned)
            }
            videoTotal = pinned.seconds
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
        session.metadata = Self.metadataItems(identifier: identifier, isWallpaper: selection.isWallpaper)
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
                sourceDuration: selection.duration,
                outputDuration: videoTotal
            )
        case .cancelled:
            throw CancellationError()
        default:
            throw LivePhotoError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }
    }

    /// 把一段区间夹进素材的真实时间范围。
    private func clampedRange(start: Double, duration: Double, assetSeconds: Double) -> CMTimeRange? {
        let requested = CMTimeRange(
            start: CMTime(seconds: max(0, start), preferredTimescale: 600),
            duration: CMTime(seconds: max(0, duration), preferredTimescale: 600)
        )
        guard assetSeconds.isFinite, assetSeconds > 0 else {
            return requested.duration.seconds > 0.05 ? requested : nil
        }
        let available = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: assetSeconds, preferredTimescale: 600)
        )
        let clipped = requested.intersection(available)
        return clipped.duration.seconds > 0.02 ? clipped : nil
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

    // MARK: - 元数据

    /// 写进视频的 QuickTime 元数据。
    ///
    /// 用 rawValue 而不是 `AVMetadataIdentifier.quickTimeMetadataContentIdentifier`，
    /// 是为了不受 SDK 可用性差异影响，两种写法等价。
    private static func metadataItems(identifier: String, isWallpaper: Bool) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [contentIdentifierItem(identifier)]
        guard isWallpaper else { return items }

        // 真实拍摄的实况照片在 moov/meta 里一定带着这三个字段，转换出来的文件默认没有。
        // 它们是「这段动态是相机拍的、可以动」的佐证，壁纸判定会看。
        let auto = AVMutableMetadataItem()
        auto.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.live-photo.auto")
        auto.keySpace = .quickTimeMetadata
        auto.value = NSNumber(value: Int8(1))
        auto.dataType = "com.apple.metadata.datatype.int8"
        items.append(auto)

        let vitality = AVMutableMetadataItem()
        vitality.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.live-photo.vitality-score")
        vitality.keySpace = .quickTimeMetadata
        vitality.value = NSNumber(value: Float(1.0))
        vitality.dataType = "com.apple.metadata.datatype.float32"
        items.append(vitality)

        let version = AVMutableMetadataItem()
        version.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.live-photo.vitality-scoring-version")
        version.keySpace = .quickTimeMetadata
        version.value = NSNumber(value: Int64(4))
        version.dataType = "com.apple.metadata.datatype.int64"
        items.append(version)

        return items
    }

    /// 构造 `com.apple.quicktime.content.identifier` 元数据项。
    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.content.identifier")
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }
}
