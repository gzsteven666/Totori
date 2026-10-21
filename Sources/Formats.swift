import Foundation

/// 输入文件的大类。决定可用输出格式集合。
enum FileKind: String, CaseIterable {
    case image, document, media, archive, unknown

    var title: String {
        switch self {
        case .image:    return "图片"
        case .document: return "文档"
        case .media:    return "音视频"
        case .archive:  return "压缩包"
        case .unknown:  return "未知"
        }
    }

    var symbol: String {
        switch self {
        case .image:    return "photo"
        case .document: return "doc.text"
        case .media:    return "waveform"
        case .archive:  return "archivebox"
        case .unknown:  return "questionmark.square.dashed"
        }
    }
}

/// 一种可选的输出格式。
struct OutputFormat: Identifiable, Hashable {
    let ext: String          // 实际写出的扩展名
    let name: String         // 中文显示名
    let kind: FileKind       // 适用于哪一类输入
    let hint: String         // 一句话说明

    var id: String { "\(kind.rawValue).\(ext)" }
}

enum FormatCatalog {
    static let all: [OutputFormat] = images + documents + medias + archives

    static let images: [OutputFormat] = [
        .init(ext: "png",  name: "PNG",   kind: .image, hint: "无损，通用"),
        .init(ext: "jpg",  name: "JPEG",  kind: .image, hint: "有损，体积小"),
        .init(ext: "heic", name: "HEIC",  kind: .image, hint: "苹果原生压缩"),
        .init(ext: "tiff", name: "TIFF",  kind: .image, hint: "打印/归档"),
        .init(ext: "webp", name: "WebP",  kind: .image, hint: "网页用，体积最小"),
        .init(ext: "avif", name: "AVIF",  kind: .image, hint: "新一代压缩"),
        .init(ext: "bmp",  name: "BMP",   kind: .image, hint: "无压缩位图"),
        .init(ext: "gif",  name: "GIF",   kind: .image, hint: "索引色"),
        .init(ext: "jp2",  name: "JP2",   kind: .image, hint: "JPEG 2000"),
        .init(ext: "pdf",  name: "PDF",   kind: .image, hint: "图片封装成单页 PDF"),
    ]

    static let documents: [OutputFormat] = [
        .init(ext: "pdf",  name: "PDF",   kind: .document, hint: "排版固定"),
        .init(ext: "html", name: "HTML",  kind: .document, hint: "网页"),
        .init(ext: "txt",  name: "纯文本", kind: .document, hint: "去掉所有格式"),
        .init(ext: "rtf",  name: "RTF",   kind: .document, hint: "富文本"),
        .init(ext: "docx", name: "Word",  kind: .document, hint: ".docx"),
        .init(ext: "odt",  name: "ODT",   kind: .document, hint: "开放文档"),
        .init(ext: "epub", name: "EPUB",  kind: .document, hint: "电子书"),
        .init(ext: "md",   name: "Markdown", kind: .document, hint: "纯文本标记"),
    ]

    static let medias: [OutputFormat] = [
        .init(ext: "mp4",  name: "MP4",   kind: .media, hint: "H.264 硬编"),
        .init(ext: "mov",  name: "MOV",   kind: .media, hint: "苹果封装"),
        .init(ext: "mkv",  name: "MKV",   kind: .media, hint: "通用封装"),
        .init(ext: "webm", name: "WebM",  kind: .media, hint: "VP9 + Opus"),
        .init(ext: "avi",  name: "AVI",   kind: .media, hint: "老设备兼容"),
        .init(ext: "wmv",  name: "WMV",   kind: .media, hint: "Windows 视频"),
        .init(ext: "gif",  name: "GIF",   kind: .media, hint: "动图，无声"),
        .init(ext: "mp3",  name: "MP3",   kind: .media, hint: "提取音频"),
        .init(ext: "m4a",  name: "M4A",   kind: .media, hint: "AAC 音频"),
        .init(ext: "wav",  name: "WAV",   kind: .media, hint: "无损 PCM"),
        .init(ext: "flac", name: "FLAC",  kind: .media, hint: "无损压缩"),
        .init(ext: "aiff", name: "AIFF",  kind: .media, hint: "苹果无损"),
        .init(ext: "ogg",  name: "OGG",   kind: .media, hint: "Opus 封装"),
        .init(ext: "opus", name: "Opus",  kind: .media, hint: "语音最优"),
        .init(ext: "wma",  name: "WMA",   kind: .media, hint: "Windows 音频"),
    ]

    static let archives: [OutputFormat] = [
        .init(ext: "zip", name: "ZIP", kind: .archive, hint: "外层打包（不解包）"),
    ]

    static func formats(for kind: FileKind) -> [OutputFormat] {
        switch kind {
        case .image:    return images
        case .document: return documents
        case .media:    return medias
        case .archive:  return archives
        case .unknown:  return []
        }
    }

    // MARK: - 类型判定

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp", "avif", "ico",
    ]

    private static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "rtf", "rtfd", "html", "htm", "txt", "md", "markdown", "svg",
        "odt", "ott", "wordml", "webarchive", "pages", "epub", "csv", "tsv",
        "pptx", "ppt", "xlsx", "xls", "key", "numbers",
    ]

    private static let mediaExts: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg",
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma",
    ]

    private static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]

    static func kind(of url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if imageExts.contains(ext) {
            // gif 既能当图片也能当动图，按图片处理
            return .image
        }
        if documentExts.contains(ext) { return .document }
        if mediaExts.contains(ext) { return .media }
        if archiveExts.contains(ext) { return .archive }
        return .unknown
    }

    /// 输出的扩展名（有些格式写出时用别的后缀）
    static func actualExtension(for format: OutputFormat, source: URL) -> String {
        format.ext
    }
}
