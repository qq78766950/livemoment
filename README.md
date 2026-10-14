# LiveMoment · 实况录影

一款把**任意视频**转换成 **iOS 原生实况照片（Live Photo）** 的 App。

挑一段视频 → 拖手柄截出想要的片段 → 定好时长、调个快慢 → 选好封面帧 → 直接存进系统相册，长按就能播放动态与声音。

---

## 环境要求

| 项目       | 要求                                             |
| -------- | ---------------------------------------------- |
| 系统       | iOS 17.0+                                      |
| 工具       | Xcode 16.0+（用了 file-system-synchronized group） |
| 第三方依赖    | 无（纯系统框架）                                       |
| 后端 / 服务端 | 无（全部在端上完成）                                     |

> 如果只有 Xcode 15：安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后执行 `xcodegen generate`，  
> 用项目里的 `project.yml` 重新生成一份兼容旧版本的工程即可。

## 构建

**有 Mac：**

1. 用 Mac 打开 `LiveMoment/LiveMoment.xcodeproj`
2. 把 `Signing & Capabilities` 里的 **Bundle Identifier** 改成自己的（默认是占位符 `com.example.livemoment`）
3. 选择真机 → **Cmd + R** 运行（模拟器里 `PHAssetCreationRequest` 写相册行为受限，务必用真机）

或者一条命令编出一个未签名的 .ipa：

```bash
bash scripts/build_ipa.sh          # 产物：build/LiveMoment-unsigned.ipa
```

**没有 Mac：** 推到 GitHub，用 `.github/workflows/build-ios.yml` 在云端 macOS runner 上编译，  
下载 artifact 得到的 .ipa 再用 Sideloadly 签名安装。完整步骤见 **[安装到手机指南.md](安装到手机指南.md)**。

首次运行会请求「添加到照片库」权限，这是保存实况照片必须的。

---

## 功能

- **相册 / 文件 双入口导入**：`PhotosPicker` 与 `.fileImporter`，视频统一拷贝到沙盒后再处理
- **时间轴片段选择**：缩略图底图 + 双手柄拖拽；**拖选区中间可整段平移**，在长视频里挪位置不用重新拉长度
- **拖动即时预览**：拖手柄/平移的过程中播放器暂停并低延迟跟随到边界那一帧，拖到哪儿看得见，不用松手才知道
- **时长可调**：1 / 2 / 3 / 5 秒快捷档 + ±0.1 秒微调，按「目标输出时长」反推需要多长的源片段
- **0.5× ~ 2× 变速**：预览实时变速；成品走 `scaleTimeRange` 真正改写时间轴，并配 `.spectral` 音高算法做到**变速不变调**
- **封面帧挑选**：滑块在选区内实时抽帧，相册里看到的那张静图由它决定
- **保留 / 关闭原声**：关闭后合成轨道只保留视频
- **循环预览**：编辑时播放器在选区内按当前倍速循环，直接预览「按压播放」的实际手感
- **一键写入相册**：`PHAssetCreationRequest(.photo + .pairedVideo)`，产出的是**原生**实况照片
- **结果页预览**：`PHLivePhotoView` 播放转换结果，规格（含变速信息）一目了然
- **配对文件导出**：生成 `IMG_xxx.pvt` 包（JPG + MOV），走 AirDrop 传给别的设备
- **转换记录**：SwiftData 落库，可删除

## 目录结构

```
LiveMoment/
├── LiveMoment.xcodeproj/
├── project.yml                  # XcodeGen 备用工程描述
├── scripts/build_ipa.sh         # 编译 + 打包未签名 .ipa（Mac 与 CI 共用）
├── .github/workflows/build-ios.yml  # 云端 macOS 编译工作流
├── 安装到手机指南.md             # 从零到装上 iPhone 的完整步骤
└── LiveMoment/
    ├── LiveMomentApp.swift      # 入口 + SwiftData 容器
    ├── ContentView.swift        # 三 Tab：制作 / 记录 / 设置
    ├── Models/
    │   ├── ClipSelection.swift       # 选区模型（起点 / 长度 / 倍速 + 夹取逻辑）
    │   ├── ConvertedItem.swift       # 转换记录（SwiftData @Model）
    │   └── VideoTransfer.swift       # 相册/文件 → 沙盒
    ├── Services/
    │   ├── VideoLoader.swift         # 元信息 / 缩略图 / 抽帧
    │   ├── LivePhotoBuilder.swift    # ★ 核心引擎（裁剪 + 变速 + 元数据）
    │   ├── PhotoLibraryService.swift # 相册写入
    │   ├── ExportService.swift       # .pvt 配对文件导出
    │   └── LoopingPlayer.swift       # 选区循环播放器（带倍速与拖动跟随）
    ├── ViewModels/EditorViewModel.swift
    ├── Views/                        # 首页 / 编辑器 / 时间轴 / 结果 / 记录 / 设置
    └── Utilities/
```

---

## 技术实现：为什么这样做是对的

实况照片**不是一种新格式**，而是「一张静态主图 + 一段短视频」加上一对**相同的配对标识**：

