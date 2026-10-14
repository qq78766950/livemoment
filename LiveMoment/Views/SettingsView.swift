import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultClipDuration") private var defaultClipDuration: Double = 2.0
    @AppStorage("keepAudioByDefault") private var keepAudioByDefault: Bool = true

    @State private var hasPermission = PhotoLibraryService.hasAddPermission()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("默认片段长度")
                        Spacer()
                        Text(Formatters.duration(defaultClipDuration))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $defaultClipDuration, in: 1.0...3.0, step: 0.1)
                }
                Toggle("默认保留原声", isOn: $keepAudioByDefault)
            } header: {
                Text("转换默认值")
            } footer: {
                Text("每次打开编辑器用这套默认值初始化，进去之后仍然可以单独调整。")
            }

            Section {
                LabeledContent("相册写入权限") {
                    Text(hasPermission ? "已允许" : "未允许")
                        .foregroundStyle(hasPermission ? .green : .orange)
                }
                Button("重新检查权限") {
                    Task {
                        _ = await PhotoLibraryService.requestAddPermission()
                        hasPermission = PhotoLibraryService.hasAddPermission()
                    }
                }
            } header: {
                Text("权限")
            }

            Section {
                LabeledContent("输出编码", value: "HEVC (H.265) / MOV")
                LabeledContent("配对方式", value: "Content Identifier")
                LabeledContent("片段上限", value: "3.0 秒")
                LabeledContent("最低系统", value: "iOS 17.0")
            } header: {
                Text("技术参数")
            }

            Section {
                Text("""
                实况照片不是一种新格式，而是「一张静态主图 + 一段短视频」，两者靠同一个配对标识绑定。

                本 App 在转码时会把这段标识同时写进照片的 Apple MakerNote（标签 17）和视频的 QuickTime 元数据（com.apple.quicktime.content.identifier），再交给系统相册完成绑定，所以生成出来的就是原生实况照片，不依赖任何服务端。

                注意：微信、QQ 这类通道会剥离元数据，直接发送会退化成「一张图 + 一段视频」。要传给别的手机，请用结果页的「保存配对文件」配合 AirDrop。
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("设置")
        .onAppear {
            hasPermission = PhotoLibraryService.hasAddPermission()
        }
    }
}
