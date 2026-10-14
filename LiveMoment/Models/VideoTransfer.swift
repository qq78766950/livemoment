import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 从系统相册 / 文件 App 拿到的视频，统一拷贝到沙盒临时目录后再处理，
/// 避免直接在只读的原始位置做转码。
struct VideoTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            VideoTransfer(url: try copyIntoImportFolder(received.file))
        }
    }

    /// 把外部位置的视频拷进沙盒临时目录。相册与「文件」App 给到的都是外部 URL，
    /// 直接拿去转码会失败或越权，所以统一先落地一份。
    static func copyIntoImportFolder(_ source: URL) throws -> URL {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("LiveMomentImport", isDirectory: true)
        if !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var ext = source.pathExtension
        if ext.isEmpty { ext = "mov" }
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        return destination
    }
}

/// 包一层 Identifiable，方便用 navigationDestination(item:) 推编辑器。
struct ImportedVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}
