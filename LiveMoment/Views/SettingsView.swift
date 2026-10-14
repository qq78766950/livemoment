import AVFoundation
import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultClipDuration") private var defaultClipDuration: Double = 2.0
    @AppStorage("keepAudioByDefault") private var keepAudioByDefault: Bool = true
    @AppStorage("preferredStillFormat") private var preferredStillFormatRaw: String = StillImageFormat.heic.rawValue

    @State private var hasPermission = PhotoLibraryService.hasAddPermission()
    @State private var cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    private var preferredStillFormat: StillImageFormat {
        StillImageFormat(rawValue: preferredStillFormatRaw) ?? .heic
    }

    private var stillFormatBinding: Binding<StillImageFormat> {
        Binding(
            get: { preferredStillFormat },
            set: { preferredStillFormatRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("默认输出时长")
                        Spacer()
                        Text(Formatters.duration(defaultClipDuration))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $defaultClipDuration, in: 1.0...5.0, step: 0.1)
                }
                Toggle("默认保留原声", isOn: $keepAudioByDefault)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("封面图格式")
                        Spacer()
                        Text(preferredStillFormat.displayName)
                            .foregroundStyle(.secondary)
                    }
                    Picker("封面图格式", selection: stillFormatBinding) {
                        ForEach(StillImageFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(preferredStillFormat.tradeOff)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } header: {
                Text("转换默认值")
            } footer: {
                Text("每次打开编辑器用这套默认值初始化，进去之后仍然可以单独调整。这里的时长是「输出时长」，即计入倍速之后的结果；超过 3 秒的部分第三方 App 可能把实况照片当普通视频。")
            }

            Section {
                LabeledContent("相册写入权限") {
                    Text(hasPermission ? "已允许" : "未允许")
                        .foregroundStyle(hasPermission ? .green : .orange)
                }
                LabeledContent("相机权限") {
                    Text(cameraGranted ? "已允许" : "未允许")
                        .foregroundStyle(cameraGranted ? .green : .orange)
                }
                Button("重新检查权限") {
                    Task {
                        _ = await PhotoLibraryService.requestAddPermission()
                        hasPermission = PhotoLibraryService.hasAddPermission()
                        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("相机权限只在首页的「拍摄一段」里用到，不给也不影响从相册或文件导入视频。")
            }

            Section {
                LabeledContent("静态主图", value: preferredStillFormat.displayName)
                LabeledContent("动态视频", value: "HEVC (H.265) / MOV")
                LabeledContent("配对方式", value: "Content Identifier（自动校验）")
                LabeledContent("输出时长", value: "0.5 ～ 5.0 秒")
                LabeledContent("源片段上限", value: "20 秒内，且随倍速浮动")
                LabeledContent("播放速度", value: "0.5× ～ 2×（可分段渐变）")
                LabeledContent("壁纸模式", value: "0.916667 秒 · 时间基 600")
                LabeledContent("安卓导出", value: "JPEG + MP4 单文件拼接")
                LabeledContent("收录方式", value: "相机拍摄 / 相册 / 文件")
                LabeledContent("最低系统", value: "iOS 17.0")
            } header: {
                Text("技术参数")
            }

            Section {
                Text("""
                实况照片不是一种新格式，而是「一张静态主图 + 一段短视频」，两者靠同一个配对标识绑定。

                本 App 在转码时会把这段标识同时写进照片的 Apple MakerNote（标签 17）和视频的 QuickTime 元数据（com.apple.quicktime.content.identifier），再交给系统相册完成绑定，所以生成出来的就是原生实况照片，不依赖任何服务端。

                静态主图有两种写法：HEIC 是系统相机在「高效」模式下采用的原生形态，体积约为 JPEG 的一半，也是苹果最认的那条路；JPEG 胜在通用。两者都会被自动校验——写完立刻把文件读回来确认配对标识真的落盘了，不合格就换另一种重写。视频那一半永远是 HEVC / MOV，这两种格式都不影响它。

                注意：微信、QQ 这类通道会剥离元数据，直接发送会退化成「一张图 + 一段视频」。要传给别的手机，请用结果页的「保存配对文件」配合 AirDrop。
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("关于实况照片")
            }

            Section {
                Text("""
                想做锁屏壁纸，打开编辑器里的「壁纸模式」。它会做三件系统判定会检查的事：把动态时长钉在 550/600 秒（0.916667 秒）、把视频轨的媒体时间基压到 600、并写入一条标记封面帧位置的「时间元数据轨」（com.apple.quicktime.still-image-time）。后两件必须重封装一次文件才能做到，所以这一步比普通模式多花几秒。

                有一件事做不到：真实拍摄的实况照片还带一条每帧传感器读数的元数据轨（com.apple.quicktime.live-photo-info），那是拍摄时的真实陀螺仪数据，格式也没公开，编不出来。所以壁纸模式能备齐所有可备齐的条件，但最终认不认仍由 iOS 现场决定。
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("关于壁纸模式")
            }

            Section {
                Text("""
                安卓的动态照片和苹果这套完全是两条路线：它是一个**单文件**——前面是完整的 JPEG，后面直接接一段 MP4，靠 JPEG 里的一段 XMP 记录「视频从文件末尾往前数多少字节开始」。所以苹果的实况照片发到安卓会散架，安卓的动态照片在 iOS 上也只会显示成一张普通照片，两边不通用。

                结果页的「导出安卓动态照片」会重新做一份：主图转成 JPEG、视频转成 H.264 / MP4、注入 XMP 并拼接，文件名按规范以 MP 结尾。同时写旧标准（Camera:MicroVideo*）和新标准（Camera:MotionPhoto* + 容器目录）两套字段，兼容面最大。
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("关于安卓动态照片")
            }
        }
        .navigationTitle("设置")
        .onAppear {
            hasPermission = PhotoLibraryService.hasAddPermission()
            cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }
}
