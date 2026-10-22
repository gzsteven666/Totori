import Foundation

/// 常用格式按显式顺序保存；不根据使用次数排序，读取无效偏好时只在内存中补全。
enum FavoriteFormats {
    static let didChange = Notification.Name("TotoriFavoriteFormatsDidChange")
    static let configurableKinds: [FileKind] = [.image, .document, .media]

    static func storageKey(_ kind: FileKind) -> String { "totori.favoriteFormats.\(kind.rawValue)" }

    /// 只接受该文件类型支持的格式，去重并限定4—6项；不足4项的类型保留全部格式。
    static func normalized(_ values: [String], kind: FileKind) -> [String] {
        let catalog = FormatCatalog.formats(for: kind)
        let valid = Set(catalog.map(\.ext))
        let minimum = min(4, catalog.count)
        var result: [String] = []
        for value in values {
            let key = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
            if valid.contains(key) && !result.contains(key) { result.append(key) }
            if result.count == 6 { break }
        }
        for key in defaults(kind) + catalog.map(\.ext) where result.count < minimum {
            if valid.contains(key) && !result.contains(key) { result.append(key) }
        }
        return result
    }

    /// 本次呼出时读取一次，由控制器保存快照，确保拖动期间的角度不随设置变化。
    static func formats(for kind: FileKind) -> [OutputFormat] {
        let raw = UserDefaults.standard.stringArray(forKey: storageKey(kind)) ?? defaults(kind)
        let catalog = FormatCatalog.formats(for: kind)
        return normalized(raw, kind: kind).compactMap { ext in catalog.first { $0.ext == ext } }
    }

    static func set(_ values: [String], for kind: FileKind) {
        UserDefaults.standard.set(normalized(values, kind: kind), forKey: storageKey(kind))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 恢复只影响当前类型的常用格式，不动其他类型、主题或快捷键。
    static func reset(_ kind: FileKind) {
        UserDefaults.standard.removeObject(forKey: storageKey(kind))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func defaults(_ kind: FileKind) -> [String] {
        switch kind {
        case .image: return ["png", "jpg", "heic", "webp"]
        case .document: return ["pdf", "txt", "docx", "rtf"]
        case .media: return ["mp4", "mov", "mp3", "gif"]
        default: return FormatCatalog.formats(for: kind).map(\.ext)
        }
    }
}
