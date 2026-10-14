import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把一次转换的结果再导出一份**安卓动态照片**（单文件拼接）。
///
/// 安卓的动态照片是「一张 JPEG + 一段 MP4 焊在一个文件里」：
/// 前半段是完整的 JPEG，后半段是完整的 MP4，靠 JPEG 里的一段 XMP 元数据
/// 告诉读取方「视频从文件末尾往前数 N 个字节开始」。
/// 和苹果的双文件方案是两条完全不同的路线，所以不能复用同一份产物：
///
/// | 部件 | 苹果实况照片 | 安卓动态照片 |
/// |---|---|---|
/// | 结构 | HEIC/JPG + MOV 两个文件 | 单个 JPG（JPEG 后面直接接 MP4） |
/// | 绑定方式 | 照片 MakerNote 17 ↔ 视频 content.identifier | JPEG 里的 XMP 字节偏移 |
/// | 视频编码 | HEVC / MOV | H.264 / MP4（安卓那套解析器对 HEVC 支持参差） |
///
/// 另外两件必须做对的事：
/// - **文件名要以 `MP` 结尾**（如 `IMG_20261014_175337MP.jpg`）。这是 Google 规范里
///   对写入方的要求，部分机型的相册与第三方解析器会按这个正则筛文件。
/// - **两套 XMP 字段都写**。旧标准 `Camera:MicroVideo*` 已被规范标记为「存在则忽略」，
///   但仍有大量老解析器只认它；新标准 `Camera:MotionPhoto*` + `Container:Directory`
///   是 Pixel、三星、小米 HyperOS 3 之后在用的。同时写两边，兼容面最大。
enum MotionPhotoExporter {

    struct Output {
        let url: URL
        /// 追加在 JPEG 后面的视频字节数。
        let videoByteCount: Int
        /// 视频起点距文件末尾的字节数。规范里 `MicroVideoOffset` 正是这个值。
        let offsetFromEnd: Int
        /// 封面帧在视频里的呈现时间戳（微秒）。
        let presentationTimestampUs: Int64
        let jpegByteCount: Int
        let totalByteCount: Int
    }

    // MARK: - 入口

    /// 生成动态照片并写到沙盒「文件」目录。返回落盘地址，交给 ShareLink 分享。
    static func export(_ result: BuiltLivePhoto, baseName: String) async throws -> Output {
        let manager = FileManager.default

        // 1) 主图重编码成 JPEG。原来可能是 HEIC——HEIC 拼接虽然也在 2023 版规范里，
        //    但支持面窄得多，几乎没人认。
        let jpegURL = try writeJPEG(from: result.photoURL)
        defer { try? manager.removeItem(at: jpegURL) }

        // 2) 视频转成 H.264 / MP4。
        let mp4URL = manager.temporaryDirectory
            .appendingPathComponent("LiveMomentAndroid-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer { try? manager.removeItem(at: mp4URL) }
        try await transcodeToMP4(source: result.videoURL, destination: mp4URL)

        let jpegData = try Data(contentsOf: jpegURL)
        let videoData = try Data(contentsOf: mp4URL)

        // 3) XMP 插进 JPEG，再把 MP4 接在文件末尾。
        let stamped = try embedXMP(
            in: jpegData,
            videoByteCount: videoData.count,
            presentationTimestampUs: result.androidPresentationTimestampUs
        )
        var payload = stamped
        payload.append(videoData)

        guard let documents = try? manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw LivePhotoError.exportFolderFailed("拿不到沙盒目录")
        }

        // 文件名以 MP 结尾是规范要求，别改
        let target = documents
            .appendingPathComponent(baseName + "MP")
            .appendingPathExtension("jpg")
        try? manager.removeItem(at: target)
        do {
            try payload.write(to: target, options: .atomic)
        } catch {
            throw LivePhotoError.exportFolderFailed(error.localizedDescription)
        }

        return Output(
            url: target,
            videoByteCount: videoData.count,
            offsetFromEnd: videoData.count,
            presentationTimestampUs: result.androidPresentationTimestampUs,
            jpegByteCount: stamped.count,
            totalByteCount: payload.count
        )
    }

