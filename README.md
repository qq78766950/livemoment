# LiveMoment · 实况录影

一款把**任意视频**转换成 **iOS 原生实况照片（Live Photo）** 的 App。

现拍一段，或挑一段视频 → 拖手柄截出想要的片段 → 定好时长、调个快慢 → 选好封面帧 → 直接存进系统相册，长按就能播放动态与声音。
想做锁屏壁纸可以开**壁纸模式**，想发给安卓手机可以导出**动态照片（单文件）**。

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

想确认编出来的 .ipa 里到底有没有某个能力，用仓库里的核验脚本查一遍（只读，不解压到磁盘）：

```bash
python scripts/verify_ipa_features.py dist/livemoment-unsigned.ipa
```

它按三层判据做检查，判据本身也写在脚本开头：Swift **类型名**走 `__swift5_types`
的类型元数据（Release 也 strip 不掉）、ObjC **选择器与类名**在 `__objc_methname`
数据段里、**长字符串字面量**只有超 15 字节的才落到 `__TEXT,__cstring`。
反过来三类探针写出来必然是空手而归，别踩：Swift 方法名（符号被 strip）、
只读属性的 getter 名（代码只赋值时二进制里只有 `setXxx:`）、
**从未被调用过的函数**（整个函数连同它的选择器一起被优化器剥掉）。

首次运行会请求「添加到照片库」权限，这是保存实况照片必须的；进「拍摄一段」时会先请求相机与麦克风权限再开会话（不给也不影响从相册或文件导入）。相机权限被拒会明确提示去设置里开；麦克风被拒不拦人，只是录成无声、并在界面挂一句说明。

---

## 功能

- **相机直接拍摄**：`AVCaptureSession` + `AVCaptureMovieFileOutput`，带声音、可前后切换、随设备方向旋转；拍完直接进编辑器
- **相册 / 文件 双入口导入**：`PhotosPicker` 与 `.fileImporter`，视频统一拷贝到沙盒后再处理
- **时间轴片段选择**：缩略图底图 + 双手柄拖拽；**拖选区中间可整段平移**，在长视频里挪位置不用重新拉长度
- **拖动即时预览**：拖手柄/平移的过程中播放器暂停并低延迟跟随到边界那一帧，拖到哪儿看得见，不用松手才知道
- **时长可调**：1 / 2 / 3 / 5 秒快捷档 + ±0.1 秒微调，按「目标输出时长」反推需要多长的源片段
- **0.5× ~ 2× 变速**：预览实时变速；成品走 `scaleTimeRange` 真正改写时间轴，并配 `.spectral` 音高算法做到**变速不变调**
- **分段变速**：同一段素材里先慢后快（或反过来），4 段线性过渡；预览按同一条曲线实时变速，成品逐段 `scaleTimeRange`
- **壁纸模式**：输出钉在 `550/600` 秒、视频轨时间基压到 `600`、写入 `still-image-time` 时间元数据轨并补 `live-photo.*` 静态字段
- **安卓动态照片导出**：单文件拼接（JPEG + MP4 + XMP），两套 XMP 字段都写，文件名按规范以 `MP` 结尾
- **封面帧挑选**：滑块在选区内实时抽帧，相册里看到的那张静图由它决定（壁纸模式固定取最后一帧）
- **主图格式可选**：`HEIC`（系统相机原生形态，体积约为 JPEG 一半）或 `JPEG`（通用性最好），写完自动校验配对标识是否落盘
- **保留 / 关闭原声**：关闭后合成轨道只保留视频
- **循环预览**：编辑时播放器在选区内按当前配置循环，直接预览「按压播放」的实际手感
- **一键写入相册**：`PHAssetCreationRequest(.photo + .pairedVideo)`，产出的是**原生**实况照片
- **结果页预览**：`PHLivePhotoView` 播放转换结果，规格（含变速、壁纸状态与格式信息）一目了然
- **配对文件导出**：生成 `IMG_xxx.pvt` 包（HEIC/JPG + MOV），走 AirDrop 传给别的设备
- **转换记录**：SwiftData 落库，可删除

## 目录结构

