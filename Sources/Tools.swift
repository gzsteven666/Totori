import AppKit
import PDFKit

// MARK: - 通用：输出路径

enum OutputNaming {
    static func path(for source: URL, suffix: String, ext: String? = nil) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let targetExt = ext ?? source.pathExtension
        var candidate = directory.appendingPathComponent("\(base)\(suffix).\(targetExt)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)\(suffix) \(index).\(targetExt)")
            index += 1
        }
        return candidate
    }
}

/// 统一的收尾提示
@MainActor
enum Feedback {
    static func success(_ message: String, outputs: [URL] = [], detail: String? = nil,
                        comparisons: [OutputComparison] = []) {
        NSSound(named: "Glass")?.play()
        CompletionPanel.shared.present(message: message, outputs: outputs, detail: detail, comparisons: comparisons)
    }

    static func failure(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = failures.count == 1 ? "有一个文件没成功" : "有 \(failures.count) 个文件没成功"
        alert.informativeText = failures.joined(separator: "\n")
        alert.runModal()
    }
}

// MARK: - 转换

enum ConversionRunner {
    /// 串行队列：以前是个 bool 锁，「正在转换时来的请求直接丢掉」，
    /// 一旦有一次转换卡住，后面所有转换都静默失效。改成排队执行。
    private static let queue = DispatchQueue(label: "xiaoju.convert", qos: .userInitiated)

    /// 滚轮/压缩任务与主窗口使用相同取消令牌和结果对比入口；失败可沿用原设置重试。
    static func run(urls: [URL], format: OutputFormat,
                    options: CompressionOptions? = nil,
                    isCompression: Bool = false) {
        let optionsSnapshot = options ?? CompressionOptions.fromDefaults()
        let cancellation = ConversionCancellation()
        DiagLog.write("convert 入队 \(urls.count) 个 → \(format.name)")
        queue.async {
            var failures: [String] = []
            var failedURLs: [URL] = []
            var outputs: [URL] = []
            var comparisons: [OutputComparison] = []
            var notes: [String] = []
            var savedBytes: Int64 = 0
            var cancelledCount = 0
            var taskItems: [RecentTaskItem] = []
            DispatchQueue.main.async {
                ProgressCenter.shared.begin(title: "正在转换 → \(format.name)", files: urls.count,
                                            onCancel: { cancellation.cancel() })
            }
            for (index, url) in urls.enumerated() {
                if cancellation.isCancelled {
                    cancelledCount += urls.count - index
                    taskItems += urls[index...].map { RecentTaskItem(source: $0, cancelled: true) }
                    break
                }
                do {
                    DispatchQueue.main.async { ProgressCenter.shared.nextFile(index) }
                    let progress: (Double) -> Void = { value in
                        DispatchQueue.main.async {
                            if !cancellation.isCancelled { ProgressCenter.shared.update(value) }
                        }
                    }
                    if isCompression {
                        let result = try ConversionService.compress(source: url, format: format,
                                                                    options: optionsSnapshot, cancellation: cancellation, progress: progress)
                        if let output = result.output {
                            outputs.append(output)
                            comparisons.append(OutputComparison(source: url, output: output))
                            taskItems.append(RecentTaskItem(source: url, output: output))
                            savedBytes += result.savedBytes
                        } else {
                            taskItems.append(RecentTaskItem(source: url, keptOriginal: true))
                            notes.append("\(url.lastPathComponent)：本次编码没有减小体积，保留原文件（\(result.sourceBytes) → \(result.encodedBytes) 字节）。")
                        }
                    } else {
                        let output = try ConversionService.convert(source: url, format: format,
                                                                  to: url.deletingLastPathComponent(),
                                                                  options: optionsSnapshot, cancellation: cancellation, progress: progress)
                        outputs.append(output)
                        comparisons.append(OutputComparison(source: url, output: output))
                        taskItems.append(RecentTaskItem(source: url, output: output))
                    }
                } catch is CancellationError {
                    cancelledCount += 1
                    taskItems.append(RecentTaskItem(source: url, cancelled: true))
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    failures.append("\(url.lastPathComponent)：\(message)")
                    failedURLs.append(url)
                    taskItems.append(RecentTaskItem(source: url, error: message))
                }
            }
            if isCompression, savedBytes > 0 {
                notes.insert("实际节省 \(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))（\(savedBytes) 字节）", at: 0)
            }
            if cancelledCount > 0 { notes.append("已取消 \(cancelledCount) 个未完成文件，已生成的结果保留。") }
            notes += failures
            let completed = outputs, pairs = comparisons, retryURLs = failedURLs
            let details = notes.isEmpty ? nil : notes.joined(separator: "\n")
            let failureCount = failures.count, wasCancelled = cancellation.isCancelled
            let historyItems = taskItems
            DispatchQueue.main.async {
                let title = wasCancelled ? "已取消" : (failureCount > 0 ? "有 \(failureCount) 个失败" : (completed.isEmpty ? "已保留原文件" : "已完成 \(completed.count) 个文件"))
                ProgressCenter.shared.finish(message: title)
                RecentTasksStore.shared.record(RecentTaskRecord(
                    title: "\(isCompression ? "压缩为" : "转换为") \(format.name)",
                    origin: isCompression ? .compression : .petals,
                    items: historyItems, detail: details))
                let retry: (() -> Void)? = retryURLs.isEmpty ? nil : {
                    run(urls: retryURLs, format: format, options: optionsSnapshot, isCompression: isCompression)
                }
                CompletionPanel.shared.present(message: title, outputs: completed, detail: details,
                                               comparisons: pairs, retry: retry,
                                               symbol: wasCancelled ? "stop.circle" : (failureCount > 0 ? "exclamationmark.circle" : "checkmark.circle.fill"))
            }
        }
    }
}

