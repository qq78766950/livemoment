import Foundation
import UniformTypeIdentifiers

/// 实况照片「静态主图」这一半的编码格式。
///
/// 需要先说清楚一件事：本 App 生成的实况照片在磁盘上始终是**两个文件**——
/// 一张静态主图 + 一段动图视频，靠同一个配对标识绑定。
/// 这里的格式只决定**主图**那一半怎么写，视频那一半永远是 HEVC / MOV，不受影响。
///
/// 两种格式在苹果生态里的地位并不对等：
/// - `heic` 是系统相机在「高效」模式下拍出的原生形态，体积约为 JPEG 的一半；
/// - `jpeg` 通用性最好，但代价是体积翻倍。
///
/// 还存在一个只有踩过才知道的坑：**iOS 15.1 起，ImageIO 往 JPEG 里写
/// `kCGImagePropertyMakerAppleDictionary` 时可能直接把它丢掉**，
/// 而配对标识恰好就存在那个字典里。写丢了的话图仍然是一张好图，
/// 但配对会失败，成品落进相册就是一张不会动的普通照片。
/// 所以选 `heic` 不只是为了省空间，更是走苹果最认的那条路。
enum StillImageFormat: String, CaseIterable, Identifiable, Sendable {
    case heic
    case jpeg

    var id: String { rawValue }

    /// 落盘扩展名。用大写，与系统相册导出的文件命名保持一致。
    var fileExtension: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPG"
        }
    }

    /// 写文件时用的统一类型标识。
    var utType: UTType {
        switch self {
        case .heic: return .heic
        case .jpeg: return .jpeg
        }
    }

    /// 当前格式写不出配对标识（或根本编不出来）时，换哪一种再试一次。
    var fallback: StillImageFormat {
        switch self {
        case .heic: return .jpeg
        case .jpeg: return .heic
        }
    }

    var displayName: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        }
    }

    /// 设置页里给用户看的取舍说明。
    var tradeOff: String {
        switch self {
        case .heic:
            return "苹果原生形态，体积约为 JPEG 的一半，与系统相机拍出的实况照片一致。"
        case .jpeg:
            return "通用性最好，任何设备与环境都能直接查看；代价是体积偏大。"
        }
    }

    /// 压缩质量要按格式分别取。
    ///
    /// HEVC 帧内编码的效率明显高于 JPEG，用同一个质量值会让 HEIC 白白多占体积：
    /// HEIC 给 0.8 就已经明显好于 JPEG 给 0.95 的观感。
    var compressionQuality: Double {
        switch self {
        case .heic: return 0.8
        case .jpeg: return 0.95
        }
    }

    /// 设置页里那行「技术参数」用的描述。
    var technicalSummary: String {
        switch self {
        case .heic: return "HEIC 主图 + HEVC / MOV 动图"
        case .jpeg: return "JPEG 主图 + HEVC / MOV 动图"
        }
    }
}
