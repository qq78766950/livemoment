import CoreMedia
import Foundation

/// 用户在时间轴上选定的一段素材区间，以及这段素材的播放倍速。
///
/// 这里把「倍速」放进选区，是因为它同时决定了两件事：
/// - 播放感受：快放让动作更利落，慢放让细节看得清；
/// - 输出时长：实况照片的动态时长 = 源片段长度 ÷ 倍速。
///
/// 于是「想在 3 秒里装进 6 秒的动作」就有了正经解法——选 6 秒素材、开 2× 快放，
/// 而不是硬砍掉一半内容。
struct ClipSelection: Equatable {

    // MARK: - 约束

    /// 输出到实况照片里的时长上限。
    ///
    /// 系统原生实况照片是「按下快门前后的 1.5 秒」（合计约 3 秒）。
    /// 3 秒以上的动态在部分第三方相册/社交 App 里会被当成普通视频，
    /// 但系统相册本身能放，所以这里放到 5 秒，由用户自己权衡。
    static let maxOutputDuration: Double = 5.0
    static let minOutputDuration: Double = 0.5
    /// 源片段的绝对上限，避免一口气选走整段长视频再极限加速。
    static let maxSourceDuration: Double = 20.0
    /// 源片段的绝对下限：再短就抽不出有意义的动态了。
    static let minSourceDuration: Double = 0.4

    /// 系统原生实况照片的惯例时长，超过就提示一句。
    static let nativeDuration: Double = 3.0

    static let minSpeed: Double = 0.5
    static let maxSpeed: Double = 2.0
    /// 可选的播放倍速档位。
    static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]
    /// 「目标输出时长」快捷档位。
    static let outputPresets: [Double] = [1.0, 2.0, 3.0, 5.0]

    // MARK: - 状态

    /// 选区起点（秒，相对原视频）。
    var start: Double
    /// 源片段长度（秒）。
    var duration: Double
    /// 播放倍速。> 1 快放（输出更短），< 1 慢放（输出更长）。
    var speed: Double = 1.0

    var end: Double { start + duration }

    /// 这段素材最终在实况照片里占用的时长。
    var outputDuration: Double {
        let factor = Self.normalizedSpeed(speed)
        return duration / factor
    }

    /// 当前倍速下源片段允许的最大长度：既不能超过源素材上限，
    /// 也要保证压缩后的输出不超过实况照片的时长上限。
    var sourceLimit: Double {
        min(Self.maxSourceDuration, Self.maxOutputDuration * Self.normalizedSpeed(speed))
    }

    /// 转成 AVFoundation 使用的时间区间，时间基 600 与 QuickTime 对齐。
    var timeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    // MARK: - 约束与变换

    /// 把倍速收进合法区间，顺手挡掉 NaN / 0 这类脏值。
    static func normalizedSpeed(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1.0 }
        return min(max(value, minSpeed), maxSpeed)
    }

    /// 约束到合法范围：不越界、源片段不超过上限、输出时长不超过上限。
    func clamped(totalDuration: Double) -> ClipSelection {
        let factor = Self.normalizedSpeed(speed)

        guard totalDuration > Self.minSourceDuration else {
            return ClipSelection(start: 0, duration: max(totalDuration, 0.1), speed: factor)
        }

        let upper = min(totalDuration, min(Self.maxSourceDuration, Self.maxOutputDuration * factor))
        var length = min(max(duration.isFinite ? duration : Self.minSourceDuration, Self.minSourceDuration), upper)
        var origin = min(max(start.isFinite ? start : 0, 0), totalDuration - length)
        if origin < 0 { origin = 0 }
        // 二次修正：夹取起点后长度可能超出剩余部分
        if origin + length > totalDuration {
            length = max(totalDuration - origin, min(Self.minSourceDuration, upper))
        }
        return ClipSelection(start: origin, duration: length, speed: factor)
    }

    /// 保持起点不变，按「目标输出时长」反推需要多长的源片段。
    ///
    /// 输出时长越短，需要的源素材越少；倍速越高，同样的输出时长能装进更多源素材。
    func resized(toOutputDuration target: Double, totalDuration: Double) -> ClipSelection {
        let factor = Self.normalizedSpeed(speed)
        let wanted = min(max(target, Self.minOutputDuration), Self.maxOutputDuration) * factor
        var next = self
        next.speed = factor
        next.duration = wanted
        return next.clamped(totalDuration: totalDuration)
    }

    /// 微调输出时长（±0.1 秒）。
    func nudgingOutputDuration(by delta: Double, totalDuration: Double) -> ClipSelection {
        resized(toOutputDuration: outputDuration + delta, totalDuration: totalDuration)
    }

    /// 以视频中心为基准生成默认选区。
    static func centered(totalDuration: Double, preferred: Double, speed: Double = 1.0) -> ClipSelection {
        let factor = normalizedSpeed(speed)
        let wanted = preferred * factor
        return ClipSelection(start: 0, duration: wanted, speed: factor)
            .clamped(totalDuration: totalDuration)
            .repositionedToCenter(totalDuration: totalDuration)
    }

    private func repositionedToCenter(totalDuration: Double) -> ClipSelection {
        let origin = max(0, (totalDuration - duration) / 2)
        return ClipSelection(start: origin, duration: duration, speed: speed)
    }
}
