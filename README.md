# LiveMoment · 实况录影

一款把**任意视频**转换成 **iOS 原生实况照片（Live Photo）** 的 App。

挑一段视频 → 截出 3 秒内的片段 → 选好封面帧 → 直接存进系统相册，长按就能播放动态与声音。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | iOS 17.0+ |
| 工具 | Xcode 16.0+（用了 file-system-synchronized group） |
| 第三方依赖 | 无（纯系统框架） |
| 后端 / 服务端 | 无（全部在端上完成） |

> 如果只有 Xcode 15：安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后执行 `xcodegen generate`，
> 用项目里的 `project.yml` 重新生成一份兼容旧版本的工程即可。

## 构建

1. 用 Mac 打开 `LiveMoment/LiveMoment.xcodeproj`
2. 把 `Signing & Capabilities` 里的 **Bundle Identifier** 改成自己的（默认是占位符 `com.example.livemoment`）
3. 选择真机 → **Cmd + R** 运行（模拟器里 `PHAssetCreationRequest` 写相册行为受限，务必用真机）

首次运行会请求「添加到照片库」权限，这是保存实况照片必须的。

---

## 功能

- **相册 / 文件 双入口导入**：`PhotosPicker` 与 `.fileImporter`，视频统一拷贝到沙盒后再处理
- **时间轴片段选择**：缩略图底图 + 双手柄拖拽，上限锁 3 秒（实况照片的惯例时长）
- **封面帧挑选**：滑块在选区内实时抽帧，相册里看到的那张静图由它决定
- **保留 / 关闭原声**：关闭后合成轨道只保留视频
- **循环预览**：编辑时播放器在选区内循环，直接预览「按压播放」的实际手感
- **一键写入相册**：`PHAssetCreationRequest(.photo + .pairedVideo)`，产出的是**原生**实况照片
- **结果页预览**：`PHLivePhotoView` 播放转换结果，规格一目了然
- **配对文件导出**：生成 `IMG_xxx.pvt` 包（JPG + MOV），走 AirDrop 传给别的设备
- **转换记录**：SwiftData 落库，可删除

## 目录结构

```
LiveMoment/
├── LiveMoment.xcodeproj/
├── project.yml                  # XcodeGen 备用工程描述
└── LiveMoment/
    ├── LiveMomentApp.swift      # 入口 + SwiftData 容器
    ├── ContentView.swift        # 三 Tab：制作 / 记录 / 设置
    ├── Models/
    │   ├── ClipSelection.swift       # 选区模型（含 3s 上限的夹取逻辑）
    │   ├── ConvertedItem.swift       # 转换记录（SwiftData @Model）
    │   └── VideoTransfer.swift       # 相册/文件 → 沙盒
    ├── Services/
    │   ├── VideoLoader.swift         # 元信息 / 缩略图 / 抽帧
    │   ├── LivePhotoBuilder.swift    # ★ 核心引擎
    │   ├── PhotoLibraryService.swift # 相册写入
    │   ├── ExportService.swift       # .pvt 配对文件导出
    │   └── LoopingPlayer.swift       # 选区循环播放器
    ├── ViewModels/EditorViewModel.swift
    ├── Views/                        # 首页 / 编辑器 / 时间轴 / 结果 / 记录 / 设置
    └── Utilities/
```

---

## 技术实现：为什么这样做是对的

实况照片**不是一种新格式**，而是「一张静态主图 + 一段短视频」加上一对**相同的配对标识**：

| 位置 | 写入内容 |
|---|---|
| 照片（JPEG） | Apple MakerNote **标签 17**（`kCGImagePropertyMakerAppleDictionary["17"]`） |
| 视频（MOV） | QuickTime 元数据 `com.apple.quicktime.content.identifier` |
| 两侧 | **完全一致的 UUID** |

`LivePhotoBuilder` 的流水线：

1. **抽封面帧** —— `AVAssetImageGenerator`，开 `appliesPreferredTrackTransform` 保证竖屏素材抽出来也是竖的；`maximumSize` 用视频原生分辨率，保证封面与视频轨道尺寸一致
2. **写静态主图** —— `CGImageDestination` 输出 JPEG，同时写进 MakerNote 17
3. **裁剪 + 转码** —— `AVMutableComposition` 按 `CMTimeRange` 截取（顺便决定要不要音轨），`AVAssetExportSession` 用 `AVAssetExportPresetHEVCHighestQuality` 输出 `.mov`，并把 UUID 写进 `session.metadata`
4. **写入相册** —— `PHAssetCreationRequest.forAsset()` 添加 `.photo` 与 `.pairedVideo` 两个资源，系统读取两侧标识完成绑定

### 几个容易踩的坑（都在代码里处理了）

- **必须是 MOV 容器**：`session.outputFileType = .mov`，MP4 会被相册拒绝
- **HEVC 失败有兜底**：拿不到 HEVC 会话时退回 `AVAssetExportPresetHighestQuality`
- **旋转信息要带过去**：合成轨上手动回填 `preferredTransform`，否则竖屏视频会被压扁
- **封面帧必然有损**：H.264/H.265 是帧间压缩，任何工具都无法无损抠出静帧，只能重新编码（质量给到 0.95）
- **`still-image-time` 时间元数据轨未手写**：相册路径由 iOS 自行补全，不受影响；仅「文件导出」模式下极少数第三方相册 App 可能要求它

---

## 已知限制

- **微信、QQ 会剥离元数据**：实况照片直接发过去会散成「一张图 + 一段视频」。这是平台行为，任何客户端都无法绕过。要分享请用结果页的「保存配对文件」+ AirDrop
- 依赖系统转码能力，个别冷门编码（如某些 HDR/ProRes）可能转换失败，已有降级路径兜底
- 临时产物放在 `tmp/LiveMomentWork`，每次重新生成前会回收上一轮，iOS 也会在空间紧张时自动清理

## 后续可以加

- 相机直接拍摄后转实况图
- 关键帧变速 / 慢动作
- 壁纸模式（精确 0.916667s + `-video_track_timescale 600`）
- Android 动态照片（单文件拼接）导出，实现跨平台互通