extension ToolRunner {
    /// 合并 PDF：把所有输入并成一份
    static func mergePDF(urls: [URL]) throws -> URL {
        guard let first = urls.first else {
            throw ConversionError.failed("没有选中文件")
        }
        let merged = PDFDocument()
        for url in urls {
            guard let doc = PDFDocument(url: url) else {
                throw ConversionError.failed("打不开 \(url.lastPathComponent)")
            }
            for index in 0..<doc.pageCount {
                if let page = doc.page(at: index) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0 else {
            throw ConversionError.failed("没有可合并的页面")
        }
        let destination = OutputNaming.path(for: first, suffix: "-合并", ext: "pdf")
        guard merged.write(to: destination) else {
            throw ConversionError.failed("写出失败")
        }
        return destination
    }

    /// 拆分 PDF：一页一个文件，放进同名文件夹
    @discardableResult
    static func splitPDF(_ url: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.failed("打不开 \(url.lastPathComponent)")
        }
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        var folder = parent.appendingPathComponent("\(base)-拆页")
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base)-拆页 \(counter)")
            counter += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let name = String(format: "%@-%03d.pdf", base, index + 1)
            let output = folder.appendingPathComponent(name)
            guard single.write(to: output) else { throw ConversionError.failed("写出失败：\(name)") }
            outputs.append(output)
        }
        return outputs
    }
}