```
LiveMoment/
├── LiveMoment.xcodeproj/
├── project.yml                  # XcodeGen 备用工程描述
├── scripts/build_ipa.sh         # 编译 + 打包未签名 .ipa（Mac 与 CI 共用）
├── scripts/verify_ipa_features.py   # 只读核验 .ipa 里各能力是否真的编进去了
├── .github/workflows/build-ios.yml  # 云端 macOS 编译工作流
├── 安装到手机指南.md             # 从零到装上 iPhone 的完整步骤
└── LiveMoment/
    ├── LiveMomentApp.swift      # 入口 + SwiftData 容器
    ├── ContentView.swift        # 三 Tab：制作 / 记录 / 设置
    ├── Models/
    │   ├── ClipSelection.swift       # 选区模型（起点 / 长度 / 倍速 / 分段 / 壁纸 + 夹取逻辑）
    │   ├── SpeedRamp.swift           # 分段变速（起速、终速、等效倍速）
    │   ├── StillImageFormat.swift    # 主图格式（HEIC / JPEG）
    │   ├── ConvertedItem.swift       # 转换记录（SwiftData @Model）
    │   └── VideoTransfer.swift       # 相册/文件 → 沙盒
    ├── Services/
    │   ├── VideoLoader.swift         # 元信息 / 缩略图 / 抽帧
    │   ├── CameraRecorder.swift      # ★ 相机拍摄（录制 / 权限 / 方向 / 前后切换）
    │   ├── LivePhotoBuilder.swift    # ★ 核心引擎（逐段裁剪 + 变速 + 元数据）
    │   ├── WallpaperFinisher.swift   # ★ 壁纸后处理（时间基 600 + still-image-time 轨）
    │   ├── StillImageWriter.swift    # ★ 主图编码 + 配对标识回读校验
    │   ├── MotionPhotoExporter.swift # ★ 安卓动态照片（单文件拼接 + XMP）
    │   ├── PhotoLibraryService.swift # 相册写入
    │   ├── ExportService.swift       # .pvt 配对文件导出
    │   └── LoopingPlayer.swift       # 选区循环播放器（带倍速曲线与拖动跟随）
    ├── ViewModels/EditorViewModel.swift
    ├── Views/                        # 首页 / 拍摄 / 编辑器 / 时间轴 / 结果 / 记录 / 设置
    └── Utilities/
```

---

## 技术实现：为什么这样做是对的

实况照片**不是一种新格式**，而是「一张静态主图 + 一段短视频」加上一对**相同的配对标识**：

| 位置       | 写入内容                                                                    |
| -------- | ----------------------------------------------------------------------- |
| 照片（HEIC / JPEG） | Apple MakerNote **标签 17**（`kCGImagePropertyMakerAppleDictionary["17"]`） |
| 视频（MOV）  | QuickTime 元数据 `com.apple.quicktime.content.identifier`                  |
| 两侧       | **完全一致的 UUID**                                                          |

`LivePhotoBuilder` 的流水线：

1. **抽封面帧** —— `AVAssetImageGenerator`，开 `appliesPreferredTrackTransform` 保证竖屏素材抽出来也是竖的；`maximumSize` 用视频原生分辨率，保证封面与视频轨道尺寸一致。壁纸模式固定取片段**最后一帧**
2. **写静态主图** —— `CGImageDestination` 输出 HEIC 或 JPEG（默认 HEIC），同时写进 MakerNote 17；写完**立刻回读校验**标识是否真的落盘，不合格自动换另一种格式重写
3. **逐段裁剪 + 转码** —— `AVMutableComposition` 按 `timelineSegments()` 给出的分段逐段 `insertTimeRange` 并逐段 `scaleTimeRange`（顺便决定要不要音轨），`AVAssetExportSession` 用 `AVAssetExportPresetHEVCHighestQuality` 输出 `.mov`，并把 UUID 写进 `session.metadata`
4. **壁纸归一化（仅壁纸模式）** —— 对整段再显式 `scaleTimeRange` 到 `CMTime(value: 550, timescale: 600)`
5. **重封装（仅壁纸模式）** —— `WallpaperFinisher` 用 `AVAssetReader`/`AVAssetWriter` 原样搬运压缩样本，顺带把时间基换算到 600 并写入 `still-image-time` 时间元数据轨
6. **写入相册** —— `PHAssetCreationRequest.forAsset()` 添加 `.photo` 与 `.pairedVideo` 两个资源，系统读取两侧标识完成绑定

### 主图格式：为什么默认写成 HEIC

静态主图这一半有两种写法，App 里可以随时切换，默认是 `HEIC`。

| 格式 | 体积 | 定位 |
| --- | --- | --- |
| **HEIC**（默认） | 约为 JPEG 的一半 | 系统相机在「高效」模式下拍出的原生形态，也是苹果最认的那条路 |
| JPEG | 基准 | 通用性最好，任何环境都能直接查看 |

选 HEIC 不只是为了省空间，还因为一个很隐蔽的坑：**iOS 15.1 起，ImageIO 往 JPEG 里写 `kCGImagePropertyMakerAppleDictionary` 时可能直接把它丢掉**——而配对标识恰好就存在那个字典里。

更麻烦的是这种失败**不会报错**：`CGImageDestinationFinalize` 照样返回 `true`，文件也是一张好图，只是标识没进去。等用户把成品存进相册、长按却纹丝不动时才会发现。

