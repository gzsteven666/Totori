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
    @Published var cancelRequested = false
    @Published var metadataRevision = 0

    enum JobState: String {
        case queued = "等待中", running = "转换中", succeeded = "已完成", failed = "失败", cancelled = "已取消"
    }

    /// 重试使用原批次的格式、目录和参数，避免设置改动让同一批结果不一致。
    private struct BatchPlan {
        let jobs: [InputFile]
        let format: OutputFormat
        let targets: [UUID: URL]
        let stripMetadata: Bool
        let options: CompressionOptions
    }
    private var lastPlan: BatchPlan?
    private var activeCancellation: ConversionCancellation?
    private var activeRun: UUID?

    var failedCount: Int { results.filter { !$0.ok && !$0.cancelled }.count }
    var cancelledCount: Int { results.filter(\.cancelled).count }


    // 选中的文件属于哪一类（取第一个文件的类型）
    var currentKind: FileKind? { files.first?.kind }

    var supportsSpreadsheetPDFLayout: Bool {
        selectedFormat?.ext == "pdf" && files.contains { SpreadsheetPDFLayout.supports($0.url) }
    }

    var availableFormats: [OutputFormat] {
        guard let kind = currentKind else { return [] }
        return FormatCatalog.formats(for: kind)
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

    private func targetDirectory(for file: InputFile) -> URL {
        useSourceFolder ? file.url.deletingLastPathComponent() : outputDirectory
    }

    /// 主按钮始终处理全部文件；列表选择只通过显式的“转换所选”入口生效。
    func convertAll() { beginBatch(jobs: files) }

    /// 从当前列表筛选选择集合，过期 ID 和空选择不会误触发整批转换。
    func convertSelected(ids: Set<UUID>) {
        beginBatch(jobs: files.filter { ids.contains($0.id) })
    }

    /// 固定新批次的范围与参数。新批次替换上次状态，但不删除磁盘上的任何文件。
    private func beginBatch(jobs: [InputFile]) {
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

    private func retry(includeCancelled: Bool) {
        guard !isConverting, let plan = lastPlan else { return }
        let pending = Set(results.filter { !$0.ok && (includeCancelled || !$0.cancelled) }.map(\.source))
        let jobs = plan.jobs.filter { pending.contains($0.url) }
        guard !jobs.isEmpty else { return }
        results.removeAll { pending.contains($0.source) }
        start(plan: plan, jobs: jobs)
    }

    private func start(plan: BatchPlan, jobs: [InputFile]) {
        let runID = UUID()
        let cancellation = ConversionCancellation()
        activeRun = runID
        activeCancellation = cancellation
        cancelRequested = false
        isConverting = true
        progress = 0
        metadataRevision += 1
        statusText = "准备转换 → \(plan.format.name)"
        for file in jobs { jobStates[file.url] = .queued }

        Task.detached(priority: .userInitiated) {
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
                    self.jobStates[file.url] = result.ok ? .succeeded : (result.cancelled ? .cancelled : .failed)
                    if !result.cancelled { self.progress = max(self.progress, base + span) }
                }
            }
            await MainActor.run {
                guard self.activeRun == runID else { return }
                let order = Dictionary(uniqueKeysWithValues: plan.jobs.enumerated().map { ($0.element.url, $0.offset) })
                self.results.sort { order[$0.source, default: 0] < order[$1.source, default: 0] }
                self.isConverting = false
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

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isTargeted = false
    @State private var selection = FileListSelection()
    @FocusState private var focusedControl: FileControl?
    private enum FileControl { case addFiles, outputFormat, settings, cancel }
    @State private var previewURL: URL?
    @State private var previewItems: [URL] = []
    @State private var fileListFocusRequest = 0
    @State private var dragShortcutHint = KeyMap.conversionDragHint
    @State private var impactSources: [FileMetadataSnapshot] = []
    @AppStorage("xiaoju.convertQuality") private var convertQuality = ""

    private var defaultQualityTitle: String {
        CompressionPreset(rawValue: convertQuality)?.title ?? "标准"
    }
    private var selectedFileCount: Int {
        model.files.filter { selection.ids.contains($0.id) }.count
    }
    private var saveLocation: String {
        model.useSourceFolder ? "原文件所在文件夹" : model.outputDirectory.path
    }
    private var impactRequest: [String] {
        model.files.map { $0.url.path } + ["revision:\(model.metadataRevision)"]
    }
    private var actionNote: String? {
        if model.primaryAction == .start {
            return selectedFileCount > 0 && selectedFileCount < model.files.count
                ? "主按钮转换全部 \(model.files.count) 个；仅处理所选请点“转换所选 \(selectedFileCount) 个”" : nil
        }
        return model.primaryActionNote
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line.opacity(0.5))
            if let notice = model.importNotice { noticeBar(notice) }
            if model.files.isEmpty {
                emptyState
            } else {
                importBar
                fileList
                Divider().overlay(Palette.line.opacity(0.5))
                options.disabled(model.isConverting)
            }
            Divider().overlay(Palette.line.opacity(0.5))
            footer
        }
        .tint(Palette.brand)
        .frame(minWidth: 760, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !model.isConverting else {
                model.importNotice = "正在转换，请在这一批结束后添加文件"
                return false
            }
            return load(providers)
        }
        .background(Palette.canvas)
        .onReceive(NotificationCenter.default.publisher(for: KeyMap.didChange)) { _ in
            dragShortcutHint = KeyMap.conversionDragHint
        }
        .onReceive(model.$files) { files in
            selection.prune(files.map(\.id))
            previewItems = previewItems.filter { url in files.contains { $0.url == url } }
            if let previewURL, !files.contains(where: { $0.url == previewURL }) { self.previewURL = nil }
        }
        .quickLookPreview($previewURL, in: previewItems)
        .task(id: impactRequest) {
            impactSources = []
            let values = await ConversionImpact.read(model.files.map(\.url))
            guard !Task.isCancelled else { return }
            impactSources = values
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "leaf.fill").resizable().scaledToFit().foregroundStyle(Palette.brand)
                }
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Totori").font(.system(size: Palette.TypeSize.title, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("本地文件转换").font(.system(size: Palette.TypeSize.caption))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button { RecentTasksWindow.shared.present() } label: { Label("最近任务", systemImage: "clock.arrow.circlepath") }
                .controlSize(.small).accessibilityIdentifier("recent.open")
            Button { FileShelf.shared.toggle() } label: { Label("文件浮窗", systemImage: "square.on.square") }
                .controlSize(.small).disabled(model.isConverting)
            Button { SettingsWindow.shared.present() } label: { Label("设置", systemImage: "gearshape") }
                .controlSize(.small).keyboardShortcut(",", modifiers: .command)
                .focusable().focused($focusedControl, equals: .settings)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Palette.surface)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.danger)
            ScrollView {
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: min(88, CGFloat(text.split(separator: "\n").count) * 16 + 4))
            Spacer(minLength: 0)
            Button("知道了") { model.importNotice = nil }.buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Palette.danger.opacity(0.08))
    }

    /// 空态只有一个导入入口，导入后由紧凑工具条接管，不挤占文件列表。
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            ZStack {
                Circle().fill(LinearGradient(colors: [Palette.glassTop, Palette.glassBottom],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: Palette.brand.opacity(0.12), radius: 14, y: 6)
                if let paw = PawAssets.open {
                    Image(nsImage: paw).resizable().scaledToFit().padding(17)
                } else {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .light))
                        .foregroundStyle(Palette.brand)
                }
            }.frame(width: 92, height: 92).accessibilityHidden(true)
            VStack(spacing: 9) {
                Text("把文件拖到这里").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("图片 · 文档 · 音视频 · 压缩包")
                    .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                Text("同类文件可批量转换，原文件会保留")
                    .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            }
            Button("选择文件…") { pickFiles() }
                .buttonStyle(BrandPrimaryButtonStyle()).accessibilityIdentifier("import.choose")
            Text(dragShortcutHint)
                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isTargeted ? Palette.brandSoft.opacity(0.75) : Palette.surface.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(isTargeted ? Palette.brand : Palette.line.opacity(0.8),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5])))
                .padding(24)
        )
    }

    private var importBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(Palette.brand).accessibilityHidden(true)
            Text("\(model.files.count) 个文件").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(isTargeted ? "松手添加到列表" : "可继续拖入同类文件")
                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            Spacer()
            Button("添加文件…") { pickFiles() }.controlSize(.small)
                .focusable().focused($focusedControl, equals: .addFiles)
                .accessibilityIdentifier("import.choose")
            Button("清空") { model.clear() }.buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary).help("清空列表，保留磁盘上的文件")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(isTargeted ? Palette.brandSoft : Palette.surfaceSecondary.opacity(0.5))
        .disabled(model.isConverting)
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(model.files) { file in
                    HStack(spacing: 12) {
                        Button { selectFileRow(file) } label: {
                            Image(systemName: selection.ids.contains(file.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(Palette.brand).frame(width: 22)
                        }
                        .buttonStyle(.plain).help("选择文件；⌘ 点击多选，⇧ 点击范围选择")
                        .accessibilityLabel("选择 \(file.name)")
                        .accessibilityValue(selection.ids.contains(file.id) ? "已选" : "未选")
                        .accessibilityIdentifier("file.select.\(file.id)")
                        FileRowThumbnail(url: file.url, kind: file.kind, revision: model.metadataRevision)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).font(.system(size: Palette.TypeSize.body, weight: .medium))
                                .foregroundStyle(Palette.textPrimary).lineLimit(1).truncationMode(.middle)
                                .help(file.url.path)
                            FileSummaryLabel(url: file.url, revision: model.metadataRevision)
                            if let state = model.jobStates[file.url] {
                                Label(state.rawValue, systemImage: stateSymbol(state))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(state == .failed ? Palette.danger :
                                                        (state == .succeeded ? Palette.success : Palette.textSecondary))
                            }
                            if let summary = model.results.first(where: { $0.source == file.url })?.outputSummary {
                                Text(summary.text).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(summary.isSmaller ? Palette.success : Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("file.outputSummary.\(file.id)")
                            }
                            if let result = model.results.first(where: { $0.source == file.url }), let error = result.error {
                                Text(error).font(.system(size: 11)).foregroundStyle(Palette.danger)
                                    .lineLimit(2).help(error)
                            }
                        }
                        Spacer(minLength: 12)
                        Button {
                            applyFileSelection(file.id, extend: false)
                            showPreview(file)
                        } label: { Image(systemName: "eye") }
                            .buttonStyle(.plain).foregroundStyle(Palette.textSecondary)
                            .help("快速查看原文件（空格）")
                            .accessibilityLabel("快速查看 \(file.name)")
                            .accessibilityIdentifier("file.preview.\(file.id)")
                        if let output = model.results.first(where: { $0.source == file.url })?.output {
                            Button("对比结果") {
                                let pairs = model.results.compactMap { result in
                                    result.output.map { OutputComparison(source: result.source, output: $0) }
                                }
                                ComparisonWindow.shared.present(pairs: pairs, selectedOutput: output)
                            }
                                .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("对比 \(file.name) 的转换结果")
                                .accessibilityIdentifier("file.compare.\(file.id)")
                        }
                        if !model.isConverting {
                            Button { model.remove(file) } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                                .buttonStyle(.plain).foregroundStyle(Palette.textSecondary)
                                .padding(5).contentShape(Rectangle())
                                .help("从列表移除，保留原文件")
                                .accessibilityLabel("移除 \(file.name)")
                                .accessibilityIdentifier("file.remove.\(file.id)")
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 10)
                    .background(selection.ids.contains(file.id) ? Palette.brandSoft.opacity(0.65) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle()).onTapGesture { selectFileRow(file) }
                    .accessibilityElement(children: .contain)
                    .id(file.id)
                    .contextMenu {
                        Button("快速查看") { showPreview(file) }
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Button(selection.ids.contains(file.id) && selection.ids.count > 1 ? "移除选中的 \(selection.ids.count) 个文件" : "从列表移除") {
                            if selection.ids.contains(file.id) { removeSelectedFiles() }
                            else { model.remove(file) }
                        }.disabled(model.isConverting)
                    }
                    Divider().overlay(Palette.line.opacity(0.35))
                }
              }.padding(.horizontal, 10).padding(.top, 4)
            }
            .accessibilityIdentifier("files.list")
            .background(FileListKeyboardHandler(focusRequest: fileListFocusRequest, onTab: { backwards in
                if model.isConverting {
                    focusedControl = backwards || model.cancelRequested ? .settings : .cancel
                } else { focusedControl = backwards ? .addFiles : .outputFormat }
            }) { action in
                switch action {
                case .preview: showPreview()
                case .remove: removeSelectedFiles()
                case .selectAll:
                    selection.selectAll(model.files.map(\.id))
                case .clear: selection.clear()
                case let .move(step, extend):
                    if let target = moveFileSelection(by: step, extend: extend) { proxy.scrollTo(target, anchor: .center) }
                }
            })
            HStack {
                Text(selection.ids.isEmpty ? "⌘ 点击多选" : "已选 \(selection.ids.count) / \(model.files.count)")
                Spacer()
                Text("空格预览 · Delete 移除 · 原文件保留")
            }
            .font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 20).padding(.vertical, 7)
        }
        .frame(maxHeight: .infinity).background(Palette.surface)
        }
    }

    /// 行选择保留独立的预览/对比/移除按钮；范围按当前列表顺序计算。
    private func selectFileRow(_ file: InputFile) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        applyFileSelection(file.id, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
        focusedControl = nil
        fileListFocusRequest += 1
    }

    private func applyFileSelection(_ id: UUID, extend: Bool, toggle: Bool = false) {
        selection.select(id, order: model.files.map(\.id), extend: extend, toggle: toggle)
    }

    /// 键盘换项后返回目标 ID，由 ScrollViewReader 把目标滚入视野。
    private func moveFileSelection(by step: Int, extend: Bool) -> UUID? {
        selection.move(step, order: model.files.map(\.id), extend: extend)
    }

    /// 批量移除只更新列表引用；转换中与单项移除使用同一保护。
    private func removeSelectedFiles() {
        guard !model.isConverting else { return }
        let files = model.files.filter { selection.ids.contains($0.id) }
        for file in files { model.remove(file) }
        selection.clear()
    }

    /// 多选时只预览选中组；眼睛按钮先选中单项，右键未选行只预览该行。
    private func showPreview(_ target: InputFile? = nil) {
        if let target, !selection.ids.contains(target.id) { previewItems = [target.url] }
        else { previewItems = model.files.filter { selection.ids.contains($0.id) }.map(\.url) }
        previewURL = target?.url ?? previewItems.first
    }

    private func stateSymbol(_ state: AppModel.JobState) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "pause.circle"
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.supportsSpreadsheetPDFLayout {
                HStack(spacing: 12) {
                    Text("Excel 排版").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                        .frame(width: 60, alignment: .leading)
                    Picker("Excel 排版", selection: $model.spreadsheetPDFLayout) {
                        ForEach(SpreadsheetPDFLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }.labelsHidden().frame(width: 160)
                        .accessibilityIdentifier("task.spreadsheet-pdf-layout")
                    Text("适配页宽：A4 横向，1 页宽，高度自动")
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 12) {
                Text("输出格式").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Picker("输出格式", selection: $model.selectedFormat) {
                    ForEach(model.availableFormats) { format in Text(format.name).tag(Optional(format)) }
                }.labelsHidden().frame(width: 140).disabled(model.availableFormats.isEmpty)
                    .focusable().focused($focusedControl, equals: .outputFormat)
                if let format = model.selectedFormat {
                    Text(format.ext == "jpg" ? "有损，适合照片" : format.hint).font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1).layoutPriority(-1).help(format.hint)
                }
                Spacer()
                if model.selectedFormat?.supportsTaskQuality == true {
                    Text("本次质量").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    Picker("本次质量", selection: $model.taskQuality) {
                        ForEach(TaskConversionQuality.allCases) { quality in
                            Text(quality == .defaults ? "默认（\(defaultQualityTitle)）" : quality.title).tag(quality)
                        }
                    }.labelsHidden().frame(width: 138)
                        .accessibilityIdentifier("task.quality")
                        .help("仅用于按当前设置开始的新批次；重试沿用原批次参数。不会更改设置中的默认质量，也不会缩小图片尺寸。")
                }
                if model.currentKind == .image {
                    Toggle("移除元数据", isOn: $model.stripMetadata).font(.system(size: 11))
                        .toggleStyle(BrandCheckboxStyle()).help("仅影响输出图片，保留原文件")
                }
            }
            if let format = model.selectedFormat {
                let impact = ConversionImpact.text(format: format, sources: impactSources)
                let generic = format.ext == "jpg" ? "有损，适合照片" : format.hint
                if impact != generic {
                    Label(impact, systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("conversion.impact")
                }
            }
            HStack(spacing: 12) {
                Text("保存到").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Menu {
                    Button("原文件所在文件夹") { model.useSourceFolder = true }
                    Button("选择文件夹…") { pickOutputDirectory() }
                } label: {
                    Label(saveLocation, systemImage: "folder").font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle)
                }.help(saveLocation).accessibilityIdentifier("output.location")
                    .frame(maxWidth: 430, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(Palette.canvas)
    }

    /// 每个阶段只强调一个动作，取消与重新转换不会冒充默认的下一步。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isConverting {
                ProgressView(value: model.progress).progressViewStyle(BrandProgressStyle())
            }
            if let note = actionNote {
                Label(note, systemImage: model.primaryAction == .newBatch ? "info.circle" : "arrow.clockwise")
                    .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(model.taskSummary).font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 16)
                if !model.files.isEmpty {
                    if model.isConverting {
                        Button(model.cancelRequested ? "取消中…" : "取消任务") { model.cancelConversion() }
                            .disabled(model.cancelRequested).accessibilityIdentifier("task.cancel")
                            .focusable().focused($focusedControl, equals: .cancel)
                    } else if !model.results.isEmpty {
                        if model.primaryAction == .reveal {
                            Button("新建一批") { model.clear() }.accessibilityIdentifier("task.newBatch")
                        } else if model.results.contains(where: \.ok) {
                            Button("查看已完成") { model.revealLastOutput() }
                        }
                        Menu {
                            if model.failedCount > 0 && model.primaryAction != .retry {
                                Button("重试失败项（\(model.failedCount)）") { model.retryFailed() }
                            }
                            if model.cancelledCount > 0 && model.primaryAction != .resume {
                                Button("继续未完成（\(model.unfinishedCount)）") { model.resumeUnfinished() }
                            }
                            Button("用当前设置重新转换全部（\(model.files.count)）") { model.convertAll() }
                                .disabled(model.selectedFormat == nil)
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().help("其他转换操作")
                            .accessibilityLabel("其他转换操作")
                    }
                    if !model.isConverting && selectedFileCount > 0 && selectedFileCount < model.files.count {
                        Button("转换所选 \(selectedFileCount) 个") { model.convertSelected(ids: selection.ids) }
                            .disabled(model.selectedFormat == nil)
                            .help("按当前设置开始新批次，仅处理所选文件；替换上次批次状态，磁盘文件保留")
                            .accessibilityIdentifier("task.selected")
                    }
                    Button(model.primaryActionTitle) { model.performPrimaryAction() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(BrandPrimaryButtonStyle()).disabled(!model.primaryActionEnabled)
                        .help(model.primaryActionNote ?? "⌘ Return 执行")
                        .accessibilityIdentifier("task.primary")
                } else {
                    Label("文件在本机处理", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14).background(Palette.surface)
    }

    // MARK: 动作

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK { model.add(urls: panel.urls) }
    }

    private func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
            model.useSourceFolder = false
        }
    }

    private func load(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.add(urls: urls)
        }
        return true
    }
}

/// 文件简介在后台读取；列表重试或任务完成后重新核验修改时间，避免显示旧的分辨率与体积。
struct FileSummaryLabel: View {
    let url: URL
    var revision = 0
    @State private var metadata: FileMetadataSnapshot?

    var body: some View {
        Text(metadata?.summary ?? "正在读取文件信息…")
            .font(.system(size: Palette.TypeSize.caption))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .help([metadata?.summary, metadata?.exactSizeText].compactMap { $0 }.joined(separator: "\n"))
            .task(id: revision) {
                let snapshot = await FileMetadataReader.read(url)
                guard !Task.isCancelled else { return }
                metadata = snapshot
            }
    }
}
