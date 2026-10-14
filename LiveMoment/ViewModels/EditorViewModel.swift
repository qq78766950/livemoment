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
    /// 用户是否手动改过倍速——改过之后就不再跟着默认值走。
    @Published private(set) var isRetimed = false

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

    /// 本次输出的动态时长（已计入倍速）。
    var outputDuration: Double { selection.outputDuration }

    /// 当前倍速下源片段的长度上限，时间轴手柄要按它来夹取。
    var sourceLimit: Double { selection.sourceLimit }

    /// 输出超过系统原生实况照片的 3 秒惯例时，给用户一句提醒。
    var exceedsNativeDuration: Bool {
        outputDuration > ClipSelection.nativeDuration + 0.01
    }

    /// 「源 4.0 秒 → 输出 2.0 秒」这类摘要，编辑器和结果页共用同一套口径。
    var durationSummary: String {
        "源 \(Formatters.duration(selection.duration)) → 输出 \(Formatters.duration(outputDuration))"
    }

    // MARK: - 装载

    func prepare(url: URL, defaultDuration: Double, keepAudioByDefault: Bool) async {
        guard info == nil else { return }
        do {
            let loaded = try await VideoLoader.info(for: url)
            info = loaded
            keepAudio = keepAudioByDefault && loaded.hasAudio
            selection = .centered(totalDuration: loaded.duration, preferred: defaultDuration)
            isRetimed = false
            coverOffset = 0

            player.load(url: url)
            player.setMuted(!keepAudio)
            player.setRate(1.0)
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
        // 预览播放器跟着选区的倍速走，用户不用点生成就能看到快放/慢放的实际观感
        player.setRate(Float(clamped.speed))
        if clamped != selection {
            selection = clamped
            // 赋值会再次触发 onChange，交给下一轮跑完整流程，避免半套状态
            return
        }
        coverOffset = min(coverOffset, max(0, selection.duration - 0.05))
        player.updateRange(selection.timeRange, seekToStart: false)
        refreshCover()
    }

    /// 调整播放倍速。**保持源片段不变**，让输出时长随之变化——
    /// 用户调倍速时心里想的是「这段动作太快/太慢」，而不是总时长。
    func setSpeed(_ value: Double) {
        var next = selection
        next.speed = ClipSelection.normalizedSpeed(value)
        guard next.speed != selection.speed else { return }
        isRetimed = abs(next.speed - 1.0) > 0.001
        selection = next.clamped(totalDuration: info?.duration ?? next.duration)
        previewSelection()
    }

    /// 按目标输出时长反推源片段长度（起点不变，尽量往后取）。
    func setOutputDuration(_ target: Double) {
        guard let info else { return }
        selection = selection.resized(toOutputDuration: target, totalDuration: info.duration)
        previewSelection()
    }

    /// 微调输出时长，步进 0.1 秒。
    func nudgeOutputDuration(by delta: Double) {
        guard let info else { return }
        selection = selection.nudgingOutputDuration(by: delta, totalDuration: info.duration)
    }

    /// 这个目标输出时长在当前倍速下是否够素材可截。
    func canReach(outputDuration target: Double, in info: VideoInfo) -> Bool {
        target * ClipSelection.normalizedSpeed(selection.speed) <= info.duration + 0.05
    }

    // MARK: - 预览

    /// 从头循环播放当前选区。
    func previewSelection() {
        player.updateRange(selection.timeRange)
        player.replayRange()
    }

    /// 拖动时间轴时的即时预览：先暂停，再低延迟跟随。
    ///
    /// 这是「边选边看」的关键——拖动过程中播放器停在目标帧上，
    /// 用户能直接看到边界落在哪一帧，而不是松手之后才播。
    func previewFrame(at sourceTime: Double) {
        player.scrub(to: clampedSourceTime(sourceTime), minimumDelta: 0.03)
    }

    /// 松手后的精确落点：低延迟 seek 会吸附到关键帧附近，
    /// 结束时补一次零容差 seek，保证预览到的就是想截的那一帧。
    func settleFrame(at sourceTime: Double) {
        player.pause()
        player.seek(to: clampedSourceTime(sourceTime), precise: true)
    }

    private func clampedSourceTime(_ value: Double) -> Double {
        let upper = info?.duration ?? value
        guard value.isFinite else { return 0 }
        return min(max(value, 0), max(upper, 0))
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
