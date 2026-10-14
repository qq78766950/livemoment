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
/// 所以这里在编码后立刻回读比对，校验不通过就换另一种格式重写，
/// 并把结果如实交给上层去展示。
enum StillImageWriter {

    /// 一次编码的产物。
    struct Output {
        let url: URL
        /// 实际落盘的格式——可能和调用方偏好的那个不同（发生了回退）。
        let format: StillImageFormat
        /// 是否已确认配对标识真的写进了文件。
        let identifierVerified: Bool
        /// 主选格式失败的原因，仅在发生回退时非空，用于给用户一句可解释的话。
        let fallbackReason: String?
    }

    /// Apple MakerNote 里承载配对标识的标签号。
    ///
    /// 即 ExifTool 中显示的 `[Apple] Content Identifier`，
    /// 对应 `kFigAppleMakerNote_AssetIdentifier`（0x0011，十进制 17）。
    /// 视频那一侧的对应物是 `com.apple.quicktime.content.identifier`。
    static let identifierTag = "17"

    // MARK: - 对外入口

    /// 按偏好格式编码主图；主选格式写不出配对标识时自动换另一种格式。
    ///
    /// - Parameter preferring: 用户偏好的格式。不是硬保证，见 `Output.format`。
    /// - Returns: 实际产物。`identifierVerified == false` 表示两种格式都没能把
    ///   标识写进文件（极罕见），上层应据此提醒用户。
    static func write(
        _ image: CGImage,
        identifier: String,
        preferring preferredFormat: StillImageFormat,
        in folder: URL,
        baseName: String = "LiveMoment"
    ) throws -> Output {
        let primary = try? encode(
            image,
            identifier: identifier,
            format: preferredFormat,
            in: folder,
            baseName: baseName
        )

        // 主选格式：编码成功且标识校验通过，直接采用。
        if let primary, primary.identifierVerified {
            return primary
        }

        // 走到这里说明主选格式要么编不出来，要么标识没写进去。
        // 两种情况的处理方式相同：换另一种格式重试。
        let alternateFormat = preferredFormat.fallback
        let alternate = try? encode(
            image,
            identifier: identifier,
            format: alternateFormat,
            in: folder,
            baseName: baseName
        )

        if let alternate, alternate.identifierVerified {
            // 回退成功。把主选留下的半成品删掉，避免同目录堆两个封面。
            if let primary {
                try? FileManager.default.removeItem(at: primary.url)
            }
            return Output(
                url: alternate.url,
                format: alternate.format,
                identifierVerified: true,
                fallbackReason: primary == nil
                    ? "\(preferredFormat.displayName) 编码不可用"
                    : "\(preferredFormat.displayName) 未能写入配对标识"
            )
        }

        // 两种格式都不行。优先交回主选产物（至少图是完整的），
        // 主选完全没有产物时才用备选，最后才抛错。
        if let primary {
            return Output(
                url: primary.url,
                format: primary.format,
                identifierVerified: false,
                fallbackReason: "配对标识未能写入 \(primary.format.displayName) 文件"
            )
        }
        if let alternate {
            return Output(
                url: alternate.url,
                format: alternate.format,
                identifierVerified: false,
                fallbackReason: "配对标识未能写入 \(alternate.format.displayName) 文件"
            )
        }
        throw LivePhotoError.imageWriteFailed
    }

    // MARK: - 单次编码

    private static func encode(
        _ image: CGImage,
        identifier: String,
        format: StillImageFormat,
        in folder: URL,
        baseName: String
    ) throws -> Output {
        let url = folder
            .appendingPathComponent(baseName)
            .appendingPathExtension(format.fileExtension)

        try? FileManager.default.removeItem(at: url)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            // 该设备或该尺寸不支持这种格式的编码（例如奇数宽高的 HEIC）
            throw LivePhotoError.imageWriteFailed
        }

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

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: format.compressionQuality,
            // 抽帧时已经应用过旋转，这里明确写成 1，免得系统按方向再转一次
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            // ★ 实况照片的配对标识就藏在这里：Apple MakerNote 标签 17
            kCGImagePropertyMakerAppleDictionary: [identifierTag: identifier]
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError.imageWriteFailed
        }

        let verified = readIdentifier(at: url) == identifier
        return Output(
            url: url,
            format: format,
            identifierVerified: verified,
            fallbackReason: nil
        )
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
