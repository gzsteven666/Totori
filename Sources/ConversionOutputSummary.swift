import Foundation

/// 纯值类型的转换结果摘要：不读文件、不读偏好、不改源文件。
struct ConversionOutputSummary: Equatable, Sendable {
    let sourceExtension: String
    let outputExtension: String
    let sourceBytes: Int64
    let outputBytes: Int64

    init(sourceExtension: String, outputExtension: String,
         sourceBytes: Int64, outputBytes: Int64) {
        self.sourceExtension = Self.normalized(sourceExtension)
        self.outputExtension = Self.normalized(outputExtension)
        self.sourceBytes = max(0, sourceBytes)
        self.outputBytes = max(0, outputBytes)
    }

    // MARK: 展示

    /// 例：`PNG → JPEG · 67 KB → 328 KB · +392.2%`
    var text: String {
        var parts = ["\(display(sourceExtension)) → \(display(outputExtension))"]
        parts.append("\(bytesText(sourceBytes)) → \(bytesText(outputBytes))")
        if let percent = percentText { parts.append(percent) }
        return parts.joined(separator: " · ")
    }

    /// 例：`体积增加 261 KB（+392.2%）` / `体积相同`
    var deltaText: String {
        guard sourceBytes != outputBytes else { return "体积相同" }
        let delta = abs(outputBytes - sourceBytes)
        let head = isSmaller ? "体积减少" : "体积增加"
        guard let percent = percentText else { return "\(head) \(bytesText(delta))" }
        return "\(head) \(bytesText(delta))（\(percent)）"
    }

    var isSmaller: Bool { outputBytes < sourceBytes }

    // MARK: 可读字段

    var sourceSizeText: String { bytesText(sourceBytes) }
    var outputSizeText: String { bytesText(outputBytes) }

    /// 相对源文件的变化比例；源为 0 时无意义，返回 nil
    var percentChange: Double? {
        guard sourceBytes > 0, sourceBytes != outputBytes else { return nil }
        return Double(outputBytes - sourceBytes) / Double(sourceBytes) * 100
    }

    // MARK: 内部

    private var percentText: String? {
        guard let percent = percentChange else { return nil }
        return String(format: "%+.1f%%", percent)
    }

    private func bytesText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func display(_ ext: String) -> String {
        guard !ext.isEmpty else { return "未知格式" }
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "tif":  return "TIFF"
        default:     return ext.uppercased()
        }
    }

    private static func normalized(_ ext: String) -> String {
        ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
    }
}
