import Foundation

/// 片段内部的**分段变速**：把选区等分成若干段，每段给一个不同的倍速，
/// 让同一段素材里出现「先慢后快」或「先快后慢」的节奏变化。
///
/// 它不引入任何新概念，只影响两件事：
/// - 每段的源长度（等分）与该段的倍速；
/// - 整段的**等效倍速**——各段倍速的调和平均。
///
/// 为什么是调和平均而不是算术平均：总输出时长 = Σ(源段长 ÷ 段倍速)。
/// 源段长相等时，它等于 `总源长 ÷ 调和平均`。用算术平均会让时长估算偏短，
/// 而时间轴长度上限、目标时长档位、封面偏移夹取全部依赖这个值，会一起错。
/// 举例：0.5× 与 2× 各占一半，算术平均是 1.25×，调和平均是 0.8×——
/// 后者才是对的（一半素材慢一倍，一半快一倍，净效果是变长）。
struct SpeedRamp: Equatable, Hashable {

    /// 段数。4 段足够表现「渐快 / 渐慢」，再细分只是更接近线性，用户看不出差别。
    static let segmentCount = 4
    static let minSegmentCount = 2
    static let maxSegmentCount = 8

    /// 第一段的倍速。
    var startSpeed: Double
    /// 最后一段的倍速。
    var endSpeed: Double
    /// 段数。
    var segments: Int

    init(
        startSpeed: Double,
        endSpeed: Double,
        segments: Int = SpeedRamp.segmentCount
    ) {
        self.startSpeed = ClipSelection.normalizedSpeed(startSpeed)
        self.endSpeed = ClipSelection.normalizedSpeed(endSpeed)
        self.segments = min(max(segments, SpeedRamp.minSegmentCount), SpeedRamp.maxSegmentCount)
    }

    /// 各段倍速，在起止之间线性过渡。
    var speeds: [Double] {
        guard segments > 1 else { return [startSpeed] }
        return (0..<segments).map { index in
            let t = Double(index) / Double(segments - 1)
            return startSpeed + (endSpeed - startSpeed) * t
        }
    }

    /// 等效倍速 = 各段倍速的调和平均。
    var effectiveSpeed: Double {
        let values = speeds
        let denominator = values.reduce(0.0) { $0 + 1.0 / $1 }
        guard denominator.isFinite, denominator > 0 else { return 1 }
        return Double(values.count) / denominator
    }

    /// 起止速度是否真的不一样。一样的话等价于匀速，引擎会走单段路径。
    var isRamping: Bool { abs(endSpeed - startSpeed) > 0.001 }

    /// 一句话说明，编辑器与结果页共用同一套口径。
    var summary: String {
        "\(Formatters.speed(startSpeed)) → \(Formatters.speed(endSpeed))，分 \(segments) 段"
    }

    /// 预设：先慢后快 / 先快后慢。
    static let slowToFast = SpeedRamp(startSpeed: 0.5, endSpeed: 2.0)
    static let fastToSlow = SpeedRamp(startSpeed: 2.0, endSpeed: 0.5)
}
