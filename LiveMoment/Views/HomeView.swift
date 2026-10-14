import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var imported: ImportedVideo?
    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero

                PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                    entryLabel(
                        title: "从相册选视频",
                        subtitle: "直接用手机里已经拍好的短片",
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showFileImporter = true
                } label: {
                    entryLabel(
                        title: "从文件选视频",
                        subtitle: "支持「文件」App 与云盘里的视频",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.plain)

                howItWorks
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("实况录影")
        .overlay {
            if isLoading {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("正在读取视频…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadFromPicker(newValue) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .navigationDestination(item: $imported) { video in
            EditorView(url: video.url)
        }
        .alert("无法打开这个视频", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 子视图

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "livephoto")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text("把一段视频变成一张会动的照片")
                .font(.title3.weight(.semibold))
            Text("挑一段视频，拖手柄截出想要的片段，随手拖拉就能看到画面跳到哪儿；再定好时长、调个快慢，选好封面帧，就能生成一张可以按压播放、带声音的实况照片。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func entryLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var howItWorks: some View {
        Card(title: "使用提示", systemImage: "lightbulb") {
            bullet("拖两侧手柄改片段长度，拖选区中间挪位置；拖动过程中画面会跟着跳，选到哪儿看得见。")
            bullet("0.5×～2× 可调速：想留住更多动作就选长一点 + 快放，6 秒素材开 2× 正好装进 3 秒。")
            bullet("片段越短越像真的实况照片，1.5～3 秒最自然；超过 3 秒在部分 App 里会被当普通视频。")
            bullet("封面帧建议挑画面最稳、最清楚的那一帧。")
            bullet("生成后可以直接发朋友圈；要传给别的手机请用 AirDrop，微信会剥掉元数据。")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.top, 7)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 数据

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func loadFromPicker(_ item: PhotosPickerItem) async {
        isLoading = true
        defer {
            isLoading = false
            pickerItem = nil
        }
        do {
            guard let transfer = try await item.loadTransferable(type: VideoTransfer.self) else {
                errorMessage = "系统没能读取这段视频，换一个试试。"
                return
            }
            imported = ImportedVideo(url: transfer.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                imported = ImportedVideo(url: try VideoTransfer.copyIntoImportFolder(url))
            } catch {
                errorMessage = "拷贝文件失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
