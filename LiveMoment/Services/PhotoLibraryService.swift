import Foundation
import Photos
import UIKit

/// 相册读写。核心是 `PHAssetCreationRequest` 的 `.photo` + `.pairedVideo` 组合，
/// 只要两个文件的配对标识一致，iOS 就会把它落成一张真正的实况照片。
enum PhotoLibraryService {

    // MARK: - 权限

    static func requestAddPermission() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func hasAddPermission() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    // MARK: - 保存

    /// 把一对文件写成一张实况照片。返回新资源的 localIdentifier。
    @discardableResult
    static func saveLivePhoto(photoURL: URL, videoURL: URL) async throws -> String? {
        let status = await requestAddPermission()
        guard status == .authorized || status == .limited else {
            throw LivePhotoError.photoLibraryDenied
        }

        let box = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // 不要移动文件，转换结果后续还要用于预览和导出
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
                box.value = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw LivePhotoError.saveFailed(error.localizedDescription)
        }
        return box.value
    }

    // MARK: - 读取

    static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }
}

/// 用来把 change block 里拿到的 placeholder 带出来。
private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}
