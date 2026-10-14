import AVFoundation
import Foundation
import Photos
import SwiftData
import SwiftUI
import UIKit

/// 编辑器的状态机：装载素材 → 调参数 → 转码 → 写相册。
@MainActor
final class EditorViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case working(String)
        case done(BuiltLivePhoto)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var workingText: String {
            if case .working(let text) = self { return text }
            return ""
        }

        var failureMessage: String {
            if case .failed(let text) = self { return text }
            return ""
        }
    }

    @Published private(set) var info: VideoInfo? = nil
    @Published private(set) var thumbnails: [UIImage] = []
    @Published var selection = ClipSelection(start: 0, duration: 2)
    /// 封面帧相对选区起点的偏移，让用户可以在一段动态里挑选最好看的一帧。
    @Published var coverOffset: Double = 0
    @Published var keepAudio = true

    @Published private(set) var coverPreview: UIImage? = nil
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var libraryIdentifier: String? = nil
    @Published private(set) var saveWarning: String? = nil

    let player = LoopingPlayer()

    /// 显式声明为非隔离，这样 SwiftUI 视图里那句
    /// `@StateObject private var viewModel = EditorViewModel()` 不会踩到主线程隔离诊断。
    nonisolated init() {}

    private var coverTask: Task<Void, Never>?
    /// 上一次的产物，用于在新一轮生成前回收临时文件。
    private var lastBuilt: BuiltLivePhoto?
    private let thumbnailCount = 10

    // MARK: - 派生值

    /// 封面帧在原始视频时间轴上的位置。
    var coverTime: Double {
        let upper = max(selection.start, selection.end - 0.02)
        return min(max(selection.start + coverOffset, selection.start), upper)
    }

    var selectionText: String {
        "\(Formatters.timecode(selection.start)) → \(Formatters.timecode(selection.end))"
    }

    // MARK: - 装载

    func prepare(url: URL, defaultDuration: Double, keepAudioByDefault: Bool) async {
        guard info == nil else { return }
        do {
            let loaded = try await VideoLoader.info(for: url)
            info = loaded
            keepAudio = keepAudioByDefault && loaded.hasAudio
            selection = .centered(totalDuration: loaded.duration, preferred: defaultDuration)
            coverOffset = 0

            player.load(url: url)
            player.setMuted(!keepAudio)
            player.updateRange(selection.timeRange)

            refreshCover()
            player.play()

            let images = await VideoLoader.timelineThumbnails(
                for: url,
                count: thumbnailCount,
                maxPixelSize: 240
            )
            thumbnails = images
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 参数变更

    func selectionDidChange() {
        let clamped = selection.clamped(totalDuration: info?.duration ?? selection.duration)
        if clamped != selection {
            selection = clamped
            return
        }
        coverOffset = min(coverOffset, max(0, selection.duration - 0.05))
        player.updateRange(selection.timeRange, seekToStart: false)
        refreshCover()
    }

    func setKeepAudio(_ value: Bool) {
        keepAudio = value
        player.setMuted(!value)
    }

    func togglePlayback() {
        player.toggle()
    }

    /// 重新抽取封面预览图。拖动时会频繁触发，所以旧的 Task 先取消。
    func refreshCover() {
        coverTask?.cancel()
        guard let url = info?.url else { return }
        let time = coverTime
        coverTask = Task { [weak self] in
            guard let self else { return }
            let image = try? await VideoLoader.coverImage(for: url, at: time, maxPixelSize: 1200)
            if Task.isCancelled { return }
            if let image {
                self.coverPreview = UIImage(cgImage: image)
            }
        }
    }

    // MARK: - 生成

    func build(context: ModelContext) async {
        guard let info, !phase.isWorking else { return }
        player.pause()

        // 回收上一轮的中间产物，避免临时目录越堆越大
        if let lastBuilt {
            LivePhotoBuilder.shared.cleanUp(after: lastBuilt)
            self.lastBuilt = nil
        }

        phase = .working("正在裁剪并转码视频…")

        let job = selection.clamped(totalDuration: info.duration)

        do {
            let result = try await LivePhotoBuilder.shared.build(
                sourceURL: info.url,
                selection: job,
                coverTime: coverTime,
                keepAudio: keepAudio
            )

            phase = .working("正在写入系统相册…")
            var identifier: String?
            var warning: String?
            do {
                identifier = try await PhotoLibraryService.saveLivePhoto(
                    photoURL: result.photoURL,
                    videoURL: result.videoURL
                )
            } catch {
                warning = "实况照片已经生成，但写入相册失败：\(error.localizedDescription)"
            }

            libraryIdentifier = identifier
            saveWarning = warning
            record(result, saved: identifier != nil, identifier: identifier, context: context)
            lastBuilt = result
            phase = .done(result)
        } catch is CancellationError {
            phase = .idle
            player.play()
        } catch {
            phase = .failed(error.localizedDescription)
            player.play()
        }
    }

    private func record(
        _ result: BuiltLivePhoto,
        saved: Bool,
        identifier: String?,
        context: ModelContext
    ) {
        let item = ConvertedItem(
            title: ExportService.makeBaseName(),
            assetIdentifier: result.identifier,
            durationSeconds: result.duration,
            pixelWidth: Int(result.pixelSize.width),
            pixelHeight: Int(result.pixelSize.height),
            keepsAudio: keepAudio,
            savedToLibrary: saved,
            libraryIdentifier: identifier,
            thumbnail: coverPreview?.jpegData(compressionQuality: 0.6)
        )
        context.insert(item)
        try? context.save()
    }

    func reset() {
        phase = .idle
        libraryIdentifier = nil
        saveWarning = nil
        player.play()
    }
}