    // MARK: - 主图

    /// 把结果里的主图重新编码成 JPEG，并顺手去掉只对苹果有意义的 Apple MakerNote。
    private static func writeJPEG(from stillURL: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(stillURL as CFURL, nil) else {
            throw LivePhotoError.imageWriteFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveMomentAndroidStill-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try? FileManager.default.removeItem(at: url)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoError.imageWriteFailed
        }

        // 用 AddImageFromSource 而不是 AddImage：前者会继承已经成型的 EXIF/TIFF 结构，
        // 拍摄时间、机型这些信息能带过来，不用逐项重建。
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.95
        metadata[kCGImagePropertyOrientation] = 1
        // 苹果那套配对标识对安卓没有意义，留着只会干扰解析
        metadata.removeValue(forKey: kCGImagePropertyMakerAppleDictionary)

        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.imageWriteFailed
        }
        return url
    }

    // MARK: - 视频

    private static func transcodeToMP4(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        try? FileManager.default.removeItem(at: destination)

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LivePhotoError.exportSessionUnavailable
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        // moov 放到文件头。安卓那边有按流式解析的实现，moov 在尾部时会直接卡住。
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw LivePhotoError.exportFailed(session.error?.localizedDescription ?? "转 MP4 失败")
        }
    }

    // MARK: - XMP 注入

    /// 把 XMP 段插到 JPEG 的 SOI 之后。
    ///
    /// JPEG 的段结构是「FFD8（SOI）后面挂一串 FFE? 段」，XMP 走 APP1（FFE1）。
    /// 插在 SOI 之后是最省事的做法：解析方按标记逐个扫描 APPn，位置无所谓。
    private static func embedXMP(
        in jpeg: Data,
        videoByteCount: Int,
        presentationTimestampUs: Int64
    ) throws -> Data {
        guard jpeg.count > 4 else { throw LivePhotoError.imageWriteFailed }

        let signature = Array("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let payload = signature + Array(xmpPacket(
            videoByteCount: videoByteCount,
            presentationTimestampUs: presentationTimestampUs
        ).utf8)

        // 段长字段本身占 2 字节，且要算在长度里
        let segmentLength = payload.count + 2
        guard segmentLength <= 0xFFFF else {
            throw LivePhotoError.exportFolderFailed("XMP 段超过单段 64KB 上限")
        }

        var output = Data()
        output.append(contentsOf: [0xFF, 0xD8])          // SOI
        output.append(contentsOf: [0xFF, 0xE1])          // APP1
        output.append(UInt8((segmentLength >> 8) & 0xFF))
        output.append(UInt8(segmentLength & 0xFF))
        output.append(contentsOf: payload)
        output.append(jpeg.subdata(in: 2..<jpeg.count))  // 原图去掉 SOI 的其余部分
        return output
    }

    /// 两套标准一起写。字段含义：
    /// - `MicroVideoOffset` / `Item:Length`：视频的字节数，也就是「从文件末尾往前数多少」
    /// - `...PresentationTimestampUs`：封面帧在视频里的呈现时间戳（微秒）
    private static func xmpPacket(videoByteCount: Int, presentationTimestampUs: Int64) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="LiveMoment">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:Camera="http://ns.google.com/photos/1.0/camera/"
            xmlns:Container="http://ns.google.com/photos/1.0/container/"
            xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
            Camera:MicroVideo="1"
            Camera:MicroVideoVersion="1"
            Camera:MicroVideoOffset="\(videoByteCount)"
            Camera:MicroVideoPresentationTimestampUs="\(presentationTimestampUs)"
            Camera:MotionPhoto="1"
            Camera:MotionPhotoVersion="1"
            Camera:MotionPhotoPresentationTimestampUs="\(presentationTimestampUs)">
           <Container:Directory>
            <rdf:Seq>
             <rdf:li rdf:parseType="Resource">
              <Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/>
             </rdf:li>
             <rdf:li rdf:parseType="Resource">
              <Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="\(videoByteCount)" Item:Padding="0"/>
             </rdf:li>
            </rdf:Seq>
           </Container:Directory>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}
