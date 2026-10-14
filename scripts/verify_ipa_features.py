"""核验新 IPA 里四个新能力是否真的被编进去了。

只读：把 IPA 当 zip 打开，读主二进制与 Info.plist，不做解压落盘、不改文件。

判据分三层：
  1. 类型元数据 —— Swift 类型名以「长度+名字」的 mangling 片段出现在二进制的
     __swift5_types 里，例如 CameraRecorder -> 14CameraRecorder。
  2. 选择器 / 类名 —— 调 ObjC API 时编译器会把选择器字符串写进
     __objc_methname / __objc_classname，例如 scaleTimeRange:toDuration:。
  3. 长字符串字面量 —— Swift 只把超过 15 个 UTF-8 字节的字面量落到
     __TEXT,__cstring；多行字面量（三个双引号包起来的那种）则一律落盘。
     所以「短于 16 字节的短中文标题」查不到属正常，这里只查确实会落盘的那些。
"""
import os
import plistlib
import sys
import zipfile

IPA = sys.argv[1] if len(sys.argv) > 1 else r"dist/livemoment-unsigned.ipa"

# (探针字节, 说明, 归属能力)
#
# 注意几类「看着该有、其实不会有」的探针，别写成它们：
#   - Swift 的方法名。Release 构建会 strip 符号表，方法名的 mangled 串就没了；
#     只有类型名还能在 __swift5_types 的类型元数据里找到（那一段是数据不是符号）。
#   - 只读的 ObjC 属性名。代码里只赋值的话，二进制里只有 setXxx: 没有 getter 名。
#   - 从没被调用过的函数。整个函数连同它的选择器一起被优化器剥掉。
PROBES = [
    # --- 相机拍摄 ---
    (b"14CameraRecorder", "Swift 类型 CameraRecorder", "相机"),
    (b"17CameraCaptureView", "Swift 类型 CameraCaptureView", "相机"),
    (b"AVCaptureMovieFileOutput", "ObjC 类 AVCaptureMovieFileOutput", "相机"),
    (b"AVCaptureVideoPreviewLayer", "ObjC 类 AVCaptureVideoPreviewLayer", "相机"),
    (b"requestAccessForMediaType:completionHandler:", "权限申请选择器", "相机"),
    (b"startRecordingToOutputFileURL:recordingDelegate:", "开始录制选择器", "相机"),
    (b"setVideoRotationAngle:", "录制轨旋转角", "相机"),
    (b"setVideoMirrored:", "前置镜像", "相机"),

    # --- 分段变速 ---
    (b"9SpeedRamp", "Swift 类型 SpeedRamp", "变速"),
    (b"scaleTimeRange:toDuration:", "AVMutableCompositionTrack 选择器", "变速"),
    (b"setAudioTimePitchAlgorithm:", "保音高算法（只赋值，故无 getter 名）", "变速"),
    (b"rateProfile", "预览速率曲线字段", "变速"),
    (b"previewSpeedProfile", "速度曲线求值方法", "变速"),

    # --- 壁纸模式 ---
    (b"17WallpaperFinisher", "Swift 类型 WallpaperFinisher", "壁纸"),
    (b"com.apple.quicktime.still-image-time", "still-image-time 轨标识", "壁纸"),
    (b"mdta/com.apple.quicktime.still-image-time", "still-image-time 完整标识", "壁纸"),
    (b"AVAssetWriterInputMetadataAdaptor", "时间元数据写入器", "壁纸"),
    (b"com.apple.quicktime.live-photo.auto", "壁纸静态字段 auto", "壁纸"),
    (b"com.apple.quicktime.live-photo.vitality-score", "壁纸静态字段 vitality", "壁纸"),
    (b"vitality-scoring-version", "壁纸静态字段 scoring-version", "壁纸"),
    (b"requestMediaDataWhenReadyOnQueue:usingBlock:", "重封装搬运样本", "壁纸"),

    # --- 安卓动态照片 ---
    (b"19MotionPhotoExporter", "Swift 类型 MotionPhotoExporter", "安卓"),
    (b"Camera:MotionPhoto", "新标准 Camera:MotionPhoto*", "安卓"),
    (b"Container:Directory", "新标准容器目录", "安卓"),
    (b"Camera:MicroVideo", "旧标准 Camera:MicroVideo*", "安卓"),
    (b"Camera:MicroVideoOffset", "旧标准字节偏移字段", "安卓"),
    (b"MotionPhotoPresentationTimestampUs", "XMP 时间戳字段", "安卓"),
    (b"video/mp4", "拼接段 MIME 类型", "安卓"),
    (b"image/jpeg", "主图 MIME 类型", "安卓"),

    # --- 通用 ---
    (b"com.apple.quicktime.content.identifier", "实况配对标识", "通用"),
]


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024.0


def main():
    if not os.path.exists(IPA):
        print("找不到文件:", IPA)
        return 1

    size = os.path.getsize(IPA)
    print("=" * 72)
    print(f"核验目标: {IPA}")
    print(f"文件大小: {human(size)} ({size:,} 字节)")
    print("=" * 72)

    with zipfile.ZipFile(IPA) as z:
        names = z.namelist()

        app_dir = None
        for n in sorted(names):
            if n.startswith("Payload/") and ".app/" in n:
                app_dir = n[: n.index(".app/") + 5]
                break
        if not app_dir:
            print("未识别到 .app 主包")
            return 1

        # Info.plist：相机 / 麦克风权限声明
        info_path = app_dir + "Info.plist"
        exe = None
        if info_path in names:
            with z.open(info_path) as fh:
                pl = plistlib.load(fh)
            exe = pl.get("CFBundleExecutable")
            print("\n【Info.plist 权限声明】")
            for k in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                      "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"):
                v = pl.get(k)
                mark = "OK " if v else "缺失"
                print(f"  [{mark}] {k}: {v}")
            print(f"  版本: {pl.get('CFBundleShortVersionString')}({pl.get('CFBundleVersion')})"
                  f"  最低系统: {pl.get('MinimumOSVersion')}")

        if not exe:
            print("没有 CFBundleExecutable，无法核对二进制")
            return 1

        bin_path = app_dir + exe
        if bin_path not in names:
            print("主二进制不在包里:", bin_path)
            return 1

        with z.open(bin_path) as fh:
            blob = fh.read()

    print(f"\n【主二进制】{bin_path}")
    print(f"  体积: {human(len(blob))}")

    print("\n【功能探针】")
    results = {}
    for probe, label, feature in PROBES:
        hits = blob.count(probe)
        results.setdefault(feature, []).append((probe, label, hits))

    order = ["相机", "变速", "壁纸", "安卓", "通用"]
    total_ok = total = 0
    for feature in order:
        rows = results.get(feature, [])
        if not rows:
            continue
        ok = sum(1 for _, _, h in rows if h)
        total_ok += ok
        total += len(rows)
        print(f"\n  ── {feature}  ({ok}/{len(rows)})")
        for probe, label, hits in rows:
            flag = "命中" if hits else "未命中"
            extra = f"x{hits}" if hits else ""
            print(f"    [{flag:>3}] {label:<40} {extra}")

    print("\n" + "=" * 72)
    print(f"探针命中率: {total_ok}/{total}")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
