import AVFoundation
import Combine
import Foundation

/// 只负责播放「选中片段」并在片段内循环的小播放器。
///
/// 编辑器里用户关心的是这一小段长什么样，所以整段视频的播放没有意义，
/// 这个类会在播放越过选区终点时自动跳回起点，做出实况照片「按压循环」的感觉。
///
/// 倍速在这里是**预览**用的：它让用户在按下「生成」之前就能看到快放/慢放的实际观感。
/// 真正写进成品的变速由 `LivePhotoBuilder` 通过 scaleTimeRange 完成。
final class LoopingPlayer: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    /// 当前预览倍速，1.0 为原速。
    @Published private(set) var rate: Float = 1.0

    private var timeObserver: Any?
    private var range: CMTimeRange = .zero

    init() {
        player.actionAtItemEnd = .pause
        player.isMuted = true
        // defaultRate 让播放器在缓冲、跳转之后自动恢复到这个速率；
        // 只设 rate 的话，一次 seek 就会把它打回 1.0。
        if #available(iOS 16.0, *) {
            player.defaultRate = 1.0
        }
        addTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 装载

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        isPlaying = false
        currentTime = 0
    }

    func updateRange(_ range: CMTimeRange, seekToStart: Bool = true) {
        self.range = range
        if seekToStart {
            seek(to: range.start.seconds)
        }
    }

    // MARK: - 播放控制

    func play() {
        guard player.currentItem != nil else { return }
        if range.duration.seconds > 0, !range.containsTime(player.currentTime()) {
            seek(to: range.start.seconds)
        }
        player.play()
        // play() 之后必须重新交代速率，否则会退回 1.0
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// 设置预览倍速。
    func setRate(_ value: Float) {
        let clamped = min(max(value.isFinite ? value : 1.0, 0.25), 4.0)
        guard abs(clamped - rate) > 0.0001 else { return }
        rate = clamped
        if #available(iOS 16.0, *) {
            player.defaultRate = clamped
        }
        if isPlaying {
            player.rate = clamped
        }
    }

    /// 跳转。`precise = false` 用于拖动时间轴时的高频跟随——
    /// 零容差的精确 seek 每次都要解到关键帧再解到目标帧，拖起来会明显卡顿。
    func seek(to seconds: Double, precise: Bool = true) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.06, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = max(0, seconds)
    }

    /// 拖动时间轴时的即时预览：先暂停，再低延迟跟随。
    func scrub(to seconds: Double, minimumDelta: Double = 0.03) {
        pause()
        guard abs(seconds - currentTime) >= minimumDelta else { return }
        seek(to: seconds, precise: false)
    }

    /// 从头循环预览当前选区。
    func replayRange() {
        if range.duration.seconds > 0 {
            seek(to: range.start.seconds)
        }
        play()
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    // MARK: - 时间观察

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            let end = self.range.end.seconds
            let start = self.range.start.seconds
            guard self.range.duration.seconds > 0, self.isPlaying else { return }
            if time.seconds >= end - 0.04 || time.seconds < start - 0.04 {
                let target = self.range.start
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                // 跳回起点后立刻恢复速率，避免快放/慢放在循环处丢失
                self.player.rate = self.rate
            }
        }
    }
}
