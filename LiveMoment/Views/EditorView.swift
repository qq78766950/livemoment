import SwiftData
import SwiftUI
import UIKit

struct EditorView: View {
    let url: URL

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("defaultClipDuration") private var defaultClipDuration: Double = 2.0
    @AppStorage("keepAudioByDefault") private var keepAudioByDefault: Bool = true

    @StateObject private var viewModel = EditorViewModel()
    @State private var finished: BuiltLivePhoto?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let info = viewModel.info {
                    previewSection(info: info)
                    TimelineSection(
                        player: viewModel.player,
                        thumbnails: viewModel.thumbnails,
                        totalDuration: info.duration,
                        selectionText: viewModel.selectionText,
                        selection: $viewModel.selection
                    )
                    coverSection
                    outputSection(info: info)
                } else if case .failed(let message) = viewModel.phase {
                    failureCard(message)
                } else {
                    ProgressView("正在读取视频…")
                        .padding(.vertical, 80)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("制作实况照片")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task {
            await viewModel.prepare(
                url: url,
                defaultDuration: defaultClipDuration,
                keepAudioByDefault: keepAudioByDefault
            )
        }
        .onChange(of: viewModel.selection) { _, _ in viewModel.selectionDidChange() }
        .onChange(of: viewModel.coverOffset) { _, _ in viewModel.refreshCover() }
        .onChange(of: viewModel.phase) { _, newValue in
            if case .done(let result) = newValue {
                finished = result
            }
        }
        .navigationDestination(item: $finished) { result in
            ResultView(result: result, libraryIdentifier: viewModel.libraryIdentifier)
        }
    }

    // MARK: - 预览

    private func previewSection(info: VideoInfo) -> some View {
        ZStack {
            PlayerLayerView(player: viewModel.player.player)

            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(viewModel.player.isPlaying ? 0.35 : 1)
        }
        .aspectRatio(
            info.displaySize.width / max(info.displaySize.height, 1),
            contentMode: .fit
        )
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 封面帧

    private var coverSection: some View {
        Card(title: "封面帧", systemImage: "photo") {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let image = viewModel.coverPreview {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color(.tertiarySystemFill)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text("这张静图就是相册里看到的那一帧，拖动滑块挑最清楚的一张。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Slider(value: $viewModel.coverOffset, in: 0...max(viewModel.selection.duration - 0.02, 0.02))

                    Text("@ \(Formatters.timecode(viewModel.coverTime))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 输出设置

    private func outputSection(info: VideoInfo) -> some View {
        Card(title: "输出设置", systemImage: "slider.horizontal.3") {
            OptionRow(
                title: "保留原声",
                subtitle: info.hasAudio ? "关掉之后就是无声的实况照片" : "这段视频本来就没有音轨"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.keepAudio },
                        set: { viewModel.setKeepAudio($0) }
                    )
                )
                .labelsHidden()
                .disabled(!info.hasAudio)
            }

            Divider()

            HStack(spacing: 8) {
                SpecChip(systemImage: "video", text: "HEVC / MOV")
                SpecChip(systemImage: "rectangle", text: info.resolutionText)
                SpecChip(systemImage: "timer", text: Formatters.duration(viewModel.selection.duration))
            }
        }
    }

    // MARK: - 失败

    private func failureCard(_ message: String) -> some View {
        Card(title: "处理失败", systemImage: "exclamationmark.triangle") {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("换一个视频") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 底部操作条

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if viewModel.phase.isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.phase.workingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            PrimaryActionButton(
                title: "生成实况照片",
                systemImage: "sparkles",
                isEnabled: viewModel.info != nil && !viewModel.phase.isWorking
            ) {
                Task { await viewModel.build(context: modelContext) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

// MARK: - 时间轴区块

/// 单独拆出来是为了把播放头每秒 10 次的刷新限制在这一小块里，
/// 不牵连整个编辑页重绘。
private struct TimelineSection: View {
    @ObservedObject var player: LoopingPlayer
    let thumbnails: [UIImage]
    let totalDuration: Double
    let selectionText: String
    @Binding var selection: ClipSelection

    var body: some View {
        Card(title: "选择动态片段", systemImage: "timeline.selection") {
            TimelineSelectorView(
                thumbnails: thumbnails,
                totalDuration: totalDuration,
                selection: $selection,
                playhead: player.currentTime
            )

            HStack {
                Text(selectionText)
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("拖动两侧手柄 · 上限 3 秒")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}
