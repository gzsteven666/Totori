import SwiftUI
import UniformTypeIdentifiers
import QuickLook

// MARK: - 状态模型

struct InputFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    let size: Int64

    var name: String { url.lastPathComponent }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func make(_ url: URL) -> InputFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return InputFile(url: url, kind: FormatCatalog.kind(of: url), size: Int64(size))
    }
}

struct ConversionResult: Identifiable {
    let id = UUID()
    let source: URL
    let output: URL?
    let error: String?
    var cancelled: Bool = false
    var outputSummary: ConversionOutputSummary? = nil

    var ok: Bool { output != nil }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var files: [InputFile] = []
    @Published var selectedFormat: OutputFormat?
    @Published var useSourceFolder = true
    @Published var stripMetadata = false
    @Published var taskQuality: TaskConversionQuality = .defaults
    @Published var spreadsheetPDFLayout: SpreadsheetPDFLayout = .original
    @Published var outputDirectory: URL = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())

    @Published var isConverting = false
    @Published var progress: Double = 0
    @Published var statusText = "把文件拖进窗口，或点「选择文件」"
    @Published var results: [ConversionResult] = []
    @Published var jobStates: [URL: JobState] = [:]
    /// 正在转换的文件各自的进度（0…1），行内进度环用；完成或取消后清除。
    @Published var fileProgress: [URL: Double] = [:]
    @Published var cancelRequested = false
    @Published var metadataRevision = 0

    enum JobState: String {
        case queued = "等待中", running = "转换中", succeeded = "已完成", failed = "失败", cancelled = "已取消"
    }

    /// 重试使用原批次的格式、目录和参数，避免设置改动让同一批结果不一致。
    struct BatchPlan {
        let jobs: [InputFile]
        let format: OutputFormat
        let targets: [UUID: URL]
        let stripMetadata: Bool
        let options: CompressionOptions
    }
    var lastPlan: BatchPlan?
    var activeCancellation: ConversionCancellation?
    var activeRun: UUID?

    var failedCount: Int { results.filter { !$0.ok && !$0.cancelled }.count }
    var cancelledCount: Int { results.filter(\.cancelled).count }


    // 选中的文件属于哪一类（取第一个文件的类型）
    var currentKind: FileKind? { files.first?.kind }

    var supportsSpreadsheetPDFLayout: Bool {
        selectedFormat?.ext == "pdf" && files.contains { SpreadsheetPDFLayout.supports($0.url) }
    }

    var availableFormats: [OutputFormat] {
        guard let kind = currentKind else { return [] }
        return FormatCatalog.formats(for: kind, sources: files.map(\.url))
    }

    @Published var importNotice: String?

    /// 统一在增删后校验选择与计数（P1-01）
    func reconcileSelection() {
        let formats = availableFormats
        if formats.isEmpty {
            selectedFormat = nil
        } else if let current = selectedFormat,
                  let matched = formats.first(where: { $0.ext == current.ext }) {
            selectedFormat = matched
        } else {
            selectedFormat = formats.first
        }
        if !isConverting {
            statusText = files.isEmpty
                ? "把文件拖进窗口，或点「选择文件」"
                : "已选 \(files.count) 个文件"
        }
    }

    func add(urls: [URL]) {
        guard !isConverting else {
            importNotice = "正在转换，先把这一批跑完再加文件"
            return
        }
        var seen = Set(files.map(\.url))
        var accepted: [InputFile] = []
        var rejected: [String] = []
        // 批次类型以已有文件为准；空列表时以本批第一个可识别文件为准
        var reference: FileKind? = files.first?.kind

        for url in urls {
            if seen.contains(url) {
                rejected.append("\(url.lastPathComponent)：重复")
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else {
                rejected.append("\(url.lastPathComponent)：不是文件")
                continue
            }
            let file = InputFile.make(url)
            guard file.kind != .unknown else {
                let ext = url.pathExtension.isEmpty ? "无扩展名" : ".\(url.pathExtension)"
                rejected.append("\(url.lastPathComponent)：不支持的类型 \(ext)")
                continue
            }
            if reference == nil { reference = file.kind }
            guard file.kind == reference else {
                rejected.append("\(url.lastPathComponent)：类型与这一批不一致（本批是\(reference!.title)）")
                continue
            }
            seen.insert(url)          // 批内去重（P2-01）
            accepted.append(file)
        }

        files.append(contentsOf: accepted)
        reconcileSelection()
        if !accepted.isEmpty {
            statusText = "已选 \(files.count) 个文件"
        }
        importNotice = rejected.isEmpty
            ? nil
            : "未导入 \(rejected.count) 个文件：\n" + rejected.joined(separator: "\n")
    }

    func clear() {
        guard !isConverting else {
            importNotice = "正在转换，先等这一批结束"
            return
        }
        files.removeAll()
        results.removeAll()
        jobStates.removeAll()
        fileProgress.removeAll()
        lastPlan = nil
        metadataRevision += 1
        selectedFormat = nil
        taskQuality = .defaults
        spreadsheetPDFLayout = .original
        importNotice = nil
        progress = 0
        statusText = "把文件拖进窗口，或点「选择文件」"
    }

    func remove(_ file: InputFile) {
        guard !isConverting else {
            importNotice = "正在转换，先等这一批结束"
            return
        }
        files.removeAll { $0.id == file.id }
        results.removeAll { $0.source == file.url }
        jobStates.removeValue(forKey: file.url)
        reconcileSelection()
        if files.isEmpty { selectedFormat = nil }
    }

    func targetDirectory(for file: InputFile) -> URL {
        useSourceFolder ? file.url.deletingLastPathComponent() : outputDirectory
    }

    /// 主按钮始终处理全部文件；列表选择只通过显式的“转换所选”入口生效。
    func convertAll() { beginBatch(jobs: files) }

    /// 从当前列表筛选选择集合，过期 ID 和空选择不会误触发整批转换。
    func convertSelected(ids: Set<UUID>) {
        beginBatch(jobs: files.filter { ids.contains($0.id) })
    }

    /// 固定新批次的范围与参数。新批次替换上次状态，但不删除磁盘上的任何文件。
    func beginBatch(jobs: [InputFile]) {
        guard !isConverting, let format = selectedFormat, !jobs.isEmpty else { return }
        var options = format.supportsTaskQuality ? taskQuality.options : .none
        if supportsSpreadsheetPDFLayout { options.spreadsheetPDFLayout = spreadsheetPDFLayout }
        let plan = BatchPlan(jobs: jobs, format: format,
                             targets: Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, targetDirectory(for: $0)) }),
                             stripMetadata: stripMetadata, options: options)
        lastPlan = plan
        results.removeAll()
        jobStates.removeAll()
        start(plan: plan, jobs: plan.jobs)
    }

    /// 取消仅影响当前批次，已经发布的输出保留；系统同步图片处理会在当前步骤结束后停止。
    func cancelConversion() {
        guard isConverting, !cancelRequested else { return }
        cancelRequested = true
        statusText = "正在取消…当前处理步骤结束后停止，已完成文件保留"
        activeCancellation?.cancel()
    }

    /// 失败重试固定原批参数，不重复处理已经成功的文件。
    func retryFailed() { retry(includeCancelled: false) }

    /// 取消后可继续所有未完成项，不重复生成已经成功的输出。
    func resumeUnfinished() { retry(includeCancelled: true) }

    func retry(includeCancelled: Bool) {
        guard !isConverting, let plan = lastPlan else { return }
        let pending = Set(results.filter { !$0.ok && (includeCancelled || !$0.cancelled) }.map(\.source))
        let jobs = plan.jobs.filter { pending.contains($0.url) }
        guard !jobs.isEmpty else { return }
        results.removeAll { pending.contains($0.source) }
        start(plan: plan, jobs: jobs)
    }

    func start(plan: BatchPlan, jobs: [InputFile]) {
        let runID = UUID()
        let cancellation = ConversionCancellation()
        activeRun = runID
        activeCancellation = cancellation
        cancelRequested = false
        isConverting = true
        progress = 0
        metadataRevision += 1
        statusText = "准备转换 → \(plan.format.name)"
        fileProgress.removeAll()
        for file in jobs { jobStates[file.url] = .queued }

        Task.detached(priority: .userInitiated) {
            // 同批文档一次启动 LibreOffice 全部转好，下面逐个转换时直接取用。
            ConversionService.prefetchDocuments(sources: jobs.map(\.url), format: plan.format,
                                                options: plan.options, cancellation: cancellation)
            defer { ConversionService.clearPrefetchedDocuments() }
            for (index, file) in jobs.enumerated() {
                if cancellation.isCancelled {
                    let skipped = jobs[index...].map { ConversionResult(source: $0.url, output: nil, error: nil, cancelled: true) }
                    await MainActor.run {
                        guard self.activeRun == runID else { return }
                        self.results.append(contentsOf: skipped)
                        for item in skipped { self.jobStates[item.source] = .cancelled }
                    }
                    break
                }
                let base = Double(index) / Double(jobs.count)
                let span = 1.0 / Double(jobs.count)
                await MainActor.run {
                    guard self.activeRun == runID else { return }
                    self.jobStates[file.url] = .running
                    if !self.cancelRequested { self.statusText = "正在转换 \(file.name)（\(index + 1)/\(jobs.count)）" }
                }
                let result: ConversionResult
                do {
                    // 重试前输入可能已修复，按本次处理时的大小生成摘要。
                    let sourceBytes = (try? FileManager.default.attributesOfItem(atPath: file.url.path))?[.size] as? NSNumber
                    let output = try ConversionService.convert(
                        source: file.url, format: plan.format,
                        to: plan.targets[file.id] ?? file.url.deletingLastPathComponent(),
                        stripMetadata: plan.stripMetadata, options: plan.options, cancellation: cancellation
                    ) { fraction in
                        Task { @MainActor in
                            guard self.activeRun == runID, self.isConverting, !self.cancelRequested else { return }
                            self.progress = max(self.progress, base + span * fraction)
                            self.fileProgress[file.url] = min(1, max(self.fileProgress[file.url] ?? 0, fraction))
                        }
                    }
                    // 在转换工作线程捕获大小；列表重绘时不重复访问磁盘。
                    let outputBytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    let summary: ConversionOutputSummary?
                    if let before = sourceBytes?.int64Value, let after = outputBytes {
                        summary = ConversionOutputSummary(sourceExtension: file.url.pathExtension,
                                                          outputExtension: output.pathExtension,
                                                          sourceBytes: before, outputBytes: after)
                    } else { summary = nil }
                    result = ConversionResult(source: file.url, output: output, error: nil, outputSummary: summary)
                } catch is CancellationError {
                    result = ConversionResult(source: file.url, output: nil, error: nil, cancelled: true)
                } catch {
                    result = ConversionResult(source: file.url, output: nil,
                                              error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                await MainActor.run {
                    guard self.activeRun == runID else { return }
                    self.results.append(result)
                    self.fileProgress.removeValue(forKey: file.url)
                    self.jobStates[file.url] = result.ok ? .succeeded : (result.cancelled ? .cancelled : .failed)
                    if !result.cancelled { self.progress = max(self.progress, base + span) }
                }
            }
            await MainActor.run {
                guard self.activeRun == runID else { return }
                let order = Dictionary(uniqueKeysWithValues: plan.jobs.enumerated().map { ($0.element.url, $0.offset) })
                self.results.sort { order[$0.source, default: 0] < order[$1.source, default: 0] }
                self.isConverting = false
                self.fileProgress.removeAll()
                self.activeCancellation = nil
                self.activeRun = nil
                self.metadataRevision += 1
                let successful = self.results.filter(\.ok).count
                if cancellation.isCancelled {
                    self.statusText = "已取消：完成 \(successful) 个，失败 \(self.failedCount) 个，未完成 \(self.cancelledCount) 个"
                } else {
                    self.progress = 1
                    self.statusText = self.failedCount == 0
                        ? "完成：\(successful) 个文件转换成功"
                        : "完成：成功 \(successful) 个，失败 \(self.failedCount) 个"
                }
                self.cancelRequested = false
                // 重试只记录这次实际执行的项；上一批的成功输出仍留在之前的记录里。
                let executed = Set(jobs.map(\.url))
                RecentTasksStore.shared.record(RecentTaskRecord(
                    title: "转换为 \(plan.format.name)", origin: .mainWindow,
                    items: self.results.filter { executed.contains($0.source) }.map(RecentTaskItem.init(result:))))
            }
        }
    }

    func revealLastOutput() {
        let urls = results.compactMap(\.output)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