所以 `StillImageWriter` 在编码之后做了一件别处通常不会做的事——**把文件读回来，比对 Apple MakerNote 标签 17 是否等于刚写进去的那个 UUID**：

- 校验通过 → 采用
- 校验不通过（或该格式根本编不出来）→ 换另一种格式重写，并在结果页如实说明发生了回退
- 两种都写不进去 → 保留图片本身，同时在结果页给出警告，而不是假装成功

视频那一半永远是 HEVC / MOV，不受这个选项影响——苹果的实况照片并不是把动图塞进 HEIF 的那套做法。

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

### 分段变速：为什么是调和平均

「同一段里先慢后快」在模型上就是把选区等分成 4 段，各段给一个倍速（起速 → 终速线性过渡）。
实现上不引入新概念，只影响两处：`timelineSegments()` 拆出的分段，以及整段的**等效倍速**。

等效倍速取的是各段倍速的**调和平均**，不是算术平均。因为：

```
总输出时长 = Σ(源段长 ÷ 段倍速)
```

源段长相等时，它等于 `总源长 ÷ 调和平均`。以 0.5× 与 2× 各占一半为例：

| 算法 | 结果 | 后果 |
| --- | --- | --- |
| 算术平均 | 1.25× | 时长被算短，时间轴长度上限与时长档位全部错位 |
| **调和平均** | 0.8× | 与逐段累加的实际结果一致 |

预览用同一组速度值拼出一条曲线（时间观察器每 0.1 秒按进度改一次 `AVPlayer.rate`），
所以按下生成之前就能看出节奏对不对，不存在「预览一套、成品另一套」。

### 壁纸模式：三个条件，以及一个凑不出来的

iOS 判定一张实况照片能否当锁屏壁纸，会看三样东西。壁纸模式逐个满足：

| 条件 | 做法 |
| --- | --- |
| 时长恰好 `550/600` 秒（0.916667） | 逐段缩放之后**再显式归一化一次**到 `CMTime(value: 550, timescale: 600)` |
| 视频轨媒体时间基为 600 | 重封装时把每个样本的 PTS/DTS 换算到 600——`AVAssetWriter` 用**第一个样本的时间戳时间基**作为轨道媒体时间基，这等价于 ffmpeg 的 `-video_track_timescale 600` |
| 标出封面帧的位置 | 写入 `com.apple.quicktime.still-image-time` **时间元数据轨**（`AVAssetWriterInputMetadataAdaptor`） |

后两件 `AVAssetExportSession` 都做不到：它只能写静态元数据，也没有时间基的控制入口，所以必须用
`AVAssetWriter` 再封一遍。视频与音频轨的样本是**原样搬运**的（passthrough，`outputSettings: nil`），
不解码不重编，既不损画质也不慢。同时把配对标识与 `live-photo.auto` / `vitality-score` /
`vitality-scoring-version` 三个静态字段重新写进新文件——重封装**不会**自动继承 `moov/meta`，
漏掉的话连普通实况照片都不是了。

还有一个设计决定：**壁纸模式的封面帧固定在片段最后一帧**。因为 iOS 播放壁纸时只播「封面帧之前」
的那一小段，封面放在末尾，整段 0.9167 秒才播得出来。

重封装完成后会回读校验时长与时间基；不达标就丢弃这次重封装的结果、保留原来的导出文件，
并在结果页如实说明——不会把「可能不行」包装成「已完成」。

**有一件事做不到**：真实拍摄的实况照片还带一条 `com.apple.quicktime.live-photo-info` 时间元数据轨，
里面是每帧一段的陀螺仪/加速度读数。那是拍摄时的真实传感器数据，格式也没公开，编不出来。
所以壁纸模式能备齐所有可备齐的条件，但最终认不认仍由 iOS 现场决定。

### 安卓动态照片：完全不同的另一条路线

| 部件 | 苹果实况照片 | 安卓动态照片 |
| --- | --- | --- |
| 结构 | HEIC/JPG + MOV **两个文件** | **单个 JPG**（JPEG 后面直接接 MP4） |
| 绑定方式 | 照片 MakerNote 17 ↔ 视频 `content.identifier` | JPEG 里的 XMP 字节偏移 |
| 视频编码 | HEVC / MOV | H.264 / MP4（安卓那套解析器对 HEVC 支持参差） |

`MotionPhotoExporter` 的流程：主图重编码成 JPEG（原来可能是 HEIC）→ 视频转 H.264/MP4 并把
`moov` 放到文件头 → 把 XMP 段插到 JPEG 的 SOI 之后 → 把 MP4 接在文件末尾 → 文件名按规范以
`MP` 结尾（如 `IMG_20261014_175337MP.jpg`）。

XMP 里**两套标准一起写**：