enum ToolRunner {
    @MainActor
    static func run(urls: [URL], tool: ToolKind) {
        // 裁剪需要交互，直接开编辑器
        if tool == .trimMedia {
            guard let first = urls.first else { return }
            DispatchQueue.main.async { TrimEditor.shared.present(url: first) }
            return
        }
        if tool == .redactImage {
            guard let first = urls.first else { return }
            DispatchQueue.main.async { RedactEditor.shared.present(url: first) }
            return
        }
        if tool == .compressImage {
            DispatchQueue.main.async { CompressionPanel.shared.present(urls: urls) }
            return
        }
        if tool == .cropImage {
            guard let first = urls.first else { return }
            CropEditor.shared.present(url: first)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var outputs: [URL] = []
            var comparisons: [OutputComparison] = []
            if tool == .mergePDF {
                do {
                    guard urls.count > 1 else { throw ConversionError.failed("合并需要至少两个 PDF") }
                    outputs = [try mergePDF(urls: urls)]
                } catch { failures.append(error.localizedDescription) }
            } else {
                for url in urls {
                    do {
                        let produced = try apply(tool, to: url)
                        outputs += produced
                        comparisons += produced.map { OutputComparison(source: url, output: $0) }
                    }
                    catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
            }
            let completed = outputs
            let pairs = comparisons
            let errors = failures
            DispatchQueue.main.async {
                if !completed.isEmpty || errors.isEmpty {
                    Feedback.success(tool == .qrText ? "二维码内容已复制" : "\(tool.title)完成", outputs: completed, comparisons: pairs)
                }
                if !errors.isEmpty { Feedback.failure(errors) }
            }
        }
    }

    private static func apply(_ tool: ToolKind, to url: URL) throws -> [URL] {
        switch tool {
        case .cropImage, .redactImage, .trimMedia:
            break   // 交互式
        case .qrText:
            let codes = try QRReader.read(url)
            guard !codes.isEmpty else {
                throw ConversionError.failed("这张图里没有二维码")
            }
            let text = codes.joined(separator: "\n")
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return []
        case .splitPDF:
            return try splitPDF(url)
        case .mergePDF:
            break   // 多文件，走 run(urls:) 的特例

        case .compressImage:
            return [try sips(url, ["-s", "formatOptions", "55"], suffix: "-压缩")]
        case .resizeSmall:
            let size = try pixelSize(url)
            let target = max(Int(Double(max(size.width, size.height)) * 0.5), 1)
            return [try sips(url, ["-Z", "\(target)"], suffix: "-小图")]
        case .rotateRight:
            return [try sips(url, ["-r", "90"], suffix: "-旋转")]
        case .stripMetadata:
            guard let format = FormatCatalog.images.first(where: {
                $0.ext == url.pathExtension.lowercased()
            }) ?? FormatCatalog.images.first(where: { $0.ext == "png" }) else {
                throw ConversionError.unsupported("不支持的图片格式")
            }
            return [try ConversionService.convert(source: url, format: format,
                                                   to: url.deletingLastPathComponent(),
                                                   stripMetadata: true) { _ in }]

        case .toPDF:
            guard let format = FormatCatalog.all.first(where: { $0.ext == "pdf" }) else {
                throw ConversionError.unsupported("没有 PDF 目标")
            }
            return [try ConversionService.convert(source: url, format: format,
                                                   to: url.deletingLastPathComponent()) { _ in }]
        case .zipArchive:
            guard let ditto = Shell.which("ditto") else {
                throw ConversionError.toolMissing("系统缺少 ditto")
            }
            let destination = OutputNaming.path(for: url, suffix: "", ext: "zip")
            let result = try Shell.run(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                               url.path, destination.path])
            guard result.status == 0 else {
                throw ConversionError.failed("打包失败：\(result.stderr.suffix(160))")
            }
            return [destination]
        }
        return []
    }

    private static func sips(_ url: URL, _ args: [String], suffix: String) throws -> URL {
        guard let sips = Shell.which("sips") else {
            throw ConversionError.toolMissing("系统缺少 sips")
        }
        let destination = OutputNaming.path(for: url, suffix: suffix)
        let result = try Shell.run(sips, args + [url.path, "--out", destination.path])
        guard result.status == 0 else {
            throw ConversionError.failed("处理失败：\(result.stderr.suffix(160))")
        }
        return destination
    }

    private static func pixelSize(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError.failed("读不到图片尺寸")
        }
        return (width, height)
    }
}

// MARK: - 文件动作

enum ActionRunner {
    @MainActor
    static func run(urls: [URL], action: ActionKind) {
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop) else {
                showAlert("这台 Mac 不支持隔空投送")
                return
            }
            service.perform(withItems: urls)

        case .copy:
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects(urls as [NSURL])

        case .move:
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            var failures: [String] = []
            for url in urls {
                let destination = uniqueURL(downloads.appendingPathComponent(url.lastPathComponent))
                do { try FileManager.default.moveItem(at: url, to: destination) }
                catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            if !failures.isEmpty { Feedback.failure(failures) } else { Feedback.success("已移动") }

        case .copyPath:
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)

        case .terminal:
            guard let first = urls.first else { return }
            let directory = first.deletingLastPathComponent()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", directory.path]
            try? process.run()

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    @MainActor
    private static func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
