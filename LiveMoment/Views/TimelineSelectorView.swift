import SwiftUI
import UIKit

/// 时间轴片段选择器：底图是均匀抽帧的缩略图，两侧手柄拖动调整区间。
///
/// 上限锁在 3 秒，因为实况照片本来就是「按下快门前后的 1.5 秒」，
/// 超过这个长度的片段在相册里播放会显得很奇怪。
struct TimelineSelectorView: View {
    let thumbnails: [UIImage]
    let totalDuration: Double
    @Binding var selection: ClipSelection
    var playhead: Double = 0

    @State private var anchor: (start: Double, duration: Double)?

    private let trackHeight: CGFloat = 66
    private let handleWidth: CGFloat = 9

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

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: selectionWidth, height: trackHeight)
                    .offset(x: startX)

                // 播放头
                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: trackHeight)
                    .offset(x: min(max(playheadX - 1, 0), width - 2))

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
            .gesture(dragGesture(isLeading: isLeading, trackWidth: trackWidth))
    }

    // MARK: - 拖拽

    private func dragGesture(isLeading: Bool, trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration > 0.1 else { return }
                if anchor == nil {
                    anchor = (selection.start, selection.duration)
                }
                guard let anchor else { return }

                let secondsPerPoint = totalDuration / Double(max(trackWidth, 1))
                let delta = Double(value.translation.width) * secondsPerPoint

                var start = anchor.start
                var end = anchor.start + anchor.duration

                if isLeading {
                    start = min(max(0, anchor.start + delta), end - ClipSelection.minDuration)
                    end = min(end, start + ClipSelection.maxDuration)
                } else {
                    end = max(min(totalDuration, anchor.start + anchor.duration + delta), start + ClipSelection.minDuration)
                    start = max(start, end - ClipSelection.maxDuration)
                }

                selection = ClipSelection(start: max(0, start), duration: max(ClipSelection.minDuration, end - start))
            }
            .onEnded { _ in
                anchor = nil
            }
    }
}