- 旧标准 `Camera:MicroVideo` / `MicroVideoVersion` / `MicroVideoOffset` / `MicroVideoPresentationTimestampUs`
- 新标准 `Camera:MotionPhoto` / `MotionPhotoVersion` / `MotionPhotoPresentationTimestampUs`
  \+ `Container:Directory` 容器目录（`Item:Mime` / `Item:Semantic` / `Item:Length` / `Item:Padding`）

新规范已把 `MicroVideo*` 标为「存在则忽略」，但仍有大量老解析器只认它；同时写两边兼容面最大。
`MicroVideoOffset` 与 `Item:Length` 都是视频的字节数——也就是「从文件末尾往前数多少字节」。

呈现时间戳（微秒）不能直接拿封面帧的源时间来用：变速之后源时间轴与成品时间轴不是一个坐标系，
必须按段累加换算（`ClipSelection.outputTime(forOffset:)`）。

### 几个容易踩的坑（都在代码里处理了）

- **必须是 MOV 容器**：`session.outputFileType = .mov`，MP4 会被相册拒绝
- **HEVC 失败有兜底**：拿不到 HEVC 会话时退回 `AVAssetExportPresetHighestQuality`
- **旋转信息要带过去**：合成轨上手动回填 `preferredTransform`，否则竖屏视频会被压扁；重封装时同样要设 `AVAssetWriterInput.transform`
- **选区要先跟素材时长求交集**：源文件的时长元数据偶尔比实际可解码内容长一点，直接 `insertTimeRange` 会抛错把整个转换带崩（分段之后是逐段夹取，跳过超界的那一段）
- **封面帧必然有损**：H.264/H.265 是帧间压缩，任何工具都无法无损抠出静帧，只能重新编码
- **iOS 15.1 起 JPEG 可能留不住配对标识**：见上文「主图格式」一节，默认走 HEIC，并且每次都做回读校验
- **设备方向与界面方向是反的**：`UIDeviceOrientation.landscapeLeft` 对应的是 `UIInterfaceOrientation.landscapeRight`，相机旋转角映射时要「翻」一次，照抄同名值会把横屏视频转 180°
- **切换摄像头别把麦克风也摘了**：按输入类型过滤，只摘视频输入，否则切一次之后录出来就无声
- **`AVErrorRecordingSuccessfullyFinishedKey`**：达到时长上限时 `didFinishRecording` 也带 error，但文件是好的，得看这个 key 判断而不是一律当失败
- **重封装不会继承 `moov/meta`**：配对标识与 `live-photo.*` 字段必须在 `AVAssetWriter.metadata` 上重新写一遍
- **多帧样本不能强行换算时间基**：`CMSampleBufferCreateCopyWithNewTiming` 只给一个 timing 条目时，多帧 buffer 会错位；代码里只对单帧（视频轨的常态）做换算，其余原样放行
- **安卓的 XMP 段有 64KB 上限**：插的是单个 APP1 段，超了就抛错，不会写出一个半截文件

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

分段变速下公式变成逐段累加，等效倍速按调和平均折算（见上文）。**壁纸模式是这套关系的反向用法**：
输出时长被钉死在 0.9167 秒，能调的只剩源片段长度，倍速由它反推——源 2 秒 → 约 2.2×。

---

## 已知限制

- **微信、QQ 会剥离元数据**：实况照片直接发过去会散成「一张图 + 一段视频」。这是平台行为，任何客户端都无法绕过。要分享请用结果页的「保存配对文件」+ AirDrop
- **HEIC 在苹果生态外兼容性一般**：把 `.pvt` 导出给 Android 或老旧设备看时，主图切到 JPEG 更稳妥；视频那一半两种格式完全一样
- **壁纸资格无法在本机判定**：`live-photo-info` 那条传感器轨编不出来（见上文），所以壁纸模式备齐了所有能备齐的条件，最终仍由 iOS 现场决定。结果页会显示后处理是否完成
- **安卓动态照片在 iOS 上只是一张普通照片**：iOS 不解安卓那套拼接格式，这是双向的不兼容，不是缺陷
- 依赖系统转码能力，个别冷门编码（如某些 HDR/ProRes）可能转换失败，已有降级路径兜底
- 相机拍摄依赖真机；模拟器没有摄像头，需要手动指定相机输入
- 临时产物放在 `tmp/LiveMomentWork`，每次重新生成前会回收上一轮，iOS 也会在空间紧张时自动清理

## 还没做 / 做不到

- **合成 `live-photo-info` 传感器轨**：需要真实拍摄时的每帧陀螺仪数据，且数据格式未公开。想提高壁纸成功率的话，可行路线是从一张真实拍摄的实况照片里**移植**这条轨——和那个反编译包里的作者用的是同一招
- **关键帧曲线变速**：现在是分段线性（每段恒定倍速），不是连续 Bézier 缓动
- **HDR / 杜比视界透传**：会统一转成 SDR HEVC
