import SwiftUI
import UIKit

/// 时间轴片段选择器：底图是均匀抽帧的缩略图，两侧手柄拖动调整区间。
///
/// 三种操作：
/// - 拖左手柄 = 改起点（选区尾部不动）
/// - 拖右手柄 = 改终点（选区头部不动）
/// - 拖选区中间 = 整段平移，用来在长视频里挪位置
///
/// 拖动过程中会通过 `onScrub` 把当前边界对应的时间回调出去，
/// 让播放器即时跳到那一帧——这就是「边选边看」，不用等松手才播。
///
/// 长度上限由外部传入（`maxSourceDuration`），因为它是**随倍速变化的**：
/// 2× 快放时 5 秒的输出能装下 10 秒素材，1× 时只能装 5 秒。
struct TimelineSelectorView: View {
    let thumbnails: [UIImage]
    let totalDuration: Double
    /// 当前倍速下源片段允许的最大长度。
    let maxSourceDuration: Double
    @Binding var selection: ClipSelection
    var playhead: Double = 0
    /// 拖动中回调，参数是边界在源视频上的秒数。
    var onScrub: (Double) -> Void = { _ in }
    /// 松手回调，用于做一次精确落点。
    var onScrubEnded: (Double) -> Void = { _ in }

    @State private var edgeAnchor: (start: Double, duration: Double)?
    @State private var moveAnchor: Double?

    private let trackHeight: CGFloat = 66
    private let handleWidth: CGFloat = 9
    /// 拖到终点时往回让一帧，避免正好落在选区外导致预览变成下一段的画面。
    private let frameBackstep = 1.0 / 30.0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let scale = width / CGFloat(max(totalDuration, 0.01))
            let startX = CGFloat(selection.start) * scale
            let selectionWidth = max(CGFloat(selection.duration) * scale, handleWidth * 2)
            let playheadX = CGFloat(min(max(playhead, 0), totalDuration)) * scale

            ZStack(alignment: .topLeading) {
                thumbnailStrip(width: width)

                // 选区之外压暗，突出被选中的部分
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: max(0, startX), height: trackHeight)

                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: max(0, width - startX - selectionWidth), height: trackHeight)
                    .offset(x: startX + selectionWidth)

                // 选区内部的透明命中区：整段平移。
                // 放在边框之前、手柄之后被手柄盖住，所以边缘拖拽仍然优先调长度。
                Color.clear
                    .frame(width: selectionWidth, height: trackHeight)
                    .contentShape(Rectangle())
                    .offset(x: startX)
                    .gesture(moveGesture(trackWidth: width))

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: selectionWidth, height: trackHeight)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                // 播放头
                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: trackHeight)
                    .offset(x: min(max(playheadX - 1, 0), width - 2))
                    .allowsHitTesting(false)

                handle(offsetX: startX - handleWidth + 1, isLeading: true, trackWidth: width)
                handle(offsetX: startX + selectionWidth - 1, isLeading: false, trackWidth: width)
            }
            .frame(width: width, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(height: trackHeight)
    }

    // MARK: - 子视图

    @ViewBuilder
    private func thumbnailStrip(width: CGFloat) -> some View {
        if thumbnails.isEmpty {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: width, height: trackHeight)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            width: width / CGFloat(thumbnails.count),
                            height: trackHeight
                        )
                        .clipped()
                }
            }
            .frame(width: width, height: trackHeight, alignment: .leading)
        }
    }

    private func handle(offsetX: CGFloat, isLeading: Bool, trackWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: trackHeight)
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 3, height: 3)
                    }
                }
            )
            .offset(x: offsetX)
            .gesture(edgeGesture(isLeading: isLeading, trackWidth: trackWidth))
    }

    // MARK: - 拖拽

    private func secondsPerPoint(trackWidth: CGFloat) -> Double {
        totalDuration / Double(max(trackWidth, 1))
    }

    /// 只改起点与长度，倍速 / 分段变速 / 壁纸模式原样带过去。
    ///
    /// 这里必须逐项复制而不是写 `ClipSelection(start:duration:)`——
    /// 后者会把分段变速和壁纸模式悄悄清掉，用户一拖时间轴就发现设置没了。
    private func rebuilt(start: Double, duration: Double) -> ClipSelection {
        ClipSelection(
            start: start,
            duration: duration,
            speed: selection.speed,
            ramp: selection.ramp,
            isWallpaper: selection.isWallpaper
        )
    }

    /// 拖动两侧手柄：改变片段长度。
    private func edgeGesture(isLeading: Bool, trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration > 0.1 else { return }
                if edgeAnchor == nil {
                    edgeAnchor = (selection.start, selection.duration)
                }
                guard let anchor = edgeAnchor else { return }

                let delta = Double(value.translation.width) * secondsPerPoint(trackWidth: trackWidth)
                let limit = max(maxSourceDuration, ClipSelection.minSourceDuration)

                var start = anchor.start
                var end = anchor.start + anchor.duration

                if isLeading {
                    start = min(max(0, anchor.start + delta), end - ClipSelection.minSourceDuration)
                    end = min(end, start + limit)
                } else {
                    end = max(
                        min(totalDuration, anchor.start + anchor.duration + delta),
                        start + ClipSelection.minSourceDuration
                    )
                    start = max(start, end - limit)
                }

                let next = rebuilt(
                    start: max(0, start),
                    duration: max(ClipSelection.minSourceDuration, end - start)
                )
                selection = next
                onScrub(isLeading ? next.start : max(next.start, next.end - frameBackstep))
            }
            .onEnded { _ in
                edgeAnchor = nil
                onScrubEnded(isLeading ? selection.start : max(selection.start, selection.end - frameBackstep))
            }
    }

    /// 拖动选区主体：整段平移，长度不变。
    private func moveGesture(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard totalDuration > 0.1 else { return }
                if moveAnchor == nil { moveAnchor = selection.start }
                guard let base = moveAnchor else { return }

                let delta = Double(value.translation.width) * secondsPerPoint(trackWidth: trackWidth)
                let maxStart = max(0, totalDuration - selection.duration)
                let newStart = min(max(0, base + delta), maxStart)

                selection = rebuilt(start: newStart, duration: selection.duration)
                onScrub(newStart)
            }
            .onEnded { _ in
                moveAnchor = nil
                onScrubEnded(selection.start)
            }
    }
}
