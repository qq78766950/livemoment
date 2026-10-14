import SwiftData
import SwiftUI
import UIKit

struct EditorView: View {
    let url: URL

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("defaultClipDuration") private var defaultClipDuration: Double = 2.0
    @AppStorage("keepAudioByDefault") private var keepAudioByDefault: Bool = true
    /// 用 rawValue 存，读的时候再还原成枚举；这样不依赖 AppStorage 对
    /// RawRepresentable 的泛型重载，行为在所有系统版本上完全一致。
    @AppStorage("preferredStillFormat") private var preferredStillFormatRaw: String = StillImageFormat.heic.rawValue

    @StateObject private var viewModel = EditorViewModel()
    @State private var finished: BuiltLivePhoto?

    private var preferredStillFormat: StillImageFormat {
        StillImageFormat(rawValue: preferredStillFormatRaw) ?? .heic
    }

    /// 壁纸模式会强制用 HEIC——真实拍摄的实况照片就是 HEIC，判定壁纸资格时它最稳。
    private var effectiveStillFormat: StillImageFormat {
        viewModel.isWallpaper ? .heic : preferredStillFormat
    }

    private var stillFormatBinding: Binding<StillImageFormat> {
        Binding(
            get: { preferredStillFormat },
            set: { preferredStillFormatRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let info = viewModel.info {
                    previewSection(info: info)
                    TimelineSection(
                        player: viewModel.player,
                        thumbnails: viewModel.thumbnails,
                        totalDuration: info.duration,
                        maxSourceDuration: viewModel.sourceLimit,
                        selectionText: viewModel.selectionText,
                        selection: $viewModel.selection,
                        onScrub: { viewModel.previewFrame(at: $0) },
                        onScrubEnded: { viewModel.settleFrame(at: $0) }
                    )
                    timingSection(info: info)
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

            // 速度角标：非原速时一直挂在画面角上，避免用户忘了自己开了快放
            if let badge = speedBadgeText {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
            }
        }
        .aspectRatio(
            info.displaySize.width / max(info.displaySize.height, 1),
            contentMode: .fit
        )
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var speedBadgeText: String? {
        if viewModel.isWallpaper { return "壁纸模式 · 0.92 秒" }
        guard viewModel.isRetimed else { return nil }
        if let ramp = viewModel.ramp {
            return "\(Formatters.speed(ramp.startSpeed)) → \(Formatters.speed(ramp.endSpeed)) 渐变"
        }
        let speed = viewModel.selection.speed
        return Formatters.speed(speed) + (speed < 1 ? " 慢放" : " 快放")
    }

    // MARK: - 时长与速度

    private func timingSection(info: VideoInfo) -> some View {
        Card(title: "时长与速度", systemImage: "timer") {
            if viewModel.isWallpaper {
                wallpaperTiming
            } else {
                standardTiming(info: info)
            }

            Divider()

            Button {
                viewModel.previewSelection()
            } label: {
                Label("循环预览选区", systemImage: "play.circle")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
        }
    }

    /// 壁纸模式：时长是钉死的，所以时长档位与速度档位都不适用，
    /// 只留下「源片段多长」这一个自由度，等效倍速由它反推出来。
    private var wallpaperTiming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("壁纸模式", systemImage: "lock.iphone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            HStack(spacing: 8) {
                metric(title: "源片段", value: Formatters.duration(viewModel.selection.duration))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                metric(title: "输出时长", value: "0.9167 秒")
                Spacer(minLength: 0)
            }

            Text("系统的壁纸判定要求动态恰好是 0.916667 秒（550/600）、视频时间基 600，并标出封面帧——这三件事壁纸模式都会做。时长钉死之后，能调的只剩源片段长度，它决定等效快慢：现在 \(Formatters.duration(viewModel.selection.duration)) 会被压成 0.9167 秒，约 \(Formatters.speed(viewModel.displaySpeed))。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("分段变速与时长档位在壁纸模式下不适用，切回普通模式即可使用。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func standardTiming(info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 源片段 → 输出时长，一眼看清倍速到底压缩掉了多少
            HStack(spacing: 8) {
                metric(title: "源片段", value: Formatters.duration(viewModel.selection.duration))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                metric(title: "输出时长", value: Formatters.duration(viewModel.outputDuration))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("目标输出时长")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ClipSelection.outputPresets, id: \.self) { preset in
                        let reachable = viewModel.canReach(outputDuration: preset, in: info)
                        Button {
                            viewModel.setOutputDuration(preset)
                        } label: {
                            Text(Formatters.duration(preset))
                                .font(.footnote.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    isCurrentPreset(preset) ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .foregroundStyle(isCurrentPreset(preset) ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!reachable)
                        .opacity(reachable ? 1 : 0.35)
                    }
                }
            }

            HStack(spacing: 14) {
                Text("微调")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                stepperButton(systemImage: "minus") { viewModel.nudgeOutputDuration(by: -0.1) }
                Text(Formatters.duration(viewModel.outputDuration))
                    .font(.footnote.monospacedDigit())
                    .frame(minWidth: 62)
                stepperButton(systemImage: "plus") { viewModel.nudgeOutputDuration(by: 0.1) }
            }

            Divider()

            // 匀速与分段变速是「同一段时间轴怎么走」的两种形态，所以二选一
            if viewModel.ramp == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("播放速度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("播放速度", selection: speedBinding) {
                        ForEach(ClipSelection.speedOptions, id: \.self) { option in
                            Text(Formatters.speed(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("调速度时保持源片段不变，输出时长跟着变：选 6 秒动作开 2× 快放，就能塞进 3 秒。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            rampControls

            if viewModel.exceedsNativeDuration {
                Label(
                    "系统的实况照片惯例是 3 秒，超过之后部分第三方 App 可能把它当普通视频。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 分段变速

    @ViewBuilder
    private var rampControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            OptionRow(
                title: "分段变速",
                subtitle: "同一段素材里先慢后快（或反过来），做节奏感"
            ) {
                Toggle("", isOn: rampEnabledBinding)
                    .labelsHidden()
            }

            if let ramp = viewModel.ramp {
                HStack(spacing: 8) {
                    rampPresetButton("先慢后快", ramp: .slowToFast, current: ramp)
                    rampPresetButton("先快后慢", ramp: .fastToSlow, current: ramp)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("起速")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("起速", selection: rampStartBinding) {
                        ForEach(ClipSelection.speedOptions, id: \.self) { option in
                            Text(Formatters.speed(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("终速")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("终速", selection: rampEndBinding) {
                        ForEach(ClipSelection.speedOptions, id: \.self) { option in
                            Text(Formatters.speed(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text("\(ramp.summary)，等效 \(Formatters.speed(ramp.effectiveSpeed))——各段倍速取调和平均，不是算术平均，否则时长会算短。预览会按同一条曲线实时变速。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rampPresetButton(_ title: String, ramp: SpeedRamp, current: SpeedRamp) -> some View {
        let selected = abs(current.startSpeed - ramp.startSpeed) < 0.001
            && abs(current.endSpeed - ramp.endSpeed) < 0.001
        return Button {
            viewModel.setRamp(ramp)
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selected ? Color.accentColor : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 封面帧

    @ViewBuilder
    private var coverSection: some View {
        Card(title: "封面帧", systemImage: "photo") {
            if viewModel.isWallpaper {
                HStack(alignment: .top, spacing: 14) {
                    coverThumbnail
                    Text("壁纸模式把封面帧固定在片段**最后一帧**。原因是 iOS 播放壁纸时只播「封面帧之前」的那一小段，封面放在末尾，整段 0.9167 秒才播得出来。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    coverThumbnail
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
    }

    private var coverThumbnail: some View {
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
    }

    // MARK: - 输出设置

    private func outputSection(info: VideoInfo) -> some View {
        Card(title: "输出设置", systemImage: "slider.horizontal.3") {
            OptionRow(
                title: "壁纸模式",
                subtitle: "输出钉在 0.916667 秒、时间基 600，并标出封面帧，用于设成锁屏壁纸"
            ) {
                Toggle("", isOn: wallpaperBinding)
                    .labelsHidden()
            }

            Divider()

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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("封面图格式")
                        .font(.footnote)
                    Spacer(minLength: 0)
                    Text(effectiveStillFormat.displayName)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Picker("封面图格式", selection: stillFormatBinding) {
                    ForEach(StillImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isWallpaper)

                Text(viewModel.isWallpaper
                     ? "壁纸模式固定用 HEIC——真实拍摄的实况照片就是 HEIC，判定壁纸资格时它最稳。"
                     : effectiveStillFormat.tradeOff + "动态那一半固定是 HEVC / MOV，不受这个选项影响。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SpecChip(systemImage: "photo", text: effectiveStillFormat.displayName)
                    SpecChip(systemImage: "video", text: "HEVC / MOV")
                    SpecChip(systemImage: "rectangle", text: info.resolutionText)
                    SpecChip(systemImage: "timer", text: Formatters.duration(viewModel.outputDuration))
                    SpecChip(systemImage: "speedometer", text: Formatters.speed(viewModel.displaySpeed))
                    if viewModel.isWallpaper {
                        SpecChip(systemImage: "lock.iphone", text: "壁纸 550/600")
                    }
                    if let ramp = viewModel.ramp {
                        SpecChip(systemImage: "waveform.path.ecg", text: "渐变 \(Formatters.speed(ramp.startSpeed))→\(Formatters.speed(ramp.endSpeed))")
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - 小部件

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .frame(width: 34, height: 30)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { viewModel.selection.speed },
            set: { viewModel.setSpeed($0) }
        )
    }

    private var rampEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.ramp != nil },
            set: { viewModel.setRamp($0 ? .slowToFast : nil) }
        )
    }

    private var rampStartBinding: Binding<Double> {
        Binding(
            get: { viewModel.ramp?.startSpeed ?? 1.0 },
            set: { value in
                let current = viewModel.ramp ?? .slowToFast
                viewModel.setRamp(SpeedRamp(
                    startSpeed: value,
                    endSpeed: current.endSpeed,
                    segments: current.segments
                ))
            }
        )
    }

    private var rampEndBinding: Binding<Double> {
        Binding(
            get: { viewModel.ramp?.endSpeed ?? 1.0 },
            set: { value in
                let current = viewModel.ramp ?? .slowToFast
                viewModel.setRamp(SpeedRamp(
                    startSpeed: current.startSpeed,
                    endSpeed: value,
                    segments: current.segments
                ))
            }
        )
    }

    private var wallpaperBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isWallpaper },
            set: { viewModel.setWallpaperMode($0) }
        )
    }

    private func isCurrentPreset(_ preset: Double) -> Bool {
        abs(viewModel.outputDuration - preset) < 0.06
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
                title: viewModel.isWallpaper ? "生成壁纸版实况照片" : "生成实况照片",
                systemImage: "sparkles",
                isEnabled: viewModel.info != nil && !viewModel.phase.isWorking
            ) {
                Task { await viewModel.build(stillFormat: effectiveStillFormat, context: modelContext) }
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
    let maxSourceDuration: Double
    let selectionText: String
    @Binding var selection: ClipSelection
    var onScrub: (Double) -> Void
    var onScrubEnded: (Double) -> Void

    var body: some View {
        Card(title: "选择动态片段", systemImage: "timeline.selection") {
            TimelineSelectorView(
                thumbnails: thumbnails,
                totalDuration: totalDuration,
                maxSourceDuration: maxSourceDuration,
                selection: $selection,
                playhead: player.currentTime,
                onScrub: onScrub,
                onScrubEnded: onScrubEnded
            )

            HStack {
                Text(selectionText)
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("拖手柄改长度 · 拖中间移动整段")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            Text("上限 \(Formatters.duration(maxSourceDuration))\(selection.isWallpaper ? "（壁纸模式）" : "（按当前 \(Formatters.speed(selection.displaySpeed)) 换算）") · 拖动时画面会跟着跳，直接看边界落在哪一帧")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
