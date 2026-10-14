import CoreMedia
import Foundation

/// 用户在时间轴上选定的一段素材，以及这段素材**怎么播**。
///
/// 这里把「倍速」放进选区，是因为它同时决定了两件事：
/// - 播放感受：快放让动作更利落，慢放让细节看得清；
/// - 输出时长：实况照片的动态时长 = 源片段长度 ÷ 等效倍速。
///
/// 于是「想在 3 秒里装进 6 秒的动作」就有了正经解法——选 6 秒素材、开 2× 快放，
/// 而不是硬砍掉一半内容。
///
/// 壁纸模式（`isWallpaper`）是同一套关系的反向用法：输出时长被钉死在
/// 550/600 秒，倍速由源片段长度反推，所以 `displaySpeed` 和 `effectiveSpeed`
/// 是两个不同的值。
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

    /// 壁纸模式要求的输出时长：550/600 秒，即 0.9166666…。
    ///
    /// 这个数字不是凑出来的。iOS 判定一张实况照片能否当锁屏壁纸时，
    /// 要求视频轨时长能在它的时间基上被整除——0.9166666… 只有在时间基 ≥ 600 时
    /// 才是个整数刻度（550 个 tick）。ffmpeg 那条经典命令里的
    /// `-video_track_timescale 600` 与 `trim=duration=0.916667` 说的就是这件事，
    /// 侧写一个就失效。
    static let wallpaperDuration: Double = 550.0 / 600.0

    /// 壁纸模式下源片段的长度上限。
    ///
    /// 输出被钉死之后，源片段越长等效倍速越高：0.9167 秒里塞 4 秒素材 ≈ 4.4×，
    /// 再长就只剩残影了，所以单独设一道上限。
    static let wallpaperMaxSourceDuration: Double = 4.0

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
    /// 匀速播放倍速。> 1 快放（输出更短），< 1 慢放（输出更长）。
    /// 开了分段变速时以 `ramp` 为准，这个值只是「上次用的匀速值」。
    var speed: Double = 1.0
    /// 分段变速配置。为 nil 时整段按 `speed` 匀速。
    var ramp: SpeedRamp? = nil
    /// 壁纸模式：输出时长钉死在 550/600 秒。
    ///
    /// 它与分段变速互斥——两者都要控制时间轴，同时开的话
    /// 「显示出来的倍速」和「实际生效的倍速」会对不上，不如直接不让选。
    var isWallpaper: Bool = false

    var end: Double { start + duration }

    /// 整段的等效倍速（匀速时就是 `speed`）。
    ///
    /// 分段变速下取各段倍速的**调和平均**，理由见 `SpeedRamp` 的注释。
    var effectiveSpeed: Double {
        if let ramp { return ramp.effectiveSpeed }
        return Self.normalizedSpeed(speed)
    }

    /// 成品实际播放的倍速。
    ///
    /// 壁纸模式下时长是固定的，倍速变成「源片段长度 ÷ 0.9167」的结果，
    /// 所以要单独算——直接拿 `effectiveSpeed` 会显示成 1×，与实际不符。
    var displaySpeed: Double {
        guard isWallpaper else { return effectiveSpeed }
        guard duration > 0.01 else { return 1 }
        return duration / Self.wallpaperDuration
    }

    /// 这段素材最终在成品里占用的时长。
    var outputDuration: Double {
        guard !isWallpaper else { return Self.wallpaperDuration }
        return duration / effectiveSpeed
    }

    /// 当前配置下源片段允许的最大长度：不能超过源素材上限，
    /// 也要保证压缩后的输出不超过成品时长上限。
    var sourceLimit: Double {
        guard !isWallpaper else { return Self.wallpaperMaxSourceDuration }
        return min(Self.maxSourceDuration, Self.maxOutputDuration * effectiveSpeed)
    }

    /// 转成 AVFoundation 使用的时间区间，时间基 600 与 QuickTime 对齐。
    var timeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    // MARK: - 分段

    /// 把选区拆成若干「源区间偏移 + 长度 + 该段倍速」的段，供引擎逐段裁切与变速。
    ///
    /// - 壁纸模式：单段，倍速由源长度反推，缩放后正好落在 550/600 秒；
    /// - 分段变速：等分源长度，各段倍速线性过渡；
    /// - 其余情况：单段匀速——与引入分段变速之前的行为**完全一致**，
    ///   引擎走的是同一条路径，不存在「没开这个功能却换了条路」的风险。
    func timelineSegments() -> [(offset: Double, duration: Double, speed: Double)] {
        if isWallpaper {
            let factor = max(0.01, duration / Self.wallpaperDuration)
            return [(0, duration, factor)]
        }
        if let ramp, ramp.isRamping {
            let speeds = ramp.speeds
            let per = duration / Double(speeds.count)
            return speeds.enumerated().map { index, value in
                (Double(index) * per, per, value)
            }
        }
        return [(0, duration, Self.normalizedSpeed(speed))]
    }

    /// 源片段内的偏移量映射到成品时间轴上的位置（秒）。
    ///
    /// 安卓动态照片要把「封面帧对应视频里的哪一刻」写成微秒时间戳，
    /// 而变速之后这个位置和源时间轴已经不是一个坐标系了，必须按段累加换算。
    func outputTime(forOffset offset: Double) -> Double {
        let clamped = min(max(offset, 0), max(duration, 0))
        var cursor = 0.0
        for segment in timelineSegments() {
            let segmentEnd = segment.offset + segment.duration
            if clamped <= segmentEnd {
                return cursor + (clamped - segment.offset) / segment.speed
            }
            cursor += segment.duration / segment.speed
        }
        return cursor
    }

    // MARK: - 预览曲线

    /// 预览用的速度曲线：参数是选区内的归一化进度（0…1），返回该点的倍速。
    ///
    /// 预览播放器按这条曲线实时改 `AVPlayer.rate`，所以「先慢后快」在按下生成
    /// 之前就能看出来、听出来。真正写进成品的分段由 `timelineSegments()` 给出，
    /// 两者用的是同一组数值，不会出现「预览一套、成品另一套」。
    ///
    /// 返回 nil 表示匀速，走原来的单速率路径。
    func previewSpeedProfile() -> ((Double) -> Float)? {
        if isWallpaper {
            let value = Float(displaySpeed)
            return { _ in value }
        }
        guard let ramp, ramp.isRamping else { return nil }
        let speeds = ramp.speeds
        return { progress in
            let clamped = min(max(progress, 0), 0.99999)
            let index = min(Int(clamped * Double(speeds.count)), speeds.count - 1)
            return Float(speeds[index])
        }
    }

    // MARK: - 约束与变换

    /// 把倍速收进合法区间，顺手挡掉 NaN / 0 这类脏值。
    static func normalizedSpeed(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1.0 }
        return min(max(value, minSpeed), maxSpeed)
    }

    /// 约束到合法范围：不越界、源片段不超过上限、输出时长不超过上限。
    func clamped(totalDuration: Double) -> ClipSelection {
        let limit = sourceLimit

        guard totalDuration > Self.minSourceDuration else {
            return ClipSelection(
                start: 0,
                duration: max(totalDuration, 0.1),
                speed: Self.normalizedSpeed(speed),
                ramp: ramp,
                isWallpaper: isWallpaper
            )
        }

        let upper = min(totalDuration, limit)
        var length = min(max(duration.isFinite ? duration : Self.minSourceDuration, Self.minSourceDuration), upper)
        var origin = min(max(start.isFinite ? start : 0, 0), totalDuration - length)
        if origin < 0 { origin = 0 }
        // 二次修正：夹取起点后长度可能超出剩余部分
        if origin + length > totalDuration {
            length = max(totalDuration - origin, min(Self.minSourceDuration, upper))
        }
        return ClipSelection(
            start: origin,
            duration: length,
            speed: Self.normalizedSpeed(speed),
            ramp: ramp,
            isWallpaper: isWallpaper
        )
    }

    /// 保持起点不变，按「目标输出时长」反推需要多长的源片段。
    ///
    /// 输出时长越短，需要的源素材越少；倍速越高，同样的输出时长能装进更多源素材。
    func resized(toOutputDuration target: Double, totalDuration: Double) -> ClipSelection {
        // 壁纸模式的时长是钉死的，档位在界面上也不会出现，这里只做夹取
        guard !isWallpaper else { return clamped(totalDuration: totalDuration) }
        let wanted = min(max(target, Self.minOutputDuration), Self.maxOutputDuration) * effectiveSpeed
        var next = self
        next.speed = Self.normalizedSpeed(speed)
        next.duration = wanted
        return next.clamped(totalDuration: totalDuration)
    }

    /// 微调输出时长（±0.1 秒）。
    func nudgingOutputDuration(by delta: Double, totalDuration: Double) -> ClipSelection {
        resized(toOutputDuration: outputDuration + delta, totalDuration: totalDuration)
    }

    /// 设置匀速倍速（会一并关掉分段变速——两者是同一件事的两种形态）。
    func withSpeed(_ value: Double) -> ClipSelection {
        var next = self
        next.speed = Self.normalizedSpeed(value)
        next.ramp = nil
        return next
    }

    /// 设置或关闭分段变速。
    func withRamp(_ value: SpeedRamp?) -> ClipSelection {
        var next = self
        next.ramp = value
        if value == nil {
            next.speed = Self.normalizedSpeed(next.speed)
        }
        return next
    }

    /// 开关壁纸模式。开启时清掉分段变速，理由见 `isWallpaper` 的注释。
    func withWallpaper(_ enabled: Bool) -> ClipSelection {
        var next = self
        next.isWallpaper = enabled
        if enabled { next.ramp = nil }
        return next
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
        return ClipSelection(
            start: origin,
            duration: duration,
            speed: speed,
            ramp: ramp,
            isWallpaper: isWallpaper
        )
    }
}
