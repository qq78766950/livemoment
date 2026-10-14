import AVFoundation
import Combine
import Foundation

/// 只负责播放「选中片段」并在片段内循环的小播放器。
///
/// 编辑器里用户关心的是这 3 秒长什么样，所以整段视频的播放没有意义，
/// 这个类会在播放越过选区终点时自动跳回起点，做出实况照片「按压循环」的感觉。
final class LoopingPlayer: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0

    private var timeObserver: Any?
    private var range: CMTimeRange = .zero

    init() {
        player.actionAtItemEnd = .pause
        player.isMuted = true
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
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
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
                self.player.seek(to: self.range.start, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
}
