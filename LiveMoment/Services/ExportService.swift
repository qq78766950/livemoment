import Foundation

/// 把转换结果以一对文件的形式导出到「文件」App。
///
/// 用途是不经过相册、直接把实况照片分享出去：AirDrop 同时传这两个文件，
/// 或者放进一个 .pvt 包一起传，接收端才能还原成实况照片。
/// （微信、QQ 这类会剥离元数据的通道，传过去就会散成一张图 + 一段视频。）
enum ExportService {

    static func makeBaseName() -> String {
        "IMG_" + Formatters.fileNameStamp.string(from: Date())
    }

    /// 导出成 `<Documents>/<名称>.pvt/` 包，内部是两个同名文件。
    @discardableResult
    static func exportPair(_ result: BuiltLivePhoto, baseName: String) throws -> URL {
        let manager = FileManager.default
        guard let documents = try? manager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw LivePhotoError.exportFolderFailed("拿不到沙盒目录")
        }

        let folder = documents.appendingPathComponent(baseName, isDirectory: true)
            .appendingPathExtension("pvt")

        do {
            if manager.fileExists(atPath: folder.path) {
                try manager.removeItem(at: folder)
            }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(
                at: result.photoURL,
                to: folder.appendingPathComponent(baseName).appendingPathExtension("JPG")
            )
            try manager.copyItem(
                at: result.videoURL,
                to: folder.appendingPathComponent(baseName).appendingPathExtension("MOV")
            )
        } catch {
            throw LivePhotoError.exportFolderFailed(error.localizedDescription)
        }

        return folder
    }
}
