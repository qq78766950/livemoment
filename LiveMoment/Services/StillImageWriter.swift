import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 静态主图编码器：把封面帧写成带 Apple MakerNote 配对标识的 HEIC 或 JPEG。
///
/// 这个类型做了一件别处通常不会做的事——**写完立刻把文件读回来校验**。
///
/// 原因是配对标识的写入并没有可靠的 API 保证：
/// `kCGImagePropertyMakerAppleDictionary` 只是「请求写入」，
/// `CGImageDestinationFinalize` 即便返回 `true`，标识也可能根本没进文件
/// （iOS 15.1 起对 JPEG 就有这个行为）。这种失败不会报错，
/// 只会在用户把成品存进相册、长按却纹丝不动时暴露出来。
///
/// 所以这里的策略是「逐级降级，每一级都实测」：
///
/// 1. 偏好格式 + 直接编码（最快）
/// 2. 偏好格式 + 两阶段编码（见 `EncodePath.viaSource`）
/// 3. 另一种格式，重复上面两步
/// 4. 全都不行 —— 把图交回去，并如实告诉上层「标识没写进去」
///
/// 每一步都以「回读出来的标识等于刚写进去的那个 UUID」为唯一判据，不靠假设。
enum StillImageWriter {

    /// 一次编码的产物。
    struct Output {
        let url: URL
        /// 实际落盘的格式——可能和调用方偏好的那个不同（发生了回退）。
        let format: StillImageFormat
        /// 是否已确认配对标识真的写进了文件。
        let identifierVerified: Bool
        /// 发生回退或校验失败时的说明，用于给用户一句可解释的话。
        let fallbackReason: String?
    }

    /// Apple MakerNote 里承载配对标识的标签号。
    ///
    /// 即 ExifTool 中显示的 `[Apple] Content Identifier`，
    /// 对应 `kFigAppleMakerNote_AssetIdentifier`（0x0011，十进制 17）。
    /// 视频那一侧的对应物是 `com.apple.quicktime.content.identifier`。
    static let identifierTag = "17"

    /// 写入主图的两条编码路径。
    private enum EncodePath: CaseIterable {
        /// 直接把 CGImage 连同元数据一次写成目标格式。最快，大多数情况下够用。
        case direct
        /// 先编码成目标格式，再读回来带着元数据重写一遍。
        ///
        /// 看起来绕，但这才是社区反复验证过的写法：
        /// `CGImageDestinationAddImageFromSource` 会**继承源文件里已经成型的
        /// 元数据结构**（包括 Apple MakerNote 那个块本身），
        /// 而 `AddImage` 是从零构建，某些系统版本上就是写不进 MakerNote。
        case viaSource
    }

    // MARK: - 对外入口

    /// 按偏好格式写入主图，必要时逐级降级。
    ///
    /// - Parameter preferring: 用户偏好的格式。这不是硬保证，实际格式见 `Output.format`。
    /// - Returns: 实际产物。`identifierVerified == false` 表示所有组合都没能把
    ///   标识写进文件（极罕见），上层应据此提醒用户。
    static func write(
        _ image: CGImage,
        identifier: String,
        preferring preferredFormat: StillImageFormat,
        in folder: URL,
        baseName: String = "LiveMoment"
    ) throws -> Output {
        // 最后手段：某次编码确实产出了完整图片，只是标识没进去。
        var lastResort: Output?

        for format in [preferredFormat, preferredFormat.fallback] {
            for path in EncodePath.allCases {
                guard let output = try? encode(
                    image,
                    identifier: identifier,
                    format: format,
                    path: path,
                    in: folder,
                    baseName: baseName
                ) else { continue }

                if output.identifierVerified {
                    removeCounterpart(of: output.format, in: folder, baseName: baseName)
                    return Output(
                        url: output.url,
                        format: output.format,
                        identifierVerified: true,
                        // 只有真的换了格式才需要跟用户解释；换了编码路径属于实现细节
                        fallbackReason: output.format == preferredFormat
                            ? nil
                            : "\(preferredFormat.displayName) 没能写入配对标识，已改用 \(output.format.displayName)"
                    )
                }

                lastResort = output
            }
        }

        // 两种格式、两条路径都试过了，标识就是写不进去。
        guard let lastResort else { throw LivePhotoError.imageWriteFailed }
        removeCounterpart(of: lastResort.format, in: folder, baseName: baseName)
        return Output(
            url: lastResort.url,
            format: lastResort.format,
            identifierVerified: false,
            fallbackReason: "配对标识没能写入 \(lastResort.format.displayName) 文件"
        )
    }

    // MARK: - 编码调度

