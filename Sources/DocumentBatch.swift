import Foundation

/// 同批文档的预转换结果。
///
/// LibreOffice 每次启动要加载字体与配置，约占单个小文档转换的九成时间（见基准）。
/// 批量转换前先用一次启动处理整批文档，结果暂存在这里；随后逐个文件的转换流程
/// （进度、取消、命名、结果汇报）保持不变，只是命中暂存时直接取用，没命中则照旧单独转换。
enum DocumentPrefetch {
    private struct Entry {
        let output: URL
        let sourceSize: Int64
        let sourceModified: Date?
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var directories: [URL] = []
    private(set) static var hits = 0

    private static func key(_ source: URL, _ ext: String, _ filter: String?) -> String {
        "\(source.standardizedFileURL.path)|\(ext.lowercased())|\(filter ?? "")"
    }

    private static func stamp(_ url: URL) -> (Int64, Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? -1), values?.contentModificationDate)
    }

    /// 取走一条暂存结果；源文件在预转换之后被改动过则视为失效。
    static func take(source: URL, ext: String, filter: String?) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: key(source, ext, filter)) else { return nil }
        let now = stamp(source)
        guard now.0 == entry.sourceSize, now.1 == entry.sourceModified,
              FileManager.default.fileExists(atPath: entry.output.path) else { return nil }
        hits += 1
        return entry.output
    }

    fileprivate static func store(source: URL, ext: String, filter: String?, output: URL) {
        let size = stamp(source)
        lock.lock()
        entries[key(source, ext, filter)] = Entry(output: output, sourceSize: size.0, sourceModified: size.1)
        lock.unlock()
    }

    fileprivate static func track(directory: URL) {
        lock.lock()
        directories.append(directory)
        lock.unlock()
    }

    /// 批次结束（或取消）后调用，删除所有未被取用的暂存文件。
    static func clear() {
        lock.lock()
        let stale = directories
        directories.removeAll()
        entries.removeAll()
        lock.unlock()
        stale.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// 一次启动 LibreOffice 转换整批文档。任何失败都静默放弃，由逐个文件的流程兜底。
    ///
    /// 只处理确定能放进同一次调用的文件：同名（忽略大小写）的源文件会在同一输出目录里互相覆盖，
    /// 需要“适配页宽”的电子表格要先改临时副本，SVG 用的是另一套过滤器，这些都留给单文件流程。
    static func prefetch(sources: [URL], ext: String, layout: SpreadsheetPDFLayout,
                         cancellation: ConversionCancellation?) throws {
        guard sources.count >= 2, let soffice = Engine.resolveSoffice() else { return }
        let outputExt = ext.lowercased()
        var seen: [String: Int] = [:]
        for url in sources { seen[url.deletingPathExtension().lastPathComponent.lowercased(), default: 0] += 1 }
        let eligible = sources.filter { url in
            let lower = url.pathExtension.lowercased()
            let fitsWidth = layout == .fitWidth && outputExt == "pdf" && SpreadsheetPDFLayout.supports(url)
            // 靠文件头识别、没有正确扩展名的文件交给单文件流程（那里会补上扩展名）
            let knownExtension = lower == FormatCatalog.effectiveExtension(of: url)
            return FormatCatalog.kind(of: url) == .document && lower != "svg" && !fitsWidth && knownExtension
                && seen[url.deletingPathExtension().lastPathComponent.lowercased()] == 1
        }
        guard eligible.count >= 2 else { return }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xiaoju-lo-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        track(directory: directory)

        let filter = Engine.libreOfficeFilter(for: outputExt)
        try ConversionCancellation.withCurrent(cancellation) {
            _ = try Engine.withSharedProfile(fallback: directory.appendingPathComponent("profile", isDirectory: true)) { profile in
                let outdir = directory.appendingPathComponent("out", isDirectory: true)
                try? FileManager.default.removeItem(at: outdir)
                try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
                let args = ["--headless", "--norestore", "--nolockcheck", "--nodefault",
                            "-env:UserInstallation=\(profile.absoluteString)",
                            "--convert-to", filter, "--outdir", outdir.path] + eligible.map(\.path)
                do {
                    // 每个文件仍按 5 分钟估算上限，整批封顶 1 小时。
                    _ = try Shell.run(soffice, args, timeout: min(300 * Double(eligible.count), 3600))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return false
                }
                try ConversionCancellation.current?.check()
                var produced = 0
                for url in eligible {
                    let output = outdir.appendingPathComponent(
                        url.deletingPathExtension().lastPathComponent + "." + outputExt)
                    if Engine.fileSize(output) > 0 {
                        store(source: url, ext: outputExt, filter: filter, output: output)
                        produced += 1
                    }
                }
                return produced > 0
            }
        }
    }
}

extension ConversionService {
    /// 批量转换文档前调用：同一次启动处理整批，之后逐个转换会命中暂存结果。
    /// 对非文档格式、单个文件或没有 LibreOffice 的环境不做任何事。
    static func prefetchDocuments(sources: [URL], format: OutputFormat, options: CompressionOptions,
                                  cancellation: ConversionCancellation? = nil) {
        guard format.kind == .document else { return }
        try? queue.sync {
            try DocumentPrefetch.prefetch(sources: sources, ext: format.ext,
                                          layout: options.spreadsheetPDFLayout, cancellation: cancellation)
        }
    }

    static func clearPrefetchedDocuments() { DocumentPrefetch.clear() }
}
