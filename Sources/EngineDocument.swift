import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

extension Engine {
    // MARK: 文档

    /// 走 LibreOffice 的格式过滤器名
    static func libreOfficeFilter(for ext: String) -> String {
        switch ext {
        case "pdf":  return "pdf"
        case "html": return "html"
        case "txt":  return "txt:Text"
        case "rtf":  return "rtf"
        case "docx": return "docx:MS Word 2007 XML"
        case "odt":  return "odt"
        case "epub": return "epub"
        case "md", "markdown": return "md:Markdown"
        default:     return ext
        }
    }

    /// 分发版只用包内 LibreOffice；开发构建可退回 /Applications 里的安装。
    static func resolveSoffice() -> String? {
        if let bundled = Shell.which("soffice") { return bundled }
        let portable = FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/RuntimeManifest.json").path)
        let system = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return !portable && FileManager.default.isExecutableFile(atPath: system) ? system : nil
    }

    static func convertDocument(source: URL,
                                        ext: String,
                                        destination: URL,
                                        layout: SpreadsheetPDFLayout,
                                        progress: @escaping (Double) -> Void) throws {
        progress(0.05)

        // 1) 优先 LibreOffice：Office/ODF/Pages/EPUB 都能吃，排版最接近原版
        if let soffice = resolveSoffice() {
            if try libreOfficeConvert(soffice: soffice,
                                      source: source,
                                      filter: source.pathExtension.lowercased() == "svg"
                                          ? nil : libreOfficeFilter(for: ext),
                                      destination: destination,
                                      layout: layout,
                                      progress: progress) {
                return
            }
            progress(0.4)
        }

        // 2) PDF：退回 cupsfilter（纯文本/RTF/HTML 效果可接受）
        if ext == "pdf" {
            guard let cupsfilter = Shell.which("cupsfilter") else {
                throw ConversionError.toolMissing("系统缺少 cupsfilter，无法生成 PDF")
            }
            let result = try Shell.run(cupsfilter, ["-m", "application/pdf", source.path], stdoutTo: destination)
            if result.status != 0 || fileSize(destination) < 100 {
                try? FileManager.default.removeItem(at: destination)
                throw ConversionError.failed("PDF 生成失败：该格式需要 LibreOffice 支持")
            }
            progress(1.0)
            return
        }

        // 3) 纯文本类：textutil 兜底
        guard let textutil = Shell.which("textutil") else {
            throw ConversionError.toolMissing("系统缺少 textutil")
        }
        let convertName: String
        switch ext {
        case "docx": convertName = "docx"
        case "rtf":  convertName = "rtf"
        case "html": convertName = "html"
        case "odt":  convertName = "odt"
        case "txt":  convertName = "txt"
        default:     convertName = ext
        }

        let result = try Shell.run(textutil, ["-convert", convertName, "-output", destination.path, source.path])
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw ConversionError.failed("文档转换失败：\(result.stderr.suffix(300))")
        }
        progress(1.0)
    }

    /// 调 LibreOffice headless；成功写出 destination 返回 true。
    static func libreOfficeConvert(soffice: String,
                                           source: URL,
                                           filter: String?,
                                           destination: URL,
                                           layout: SpreadsheetPDFLayout = .original,
                                           progress: @escaping (Double) -> Void) throws -> Bool {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("totori-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var input = source
        if layout == .fitWidth, destination.pathExtension.lowercased() == "pdf",
           SpreadsheetPDFLayout.supports(source) {
            if source.pathExtension.lowercased() == "xls" {
                let intermediate = staging.appendingPathComponent("intermediate.xlsx")
                guard try libreOfficeConvert(soffice: soffice, source: source,
                    filter: "xlsx:Calc MS Excel 2007 XML", destination: intermediate,
                    progress: { _ in }) else {
                    throw ConversionError.failed("无法为此 Excel 创建页宽适配副本")
                }
                input = intermediate
            }
            input = try SpreadsheetPDFLayout.fitWidthCopy(of: input, in: staging)
        }

        /// 用指定配置目录跑一次转换；成功写出 destination 返回 true。
        func attempt(profile: URL) throws -> Bool {
            let args = [
                "--headless", "--norestore", "--nolockcheck", "--nodefault",
                "-env:UserInstallation=\(profile.absoluteString)",
                "--convert-to", filter ?? destination.pathExtension,
                "--outdir", staging.path,
                input.path,
            ]
            do {
                _ = try Shell.run(soffice, args, timeout: 300)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 工具启动失败仍允许原有文档后端兜底；取消绝不走兜底。
            }
            try ConversionCancellation.current?.check()

            let produced = (try? FileManager.default.contentsOfDirectory(at: staging,
                                                                        includingPropertiesForKeys: nil))?
                .first { $0.pathExtension.lowercased() == destination.pathExtension.lowercased() }
            guard let produced, fileSize(produced) > 0 else { return false }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: produced, to: destination)
            return true
        }

        // 命中同批预转换的结果就直接取用，不再启动 LibreOffice。
        let fitsWidth = layout == .fitWidth && destination.pathExtension.lowercased() == "pdf"
            && SpreadsheetPDFLayout.supports(source)
        if !fitsWidth,
           let cached = DocumentPrefetch.take(source: source, ext: destination.pathExtension, filter: filter) {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: cached, to: destination)
            try? FileManager.default.removeItem(at: cached)
            progress(1.0)
            return true
        }

        if try withSharedProfile(fallback: staging.appendingPathComponent("profile", isDirectory: true),
                                 attempt) {
            progress(1.0)
            return true
        }
        return false
    }

    /// 优先复用 Totori 专用的配置目录：每次新建配置要多花约一半时间（见基准）。
    /// 它与用户自己的 LibreOffice 配置互不相干；同一时刻只允许一个转换占用，
    /// 占不到锁就退回一次性配置目录。`attempt` 成功产出文件返回 true。
    static func withSharedProfile(fallback: URL, _ attempt: (URL) throws -> Bool) throws -> Bool {
        guard sharedProfileLock.`try`() else { return try attempt(fallback) }
        defer { sharedProfileLock.unlock() }
        let existed = FileManager.default.fileExists(atPath: sharedProfile.path)
        try? FileManager.default.createDirectory(at: sharedProfile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if try attempt(sharedProfile) { return true }
        guard existed else { return false }
        // 复用的配置可能被上次被取消的进程弄坏：用干净配置再试一次，成功就丢弃旧配置。
        try? FileManager.default.removeItem(at: fallback)
        if try attempt(fallback) {
            try? FileManager.default.removeItem(at: sharedProfile)
            return true
        }
        return false
    }

    static let sharedProfileLock = NSLock()

    /// 文档引擎的专用配置目录，放在 Application Support，不会影响用户自己的 LibreOffice。
    static var sharedProfile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Totori/lo-profile", isDirectory: true)
    }

}