    private static func encode(
        _ image: CGImage,
        identifier: String,
        format: StillImageFormat,
        path: EncodePath,
        in folder: URL,
        baseName: String
    ) throws -> Output {
        let url = folder
            .appendingPathComponent(baseName)
            .appendingPathExtension(format.fileExtension)

        try? FileManager.default.removeItem(at: url)

        switch path {
        case .direct:
            try writeDirect(image, identifier: identifier, format: format, to: url)
        case .viaSource:
            try writeViaSource(
                image,
                identifier: identifier,
                format: format,
                to: url,
                in: folder,
                baseName: baseName
            )
        }

        return Output(
            url: url,
            format: format,
            identifierVerified: readIdentifier(at: url) == identifier,
            fallbackReason: nil
        )
    }

    // MARK: - 路径 A：一次写成

    private static func writeDirect(
        _ image: CGImage,
        identifier: String,
        format: StillImageFormat,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            // 该设备或该尺寸不支持这种格式的编码（例如奇数宽高的 HEIC）
            throw LivePhotoError.imageWriteFailed
        }

        var properties = baseProperties(format: format)
        // ★ 实况照片的配对标识就藏在这里：Apple MakerNote 标签 17
        properties[kCGImagePropertyMakerAppleDictionary] = [identifierTag: identifier]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.imageWriteFailed
        }
    }

    // MARK: - 路径 B：先编码，再带着标识重写一遍

    private static func writeViaSource(
        _ image: CGImage,
        identifier: String,
        format: StillImageFormat,
        to url: URL,
        in folder: URL,
        baseName: String
    ) throws {
        // 第一遍：得到一份「结构完整、但还没有配对标识」的目标格式文件。
        let intermediate = folder
            .appendingPathComponent(baseName + "-raw")
            .appendingPathExtension(format.fileExtension)
        try? FileManager.default.removeItem(at: intermediate)

        guard let rawDestination = CGImageDestinationCreateWithURL(
            intermediate as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoError.imageWriteFailed
        }
        defer { try? FileManager.default.removeItem(at: intermediate) }

        CGImageDestinationAddImage(rawDestination, image, baseProperties(format: format) as CFDictionary)
        guard CGImageDestinationFinalize(rawDestination) else {
            throw LivePhotoError.imageWriteFailed
        }

        // 第二遍：把它读回来，带着配对标识重写一次。
        guard let source = CGImageSourceCreateWithURL(intermediate as CFURL, nil),
              let existing = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw LivePhotoError.imageWriteFailed
        }

        var metadata = existing
        // 合并而不是覆盖：源文件里可能还有别的 Apple MakerNote 项，不能顺手丢掉
        var makerNote: [String: Any] = [:]
        if let dict = metadata[kCGImagePropertyMakerAppleDictionary] as? [String: Any] {
            makerNote = dict
        } else if let dict = metadata[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any] {
            for (key, value) in dict {
                makerNote[key as String] = value
            }
        }
        makerNote[identifierTag] = identifier
        metadata[kCGImagePropertyMakerAppleDictionary] = makerNote

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoError.imageWriteFailed
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.imageWriteFailed
        }
    }

    // MARK: - 公共元数据

    /// 两条路径共用的基础元数据（不含配对标识）。
    private static func baseProperties(format: StillImageFormat) -> [CFString: Any] {
        let stamp = Formatters.exifDate.string(from: Date())
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp
        ]
        // HEIC 规范要求 TIFF 块里带 Make / Model，缺了部分解析器会认不出整套 EXIF
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "LiveMoment"
        ]
        return [
            kCGImageDestinationLossyCompressionQuality: format.compressionQuality,
            // 抽帧时已经应用过旋转，这里明确写成 1，免得系统按方向再转一次
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff
        ]
    }

    /// 删掉本次没采用的另一种格式留下的文件，避免工作目录里堆两个封面。
    private static func removeCounterpart(of format: StillImageFormat, in folder: URL, baseName: String) {
        let url = folder
            .appendingPathComponent(baseName)
            .appendingPathExtension(format.fallback.fileExtension)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 回读

    /// 把写好的文件读回来，取出 Apple MakerNote 里的配对标识。
    ///
    /// 顺带说明一下为什么这里要双重取值：字典从 CoreFoundation 桥接回来时，
    /// 键的类型在 `CFString` 与 `String` 之间不保证一致，
    /// 两种都试一遍比赌其中一种稳。
    static func readIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let makerNote = properties[kCGImagePropertyMakerAppleDictionary]
        else { return nil }

        if let dict = makerNote as? [CFString: Any],
           let value = dict[identifierTag as CFString] as? String {
            return value
        }
        if let dict = makerNote as? [String: Any],
           let value = dict[identifierTag] as? String {
            return value
        }
        return nil
    }
}
