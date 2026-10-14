import Foundation
import SwiftData

/// 一次成功转换的记录。
@Model
final class ConvertedItem {
    var title: String
    var createdAt: Date
    var assetIdentifier: String
    var durationSeconds: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var keepsAudio: Bool
    var savedToLibrary: Bool
    var libraryIdentifier: String?
    /// 静态主图实际使用的格式，存 `StillImageFormat` 的 rawValue。
    ///
    /// 给了默认值，所以旧记录在 SwiftData 轻量迁移时会被自动补上，
    /// 不会因为新增字段导致建库失败。
    var stillFormatRaw: String = StillImageFormat.heic.rawValue
    /// 封面缩略图，落到外部存储避免撑大数据库。
    @Attribute(.externalStorage) var thumbnail: Data?

    init(
        title: String,
        createdAt: Date = .now,
        assetIdentifier: String,
        durationSeconds: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        keepsAudio: Bool,
        savedToLibrary: Bool,
        libraryIdentifier: String? = nil,
        stillFormatRaw: String = StillImageFormat.heic.rawValue,
        thumbnail: Data? = nil
    ) {
        self.title = title
        self.createdAt = createdAt
        self.assetIdentifier = assetIdentifier
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.keepsAudio = keepsAudio
        self.savedToLibrary = savedToLibrary
        self.libraryIdentifier = libraryIdentifier
        self.stillFormatRaw = stillFormatRaw
        self.thumbnail = thumbnail
    }

    var resolutionText: String { "\(pixelWidth) × \(pixelHeight)" }
    var durationText: String { String(format: "%.1f 秒", durationSeconds) }
    /// 记录里存的格式，取不出来时按 HEIC 兜底。
    var stillFormat: StillImageFormat { StillImageFormat(rawValue: stillFormatRaw) ?? .heic }
}
