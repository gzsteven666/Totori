import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        // 图标：自动补成正方形，打包常用尺寸
        .init(ext: "ico",  name: "ICO",   kind: .image, hint: "Windows/网站图标，含 16–256 像素"),
        .init(ext: "icns", name: "ICNS",  kind: .image, hint: "macOS 应用图标，含 16–1024 像素"),
        // 只给动图 GIF：转成视频通常小很多
        .init(ext: "mp4",  name: "MP4",   kind: .image, hint: "动图转视频，体积通常小很多"),
        .init(ext: "webm", name: "WebM",  kind: .image, hint: "动图转网页视频"),
    ]

    /// 图片里只给动图 GIF 的视频输出
    static let animatedOnlyImageExts: Set<String> = ["mp4", "webm"]
    /// 图标输出由专门的流程生成（补正方形、打包多尺寸）
    static let iconExts: Set<String> = ["ico", "icns"]

    static let documents: [OutputFormat] = [
        .init(ext: "pdf",  name: "PDF",   kind: .document, hint: "排版固定"),
        .init(ext: "html", name: "HTML",  kind: .document, hint: "网页"),
        .init(ext: "txt",  name: "纯文本", kind: .document, hint: "去掉所有格式"),
        .init(ext: "rtf",  name: "RTF",   kind: .document, hint: "富文本"),
        .init(ext: "docx", name: "Word",  kind: .document, hint: ".docx"),
        .init(ext: "odt",  name: "ODT",   kind: .document, hint: "开放文档"),
        .init(ext: "epub", name: "EPUB",  kind: .document, hint: "电子书"),
        .init(ext: "md",   name: "Markdown", kind: .document, hint: "纯文本标记"),
        // 只给表格输入
        .init(ext: "xlsx", name: "Excel", kind: .document, hint: ".xlsx 表格"),
        .init(ext: "ods",  name: "ODS",   kind: .document, hint: "开放表格"),
        .init(ext: "csv",  name: "CSV",   kind: .document, hint: "逗号分隔，UTF-8；只导出第一个工作表"),
        // 只给演示文稿输入
        .init(ext: "pptx", name: "PPTX", kind: .document, hint: ".pptx 演示文稿"),
        .init(ext: "odp",  name: "ODP",   kind: .document, hint: "开放演示文稿"),
        // 逐页图片：PDF 直接渲染，其他文档先转 PDF；多页时每页一张，放进一个文件夹
        .init(ext: "png",  name: "PNG",   kind: .document, hint: "每页一张图片"),
        .init(ext: "jpg",  name: "JPEG",  kind: .document, hint: "每页一张图片，体积小"),
    ]

    /// 逐页出图的格式（PDF 直接渲染，其他文档先经 LibreOffice 转成 PDF）
    static let pageImageExts: Set<String> = ["png", "jpg"]
    /// 表格专用的输出，文字类文档转不出来
    static let spreadsheetOutputExts: Set<String> = ["xlsx", "ods", "csv"]
    /// 演示文稿专用的输出
    static let presentationOutputExts: Set<String> = ["pptx", "odp"]

    static let medias: [OutputFormat] = [
        .init(ext: "mp4",  name: "MP4",   kind: .media, hint: "H.264 硬编"),
        // ext 只是格式的标识，实际扩展名见 actualExtension
        .init(ext: "hevc", name: "HEVC", kind: .media, hint: "MP4 · H.265 硬编，同画质体积约小一半"),
        .init(ext: "mov",  name: "MOV",   kind: .media, hint: "苹果封装"),
        .init(ext: "prores", name: "ProRes", kind: .media, hint: "MOV · ProRes 422，适合剪辑，体积大"),
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
        // 视频截一帧代表画面
        .init(ext: "png",  name: "封面PNG", kind: .media, hint: "截取一帧代表画面"),
        .init(ext: "jpg",  name: "封面JPG", kind: .media, hint: "截取一帧代表画面"),
    ]

    /// 只给有画面的视频：音频文件转不出
    static let videoOnlyMediaExts: Set<String> = ["mp4", "hevc", "mov", "prores", "mkv", "webm", "avi", "wmv", "gif", "png", "jpg"]

    static let archives: [OutputFormat] = [
        .init(ext: "extract", name: "解压", kind: .archive, hint: "解出到同名文件夹；单个压缩文件直接还原"),
        .init(ext: "repack", name: "ZIP", kind: .archive, hint: "解开后重新打包成 ZIP"),
        .init(ext: "tgz",  name: "TAR.GZ", kind: .archive, hint: "解开后重新打包成 tar.gz"),
        .init(ext: "zip",  name: "外层ZIP", kind: .archive, hint: "原文件整个装进 ZIP，不解包"),
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

    // MARK: - 按输入文件过滤输出格式

    /// 表格和演示文稿在 LibreOffice 里分别用 Calc、Impress 打开，只能导出同类格式、PDF、HTML
    /// （以及经 PDF 渲染的逐页图片）；txt、docx、epub 这类文字格式会失败。
    private static let spreadsheetExts: Set<String> = ["xlsx", "xls", "ods", "numbers"]
    private static let presentationExts: Set<String> = ["pptx", "ppt", "key", "odp"]
    /// csv / tsv 在 LibreOffice 中按表格打开，转文字类格式靠 textutil 兜底；它写不了 epub / md。
    private static let tabularTextExts: Set<String> = ["csv", "tsv"]
    private static let audioExts: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma",
        "caf", "amr", "ape", "mka", "m4b", "aifc",
    ]

    private static let writableImageTypes: Set<String> =
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// 当前系统的 ImageIO 能否编码该图片格式。AVIF、JPEG 2000 等是否可写取决于系统版本与硬件
    /// （例如 GitHub 托管的 macOS 虚拟机就不能编码 AVIF），不可写时不提供，避免必然失败。
    /// WebP 由内置 cwebp 编码，不受 ImageIO 限制。
    static func canWriteImage(_ ext: String) -> Bool {
        let identifier: String
        switch ext {
        case "webp": return true
        case "avif": identifier = "public.avif"
        case "jp2":  identifier = "public.jpeg-2000"
        default:
            guard let type = UTType(filenameExtension: ext) else { return true }
            identifier = type.identifier
        }
        return writableImageTypes.contains(identifier)
    }

    /// 单个输入文件实际能产出的格式，顺序同目录。
    /// 同格式再输出（如 JPG→JPEG）保留，那是重新编码/压缩的用法；只有 PDF→PDF 没有意义。
    static func outputs(for source: URL) -> [OutputFormat] {
        let ext = effectiveExtension(of: source)
        let kind = kind(of: source)
        let candidates: [OutputFormat]
        switch kind {
        case .document:
            if ext == "pdf" {
                // LibreOffice 只能把 PDF 当绘图打开，只有 HTML 能导；文字和逐页图片由系统 PDF 渲染完成
                candidates = documents.filter { ["html", "txt", "png", "jpg"].contains($0.ext) }
            } else if spreadsheetExts.contains(ext) {
                let allowed = Set(["pdf", "html"]).union(spreadsheetOutputExts).union(pageImageExts)
                candidates = documents.filter { allowed.contains($0.ext) && $0.ext != ext }
            } else if presentationExts.contains(ext) {
                let allowed = Set(["pdf", "html"]).union(presentationOutputExts).union(pageImageExts)
                candidates = documents.filter { allowed.contains($0.ext) && $0.ext != ext }
            } else if tabularTextExts.contains(ext) {
                // csv/tsv 既能当文字导出，也能存成真正的表格
                candidates = documents.filter {
                    !["epub", "md"].contains($0.ext) && !presentationOutputExts.contains($0.ext) && $0.ext != ext
                }
            } else if ext == "svg" {
                candidates = documents.filter { ["pdf", "png", "jpg"].contains($0.ext) }
            } else {
                candidates = documents.filter {
                    !spreadsheetOutputExts.contains($0.ext) && !presentationOutputExts.contains($0.ext)
                }
            }
        case .media:
            // 纯音频没有视频流，输出视频或 GIF 只会失败或得到无画面的文件
            candidates = audioExts.contains(ext) ? medias.filter { !videoOnlyMediaExts.contains($0.ext) } : medias
        case .image:
            let animated = ext == "gif" && isAnimated(source)
            candidates = images.filter { format in
                if animatedOnlyImageExts.contains(format.ext) { return animated }
                return canWriteImage(format.ext)
            }
        case .archive:
            let tarball = ["tgz"].contains(ext) || source.lastPathComponent.lowercased().hasSuffix(".tar.gz")
            candidates = archives.filter { format in
                switch format.ext {
                case "repack": return ext != "zip"          // ZIP 重新打包成 ZIP 没有意义
                case "tgz": return !tarball
                default: return true
                }
            }
        default:
            candidates = formats(for: kind)
        }
        return candidates
    }

    /// 一批同类文件共同支持的输出格式（交集）。`sources` 为空时返回该类型的全部格式。
    static func formats(for kind: FileKind, sources: [URL]) -> [OutputFormat] {
        let same = sources.filter { Self.kind(of: $0) == kind }
        guard !same.isEmpty else { return formats(for: kind) }
        let allowed = same.map { Set(outputs(for: $0)) }
        return formats(for: kind).filter { format in allowed.allSatisfy { $0.contains(format) } }
    }

    // MARK: - 类型判定

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp", "avif", "ico",
        // 系统 ImageIO 能直接解码：JPEG 2000、Photoshop（合并图层）、OpenEXR、TGA
        "jp2", "j2k", "jpf", "psd", "exr", "tga",
        // 相机 RAW：按系统默认参数显影
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw",
        "3fr", "erf", "mrw", "x3f", "iiq", "rwl",
    ]

    private static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "rtf", "rtfd", "html", "htm", "txt", "md", "markdown", "svg",
        "odt", "ott", "wordml", "webarchive", "pages", "epub", "csv", "tsv",
        "pptx", "ppt", "xlsx", "xls", "key", "numbers",
    ]

    private static let mediaExts: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg",
        // 摄像机、手机、DVD 与广播常见的容器，自带 ffmpeg 都能读
        "ts", "mts", "m2ts", "3gp", "3g2", "vob", "ogv", "mxf",
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma",
        "caf", "amr", "ape", "mka", "m4b", "aifc",
    ]

    private static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]

    static func kind(of url: URL) -> FileKind {
        let ext = effectiveExtension(of: url)
        if imageExts.contains(ext) {
            // gif 既能当图片也能当动图，按图片处理
            return .image
        }
        if documentExts.contains(ext) { return .document }
        // .ts 也是 TypeScript 源码的扩展名：只有开头是 MPEG-TS 同步字节（0x47）才当视频
        if ext == "ts", !looksLikeMPEGTS(url) { return .unknown }
        if mediaExts.contains(ext) { return .media }
        if archiveExts.contains(ext) { return .archive }
        return .unknown
    }

    private static var knownExts: Set<String> {
        imageExts.union(documentExts).union(mediaExts).union(archiveExts)
    }

    /// 用于判定类型的扩展名：扩展名已知就直接用；没有扩展名或扩展名不认识时，读文件开头识别真实格式。
    /// 只在扩展名不可用时才读文件，已有的按扩展名判断行为不变。
    static func effectiveExtension(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if knownExts.contains(ext) { return ext }
        return sniffedExtension(of: url) ?? ext
    }

    /// MPEG-TS 每 188 字节一个包，包头是 0x47；查前两个包，避免把源码文件误认成视频。
    /// 读不到（如文件不存在的路径判断）时按扩展名放行。
    static func looksLikeMPEGTS(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 189), data.count == 189 else { return false }
        return data[data.startIndex] == 0x47 && data[data.startIndex + 188] == 0x47
    }

    /// 按文件头魔数识别常见格式，返回规范扩展名；认不出返回 nil。
    static func sniffedExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count >= 4 else { return nil }
        let b = [UInt8](data)
        func has(_ text: String, at offset: Int = 0) -> Bool {
            let bytes = Array(text.utf8)
            return b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if has("GIF8") { return "gif" }
        if has("RIFF"), b.count >= 12 {
            if has("WEBP", at: 8) { return "webp" }
            if has("WAVE", at: 8) { return "wav" }
            if has("AVI ", at: 8) { return "avi" }
        }
        if has("II*") && b[3] == 0 || has("MM") && b[2] == 0 && b[3] == 0x2A { return "tiff" }
        if has("BM"), b.count >= 10, b[6...9].allSatisfy({ $0 == 0 }) { return "bmp" }
        if has("ftyp", at: 4), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return "heic" }
            if brand == "avif" { return "avif" }
            if brand == "qt  " { return "mov" }
            if brand.hasPrefix("M4A") { return "m4a" }
            return "mp4"
        }
        if has("%PDF") { return "pdf" }
        if has("{\\rtf") { return "rtf" }
        if has("PK") && b[2] == 3 && b[3] == 4 { return "zip" }
        if b.starts(with: [0x1F, 0x8B]) { return "gz" }
        if has("BZh") { return "bz2" }
        if b.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if b.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7z" }
        if has("Rar!") { return "rar" }
        if has("ID3") || (b[0] == 0xFF && b[1] & 0xE0 == 0xE0) { return "mp3" }
        if has("OggS") { return "ogg" }
        if has("fLaC") { return "flac" }
        if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "mkv" }
        if has("FORM"), has("AIFF", at: 8) { return "aiff" }
        return nil
    }

    /// 输出的扩展名（有些格式写出时用别的后缀）
    /// 格式标识与实际写出的扩展名不同的几种：HEVC/ProRes 只是编码不同，解压出来是文件夹。
    static func actualExtension(for format: OutputFormat, source: URL) -> String {
        switch (format.kind, format.ext) {
        case (.media, "hevc"): return "mp4"
        case (.media, "prores"): return "mov"
        case (.archive, "repack"): return "zip"
        case (.archive, "tgz"): return "tar.gz"
        case (.archive, "extract"): return ""
        default: return format.ext
        }
    }

    /// GIF 是否有多帧；文件不存在（只按扩展名判断时）当作动图，选项照常给出。
    static func isAnimated(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
}
