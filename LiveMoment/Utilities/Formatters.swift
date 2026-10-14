import Foundation

enum Formatters {
    /// 时间轴上的 mm:ss.S 样式。
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        let tenths = Int((seconds - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", minutes, secs, tenths)
    }

    static func duration(_ seconds: Double) -> String {
        String(format: "%.1f 秒", seconds)
    }

    static func fileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(max(bytes, 0)))
    }

    /// EXIF 的 DateTimeOriginal 要求 `yyyy:MM:dd HH:mm:ss` 格式。
    static let exifDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static let recordTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    static let fileNameStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}
