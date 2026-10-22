import SwiftUI
import UniformTypeIdentifiers
import QuickLook

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
    @AppStorage("totori.convertQuality") private var convertQuality = ""

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
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            ScrollView {
                Text(text).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: min(88, CGFloat(text.split(separator: "\n").count) * 16 + 4))
            Spacer(minLength: 0)
            Button("知道了") { model.importNotice = nil }.buttonStyle(.plain)
                .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Palette.warning.opacity(0.12))
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
                    .font(.system(size: Palette.TypeSize.body)).foregroundStyle(Palette.textSecondary)
                Text("同类文件可批量转换，原文件会保留")
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
            }
            Button("选择文件…") { pickFiles() }
                .buttonStyle(BrandPrimaryButtonStyle()).accessibilityIdentifier("import.choose")
            Text(dragShortcutHint)
                .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: Palette.Radius.panel)
                .fill(isTargeted ? Palette.brandSoft.opacity(0.75) : Palette.surface.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: Palette.Radius.panel)
                    .strokeBorder(isTargeted ? Palette.brand : Palette.line.opacity(0.8),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5])))
                .padding(24)
        )
    }

    private var importBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(Palette.brand).accessibilityHidden(true)
            Text("\(model.files.count) 个文件").font(.system(size: Palette.TypeSize.label, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(isTargeted ? "松手添加到列表" : "可继续拖入同类文件")
                .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
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
                            if let summary = model.results.first(where: { $0.source == file.url })?.outputSummary {
                                Text(summary.text).font(.system(size: Palette.TypeSize.caption)).monospacedDigit()
                                    .foregroundStyle(summary.isSmaller ? Palette.success : Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("file.outputSummary.\(file.id)")
                            }
                            if let result = model.results.first(where: { $0.source == file.url }), let error = result.error {
                                Text(error).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.danger)
                                    .lineLimit(2).help(error)
                            }
                        }
                        Spacer(minLength: 12)
                        if let state = model.jobStates[file.url] {
                            JobStateBadge(state: state, progress: model.fileProgress[file.url])
                        }
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
                                .buttonStyle(.plain)
                                .font(.system(size: Palette.TypeSize.caption, weight: .medium))
                                .foregroundStyle(Palette.brand)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Palette.brandSoft))
                                .contentShape(Capsule())
                                .accessibilityLabel("对比 \(file.name) 的转换结果")
                                .accessibilityIdentifier("file.compare.\(file.id)")
                        }
                        if !model.isConverting {
                            Button { model.remove(file) } label: { Image(systemName: "xmark").font(.system(size: Palette.TypeSize.caption)) }
                                .buttonStyle(.plain).foregroundStyle(Palette.textSecondary)
                                .padding(5).contentShape(Rectangle())
                                .help("从列表移除，保留原文件")
                                .accessibilityLabel("移除 \(file.name)")
                                .accessibilityIdentifier("file.remove.\(file.id)")
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 10)
                    .background(selection.ids.contains(file.id) ? Palette.brandSoft.opacity(0.65) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Palette.Radius.control))
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
                // 快捷键提示只在选中文件后出现；平时列表底部不常驻一整行说明
                if !selection.ids.isEmpty { Text("空格预览 · Delete 移除 · 原文件保留") }
            }
            .font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
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

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.supportsSpreadsheetPDFLayout {
                HStack(spacing: 12) {
                    Text("Excel 排版").font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textSecondary)
                        .frame(width: 60, alignment: .leading)
                    Picker("Excel 排版", selection: $model.spreadsheetPDFLayout) {
                        ForEach(SpreadsheetPDFLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }.labelsHidden().frame(width: 160)
                        .accessibilityIdentifier("task.spreadsheet-pdf-layout")
                    Text("适配页宽：A4 横向，1 页宽，高度自动")
                        .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text("输出格式").font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 60, alignment: .leading).padding(.top, 5)
                VStack(alignment: .leading, spacing: 8) {
                    formatSelector
                    HStack(spacing: 12) {
                        if let format = model.selectedFormat {
                            Text(format.ext == "jpg" ? "有损，适合照片" : format.hint)
                                .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                                .lineLimit(1).layoutPriority(-1).help(format.hint)
                        }
                        Spacer()
                        if model.selectedFormat?.supportsTaskQuality == true {
                            Text("本次质量").font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                            Picker("本次质量", selection: $model.taskQuality) {
                                ForEach(TaskConversionQuality.allCases) { quality in
                                    Text(quality == .defaults ? "默认（\(defaultQualityTitle)）" : quality.title).tag(quality)
                                }
                            }.labelsHidden().frame(width: 138)
                                .accessibilityIdentifier("task.quality")
                                .help("仅用于按当前设置开始的新批次；重试沿用原批次参数。不会更改设置中的默认质量，也不会缩小图片尺寸。")
                        }
                        if model.currentKind == .image {
                            Toggle("移除元数据", isOn: $model.stripMetadata).font(.system(size: Palette.TypeSize.caption))
                                .toggleStyle(BrandCheckboxStyle()).help("仅影响输出图片，保留原文件")
                        }
                    }
                }
            }
            if let format = model.selectedFormat {
                let impact = ConversionImpact.text(format: format, sources: impactSources)
                let generic = format.ext == "jpg" ? "有损，适合照片" : format.hint
                if impact != generic {
                    Label(impact, systemImage: "info.circle")
                        .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("conversion.impact")
                }
            }
            HStack(spacing: 12) {
                Text("保存到").font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Menu {
                    Button("原文件所在文件夹") { model.useSourceFolder = true }
                    Button("选择文件夹…") { pickOutputDirectory() }
                } label: {
                    Label(saveLocation, systemImage: "folder").font(.system(size: Palette.TypeSize.label))
                        .lineLimit(1).truncationMode(.middle)
                }.help(saveLocation).accessibilityIdentifier("output.location")
                    .frame(maxWidth: 430, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(Palette.canvas)
    }

    /// 格式不多（≤ 10 个，窄窗口会折成两行）时直接排成胶囊，一眼看全；格式再多才退回下拉框。
    @ViewBuilder
    private var formatSelector: some View {
        if model.availableFormats.count <= 10 {
            FormatChips(formats: model.availableFormats, selection: $model.selectedFormat)
                .focusable().focused($focusedControl, equals: .outputFormat)
        } else {
            Picker("输出格式", selection: $model.selectedFormat) {
                ForEach(model.availableFormats) { format in Text(format.name).tag(Optional(format)) }
            }.labelsHidden().frame(width: 140).disabled(model.availableFormats.isEmpty)
                .focusable().focused($focusedControl, equals: .outputFormat)
        }
    }

    /// 转换前底部左侧给出本批的去向，不再重复顶部已有的“N 个文件”。
    private var footerSummary: String {
        guard !model.isConverting, model.results.isEmpty, !model.files.isEmpty,
              let format = model.selectedFormat else { return model.taskSummary }
        let place = model.useSourceFolder ? "原文件所在文件夹" : model.outputDirectory.lastPathComponent
        return "将转换为 \(format.name) · 保存到 \(place)"
    }

    /// 每个阶段只强调一个动作，取消与重新转换不会冒充默认的下一步。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isConverting {
                ProgressView(value: model.progress).progressViewStyle(BrandProgressStyle())
            }
            if let note = actionNote {
                Label(note, systemImage: model.primaryAction == .newBatch ? "info.circle" : "arrow.clockwise")
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(footerSummary).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
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
                        .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
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
