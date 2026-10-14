import CoreMedia
import Foundation

/// 用户在时间轴上选定的一段素材区间。
///
/// 实况照片的惯例是「按下快门前后的 1.5 秒」，也就是 3 秒上限，
/// 因此这里把上限固化为 3 秒，下限取 0.5 秒以保证还能看出动态。
struct ClipSelection: Equatable {
    static let maxDuration: Double = 3.0
    static let minDuration: Double = 0.5

    /// 选区起点（秒，相对原视频）。
    var start: Double
    /// 选区长度（秒）。
    var duration: Double

    var end: Double { start + duration }

    /// 转成 AVFoundation 使用的时间区间，时间基 600 与 QuickTime 对齐。
    var timeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    /// 约束到合法范围：不越界、不超过 3 秒、不短于 0.5 秒。
    func clamped(totalDuration: Double) -> ClipSelection {
        guard totalDuration > Self.minDuration else {
            return ClipSelection(start: 0, duration: max(totalDuration, 0.1))
        }
        var length = min(max(duration, Self.minDuration), Self.maxDuration)
        length = min(length, totalDuration)
        var origin = min(max(start, 0), totalDuration - length)
        if origin < 0 { origin = 0 }
        // 二次修正：夹取起点后长度可能超出剩余部分
        if origin + length > totalDuration {
            length = max(totalDuration - origin, Self.minDuration)
        }
        return ClipSelection(start: origin, duration: length)
    }

    /// 以视频中心为基准生成默认选区。
    static func centered(totalDuration: Double, preferred: Double) -> ClipSelection {
        ClipSelection(start: 0, duration: preferred).clamped(totalDuration: totalDuration)
            .repositionedToCenter(totalDuration: totalDuration)
    }

    private func repositionedToCenter(totalDuration: Double) -> ClipSelection {
        let origin = max(0, (totalDuration - duration) / 2)
        return ClipSelection(start: origin, duration: duration)
    }
}