| 位置       | 写入内容                                                                    |
| -------- | ----------------------------------------------------------------------- |
| 照片（JPEG） | Apple MakerNote **标签 17**（`kCGImagePropertyMakerAppleDictionary["17"]`） |
| 视频（MOV）  | QuickTime 元数据 `com.apple.quicktime.content.identifier`                  |
| 两侧       | **完全一致的 UUID**                                                          |

`LivePhotoBuilder` 的流水线：

1. **抽封面帧** —— `AVAssetImageGenerator`，开 `appliesPreferredTrackTransform` 保证竖屏素材抽出来也是竖的；`maximumSize` 用视频原生分辨率，保证封面与视频轨道尺寸一致
2. **写静态主图** —— `CGImageDestination` 输出 JPEG，同时写进 MakerNote 17
3. **裁剪 + 转码** —— `AVMutableComposition` 按 `CMTimeRange` 截取（顺便决定要不要音轨），`AVAssetExportSession` 用 `AVAssetExportPresetHEVCHighestQuality` 输出 `.mov`，并把 UUID 写进 `session.metadata`
4. **写入相册** —— `PHAssetCreationRequest.forAsset()` 添加 `.photo` 与 `.pairedVideo` 两个资源，系统读取两侧标识完成绑定

### 变速是怎么做的

预览和成品的实现路径完全不同，这一点容易搞混：

| 阶段   | 手段                                                                     | 说明                                        |
| ---- | ---------------------------------------------------------------------- | ----------------------------------------- |
| 编辑预览 | `AVPlayer.rate` + `defaultRate`                                        | 只影响观感，不改文件；`defaultRate` 保证 seek/缓冲之后速率不丢 |
| 成品输出 | `AVMutableCompositionTrack.scaleTimeRange`                             | **真正改写时间轴**：把 6 秒素材映射到 3 秒，而不是丢一半帧        |
| 音频   | `AVMutableAudioMixInputParameters.audioTimePitchAlgorithm = .spectral` | 变速不变调，慢放不闷、快放不尖                           |

三个必须注意的点：

- `scaleTimeRange` **不会**被合成轨自动继承，视频轨和音频轨要各自调用一次，否则会出现「画面快放了但声音没变」的错位
- 音高算法只在 `scaleTimeRange` 存在时生效，1× 时整条变速链路会被跳过——已验证可用的原始路径保持字节级不变
- 变速后仍然只走一次导出，不做二次转码，避免画质二次损失

### 几个容易踩的坑（都在代码里处理了）

- **必须是 MOV 容器**：`session.outputFileType = .mov`，MP4 会被相册拒绝
- **HEVC 失败有兜底**：拿不到 HEVC 会话时退回 `AVAssetExportPresetHighestQuality`
- **旋转信息要带过去**：合成轨上手动回填 `preferredTransform`，否则竖屏视频会被压扁
- **选区要先跟素材时长求交集**：源文件的时长元数据偶尔比实际可解码内容长一点，直接 `insertTimeRange` 会抛错把整个转换带崩
- **封面帧必然有损**：H.264/H.265 是帧间压缩，任何工具都无法无损抠出静帧，只能重新编码（质量给到 0.95）
- **`still-image-time` 时间元数据轨未手写**：相册路径由 iOS 自行补全，不受影响；仅「文件导出」模式下极少数第三方相册 App 可能要求它

---

## 时长与倍速的换算关系

这是整个编辑器里最容易绕晕的地方，一句话记牢：

```
输出时长 = 源片段长度 ÷ 播放倍速
```

于是：

- **调倍速保持源片段不变** —— 因为用户调倍速时想的是「这段动作太快/太慢」，不是总时长
- **调目标时长保持起点不变** —— 自动反推需要多长的源片段
- **源片段上限随倍速浮动** —— 1× 时最多 5 秒，2× 时能到 10 秒（因为压缩后还是 5 秒）

| 源片段   | 倍速   | 输出时长  | 适用场景         |
| ----- | ---- | ----- | ------------ |
| 3.0 秒 | 1×   | 3.0 秒 | 最接近系统原生实况照片  |
| 6.0 秒 | 2×   | 3.0 秒 | 一段完整动作塞进 3 秒 |
| 1.5 秒 | 0.5× | 3.0 秒 | 把一瞬间的细节拉慢看清  |

硬上限：输出 0.5～5 秒，源片段 0.4～20 秒。系统原生实况照片的惯例是 **3 秒**，超过 3 秒部分第三方 App 可能当成普通视频，编辑器里会给出橙色提示。

---

## 已知限制

- **微信、QQ 会剥离元数据**：实况照片直接发过去会散成「一张图 + 一段视频」。这是平台行为，任何客户端都无法绕过。要分享请用结果页的「保存配对文件」+ AirDrop
- 依赖系统转码能力，个别冷门编码（如某些 HDR/ProRes）可能转换失败，已有降级路径兜底
- 临时产物放在 `tmp/LiveMomentWork`，每次重新生成前会回收上一轮，iOS 也会在空间紧张时自动清理

## 后续可以加

- 相机直接拍摄后转实况图
- 分段变速（同一个片段里先慢后快），需要拆成多段 `scaleTimeRange`
- 壁纸模式（精确 0.916667s + `-video_track_timescale 600`）
- Android 动态照片（单文件拼接）导出，实现跨平台互通
