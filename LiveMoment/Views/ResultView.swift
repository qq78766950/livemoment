import Photos
import SwiftUI
import UIKit

struct ResultView: View {
    let result: BuiltLivePhoto
    let libraryIdentifier: String?

    @Environment(\.dismiss) private var dismiss

    @State private var livePhoto: PHLivePhoto?
    @State private var staticImage: UIImage?
    @State private var statusText = "正在准备预览…"
    @State private var exportedFolder: URL?
    @State private var androidOutput: MotionPhotoExporter.Output?
    @State private var isExportingAndroid = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                previewCard
                specCard
                exportCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("生成完成")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task { await loadPreview() }
        .alert("导出失败", isPresented: exportErrorBinding) {
            Button("知道了", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - 预览

    private var previewCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black
                if let livePhoto {
                    LivePhotoPreviewView(livePhoto: livePhoto)
                        .padding(6)
                } else if let staticImage {
                    Image(uiImage: staticImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    ProgressView().tint(.white)
                }

                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "livephoto").font(.caption2)
                        Text("实况").font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 规格

    private var specCard: some View {
        Card(title: "这张实况照片", systemImage: "info.circle") {
            LabeledContent("分辨率", value: result.resolutionText)
            LabeledContent("动态时长", value: Formatters.duration(result.duration))
            if result.isRetimed {
                LabeledContent("播放速度", value: "\(Formatters.speed(result.speed))（源片段 \(Formatters.duration(result.sourceDuration))）")
            }
            LabeledContent("视频体积", value: result.fileSizeText)
            LabeledContent("静态主图", value: result.stillFormat.displayName)
            LabeledContent("动态视频", value: "HEVC (H.265) / MOV")

            if result.isWallpaper {
                LabeledContent("壁纸模式") {
                    HStack(spacing: 4) {
                        Text(result.wallpaperApplied ? "已处理" : "未完成")
                            .font(.footnote)
                        Image(systemName: result.wallpaperApplied
                              ? "checkmark.seal.fill"
                              : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(result.wallpaperApplied ? .green : .orange)
                    }
                }
            }

            LabeledContent("配对标识") {
                HStack(spacing: 4) {
                    Text(result.identifier.prefix(8) + "…")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Image(systemName: result.identifierVerified
                          ? "checkmark.seal.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(result.identifierVerified ? .green : .orange)
                }
            }
            LabeledContent("相册状态") {
                if libraryIdentifier != nil {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Text("未保存").font(.footnote).foregroundStyle(.orange)
                }
            }

            // 发生了格式回退（或标识没写进去）时如实说明，不让用户自己猜
            if let note = result.stillFallbackReason {
                Label(
                    result.identifierVerified
                        ? "\(note)，已自动改用另一种格式重写。"
                        : "\(note)，这张实况照片可能无法在相册里配对播放。",
                    systemImage: result.identifierVerified
                        ? "arrow.triangle.2.circlepath"
                        : "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(result.identifierVerified ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            // 壁纸后处理没做完时同样要说明，别让用户拿着一条不会动的壁纸去试
            if let note = result.wallpaperNote {
                Label(note, systemImage: "lock.iphone")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 导出

    private var exportCard: some View {
        Card(title: "分享到别的设备", systemImage: "square.and.arrow.up") {
            Text("实况照片在磁盘上是「一张 \(result.stillFormat.displayName) + 一段 MOV」两个文件，靠配对标识绑定。AirDrop、iCloud 云盘这类通道能保住配对关系。微信、QQ 会剥掉元数据，发过去会散成两个独立文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let exportedFolder {
                ShareLink(item: exportedFolder) {
                    Label("分享配对文件", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Text("已存到「文件 → 我的 iPhone → 实况录影 → \(exportedFolder.lastPathComponent)」")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    exportPair()
                } label: {
                    Label("保存配对文件到「文件」App", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            Divider()

            androidSection

            Divider()

            Button {
                dismiss()
            } label: {
                Label("再做一个", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    /// 安卓动态照片是「单文件拼接」，和苹果的双文件完全不通用，所以单独一条出口。
    @ViewBuilder
    private var androidSection: some View {
        Text("安卓手机认的是另一种格式：一张 JPEG 后面直接接一段 MP4，靠 JPEG 里的 XMP 记录视频的字节位置，文件名以 MP 结尾。和苹果这套双文件不通用，需要单独导出一份。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let androidOutput {
            ShareLink(item: androidOutput.url) {
                Label("分享安卓动态照片", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)

            Text("已存到「文件 → 我的 iPhone → 实况录影 → \(androidOutput.url.lastPathComponent)」· 主图 \(Formatters.fileSize(androidOutput.jpegByteCount)) + 视频 \(Formatters.fileSize(androidOutput.videoByteCount))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button {
                Task { await exportAndroid() }
            } label: {
                HStack(spacing: 8) {
                    if isExportingAndroid {
                        ProgressView()
                    }
                    Label(
                        isExportingAndroid ? "正在拼接动态照片…" : "导出安卓动态照片",
                        systemImage: "rectangle.stack.badge.plus"
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(isExportingAndroid)
        }
    }

    // MARK: - 数据

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    /// 显式标 `@MainActor`：这是一个非隔离类型上的异步方法，
    /// 不标的话第一次 `await` 之后会落到后台线程，再改 `@State` 就是在非主线程动界面状态。
    @MainActor
    private func loadPreview() async {
        if staticImage == nil {
            staticImage = UIImage(contentsOfFile: result.photoURL.path)
        }

        // 从本地文件对构建 PHLivePhoto：文件里的配对标识齐全，这一步是确定性的。
        // 相册里的那份由系统自己管理，用户去「照片」App 就能看到。
        if let photo = await requestFromFiles() {
            livePhoto = photo
            statusText = "长按画面即可播放动态与声音。"
        } else if !result.identifierVerified {
            statusText = "配对标识没能写进主图文件，系统不会把它认成实况照片。可以到「设置 → 封面图格式」换一种格式再试一次。"
        } else if libraryIdentifier != nil {
            statusText = "照片已保存到相册，请到「照片」App 里长按播放。"
        } else {
            statusText = "已生成文件，但当前设备无法预览实况效果。"
        }
    }

    private func requestFromFiles() async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            let once = OnceBox()
            let size = CGSize(width: 1400, height: 1400)
            PHLivePhoto.request(
                withResourceFileURLs: [result.photoURL, result.videoURL],
                placeholderImage: staticImage,
                targetSize: size,
                contentMode: .aspectFit
            ) { photo, _ in
                guard once.claim() else { return }
                continuation.resume(returning: photo)
            }
        }
    }

    private func exportPair() {
        do {
            exportedFolder = try ExportService.exportPair(result, baseName: ExportService.makeBaseName())
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// 同上：拼接本身跑在后台，状态更新回到主线程。
    @MainActor
    private func exportAndroid() async {
        isExportingAndroid = true
        defer { isExportingAndroid = false }
        do {
            androidOutput = try await MotionPhotoExporter.export(
                result,
                baseName: ExportService.makeBaseName()
            )
        } catch {
            exportError = error.localizedDescription
        }
    }
}
