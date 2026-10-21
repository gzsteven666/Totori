import AppKit
import SwiftUI
import ImageIO
import Quartz

/// 转换结果入口。每次打开替换上一次请求，关闭窗口后不再接收迟到结果。
@MainActor
final class ComparisonWindow: NSObject, NSWindowDelegate {
    static let shared = ComparisonWindow()
    private var window: NSWindow?
    private var model: ComparisonModel?
    private var previewWindows: [NSWindow] = []
    private var resignObserver: NSObjectProtocol?

    func present(source: URL, output: URL) {
        present(ComparisonModel(source: source, output: output))
    }

    /// 仅图片结果组成连续对比；点开非图片结果时保留原有快速查看入口。
    func present(pairs: [OutputComparison], selectedOutput: URL? = nil) {
        let selected = selectedOutput.flatMap { selected in pairs.first { $0.output == selected } }
        if let selected, !ComparisonBatch.isImagePair(selected) {
            present(source: selected.source, output: selected.output)
            return
        }
        let images = ComparisonBatch.imagePairs(pairs)
        guard !images.isEmpty else {
            if let pair = selected ?? pairs.first { present(source: pair.source, output: pair.output) }
            return
        }
        present(ComparisonModel(pairs: images, selectedOutput: selectedOutput))
    }

    private func present(_ model: ComparisonModel) {
        self.model?.cancel(clearBatch: true)
        self.model = model
        let window = self.window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: ComparisonView(model: model) { [weak self] url in
            self?.quickLook(url)
        })
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.load()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Totori · 转换前后对比"
        window.identifier = NSUserInterfaceItemIdentifier("totori.comparison")
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.releaseHold() }
        }
        window.center()
        return window
    }

    private func quickLook(_ url: URL) {
        guard let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 560), style: .normal) else {
            NSWorkspace.shared.open(url)
            return
        }
        preview.autostarts = false
        preview.shouldCloseWithWindow = true
        preview.previewItem = url as NSURL
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "快速查看 · \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = preview
        previewWindows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            model?.releaseHold()
            model?.cancel(clearBatch: true)
            model = nil
            window?.contentView = nil
            let previews = previewWindows
            previews.forEach { $0.close() }
            previewWindows.removeAll()
        } else {
            previewWindows.removeAll { $0 === closing }
        }
    }

    /// 对比窗口会保留并重用，失焦监听随控制器释放，避免第二次打开失去恢复能力。
    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

@MainActor
final class ComparisonModel: ObservableObject {
    @Published private(set) var pairs: [OutputComparison]
    @Published private(set) var selectedIndex: Int
    var source: URL { pairs.indices.contains(selectedIndex) ? pairs[selectedIndex].source : URL(fileURLWithPath: "/") }
    var output: URL { pairs.indices.contains(selectedIndex) ? pairs[selectedIndex].output : URL(fileURLWithPath: "/") }
    var batchCount: Int { pairs.count }
    var canMovePrevious: Bool { selectedIndex > 0 && !pairs.isEmpty }
    var canMoveNext: Bool { selectedIndex + 1 < pairs.count }
    var positionText: String { "第 \(selectedIndex + 1) / \(pairs.count) 张" }
    var hasImageBatch: Bool { !pairs.isEmpty && pairs.allSatisfy(ComparisonBatch.isImagePair) }
    @Published var sourceMetadata: FileMetadataSnapshot?
    @Published var outputMetadata: FileMetadataSnapshot?
    @Published var sourceBitmap: CGImage?
    @Published var outputBitmap: CGImage?
    @Published var loading = true
    @Published var fit = true
    @Published var zoom = 1.0
    @Published var anchor = CGPoint(x: 0.5, y: 0.5)

    enum ComparisonMode: String, CaseIterable, Identifiable {
        case sideBySide, divider
        var id: String { rawValue }
        var title: String { self == .sideBySide ? "并排" : "分界" }
    }

    @Published private(set) var mode: ComparisonMode = .sideBySide
    private(set) var preferredMode: ComparisonMode = .sideBySide
    @Published var divider: Double = 0.5
    @Published var holdOriginal = false      // 按住查看
    @Published var lockOriginal = false      // 可访问替代：锁定查看
    @Published var dividerUnavailable = false

    var showingOriginalOnly: Bool { holdOriginal || lockOriginal }

    /// 像素尺寸一致才允许分界，否则无法逐像素对齐
    var canUseDivider: Bool {
        guard let a = sourceMetadata, let b = outputMetadata,
              let aw = a.pixelWidth, let ah = a.pixelHeight,
              let bw = b.pixelWidth, let bh = b.pixelHeight else { return false }
        return aw == bw && ah == bh && sourceBitmap != nil && outputBitmap != nil
    }

    func setDivider(_ value: Double) {
        divider = min(max(value, 0), 1)
    }

    func setMode(_ new: ComparisonMode) {
        preferredMode = new
        applyPreferredMode()
    }

    private func applyPreferredMode() {
        dividerUnavailable = preferredMode == .divider && !canUseDivider && !loading
        mode = preferredMode == .divider && canUseDivider ? .divider : .sideBySide
    }

    func previous() { select(index: selectedIndex - 1) }
    func next() { select(index: selectedIndex + 1) }

    func select(index: Int) {
        guard pairs.indices.contains(index), index != selectedIndex else { return }
        releaseHold()
        selectedIndex = index
        load()
    }

    func releaseHold() {
        holdOriginal = false
    }

    var debugRequestToken: UUID { request }
    func debugSetImages(source: CGImage?, output: CGImage?,
                        sourceSize: (Int, Int)?, outputSize: (Int, Int)?) {
        sourceBitmap = source
        outputBitmap = output
        func snapshot(_ url: URL, _ size: (Int, Int)?) -> FileMetadataSnapshot? {
            guard let size else { return nil }
            return FileMetadataSnapshot(url: url, formatName: "PNG", byteCount: 120,
                                        pixelWidth: size.0, pixelHeight: size.1,
                                        duration: nil, pageCount: nil, frameCount: nil,
                                        isImage: true)
        }
        sourceMetadata = snapshot(self.source, sourceSize)
        outputMetadata = snapshot(self.output, outputSize)
        loading = false
        applyPreferredMode()
    }
    private var task: Task<Void, Never>?
    private var request = UUID()
    private let previewLoader: @Sendable (URL, URL) async -> ComparisonPairPreview

    convenience init(source: URL, output: URL) {
        self.init(pairs: [OutputComparison(source: source, output: output)], selectedOutput: output)
    }

    init(pairs: [OutputComparison], selectedOutput: URL? = nil,
         previewLoader: @escaping @Sendable (URL, URL) async -> ComparisonPairPreview = { source, output in
             await ComparisonPairPreview.read(source, output)
         }) {
        precondition(!pairs.isEmpty, "对比需要至少一组文件")
        self.pairs = pairs
        selectedIndex = selectedOutput.flatMap { selected in pairs.firstIndex { $0.output == selected } } ?? 0
        self.previewLoader = previewLoader
    }

    var hasImagePair: Bool {
        sourceMetadata?.isImage == true && outputMetadata?.isImage == true &&
            sourceBitmap != nil && outputBitmap != nil
    }

    var previewIsReduced: Bool {
        [sourceMetadata, outputMetadata].compactMap { $0 }.contains {
            max($0.pixelWidth ?? 0, $0.pixelHeight ?? 0) > ComparisonPairPreview.maximumSide
        }
    }

    /// 体积减少使用强调色，增大/相同使用中性色（格式转换的体积变化本身不代表质量好坏）
    var volumeDecreased: Bool {
        guard let before = sourceMetadata?.byteCount,
              let after = outputMetadata?.byteCount else { return false }
        return after < before
    }

    var changeText: String? {
        var parts: [String] = []
        if let before = sourceMetadata?.byteCount, let after = outputMetadata?.byteCount {
            let summary = ConversionOutputSummary(sourceExtension: source.pathExtension,
                                                  outputExtension: output.pathExtension,
                                                  sourceBytes: before, outputBytes: after)
            parts.append(summary.deltaText)
        }
        if let before = sourceMetadata?.resolutionText, let after = outputMetadata?.resolutionText {
            parts.append(before == after ? "像素尺寸相同" : "\(before) → \(after) 像素")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func load() {
        task?.cancel()
        let token = UUID()
        request = token
        releaseHold()
        sourceMetadata = nil
        outputMetadata = nil
        sourceBitmap = nil
        outputBitmap = nil
        dividerUnavailable = false
        loading = !pairs.isEmpty
        applyPreferredMode()
        guard !pairs.isEmpty else { task = nil; return }
        let source = self.source, output = self.output
        let loader = previewLoader
        task = Task { [weak self] in
            let preview = await loader(source, output)
            guard !Task.isCancelled, let self, self.request == token else { return }
            self.sourceMetadata = preview.sourceMetadata
            self.outputMetadata = preview.outputMetadata
            self.sourceBitmap = preview.sourceImage
            self.outputBitmap = preview.outputImage
            self.loading = false
            self.applyPreferredMode()
            self.task = nil
        }
    }

    func cancel(clearBatch: Bool = false) {
        request = UUID()
        task?.cancel()
        task = nil
        releaseHold()
        sourceBitmap = nil
        outputBitmap = nil
        sourceMetadata = nil
        outputMetadata = nil
        loading = false
        if clearBatch {
            pairs.removeAll()
            selectedIndex = 0
        }
    }

}

private struct ComparisonView: View {
    @ObservedObject var model: ComparisonModel
    var quickLook: (URL) -> Void
    @AppStorage("xiaoju.theme") private var themeRaw = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoBar
            if model.hasImageBatch { batchNavigation }
            controls
            if model.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取文件简介与预览…").foregroundStyle(Palette.textSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hasImagePair {
                imageArea
                if model.previewIsReduced {
                    Text("超大图片使用最长边 4096 像素的预览；100% 按原始像素定位。")
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                }
            } else {
                fallback
            }
        }
        .padding(16)
        .foregroundStyle(Palette.textPrimary)
        .tint(theme.tint)
        .background(Palette.canvas)
        .onDisappear { model.releaseHold() }
        .onExitCommand { model.releaseHold() }
    }

    // MARK: 顶部信息栏

    private var infoBar: some View {
        HStack(spacing: 12) {
            compactFile(model.source, metadata: model.sourceMetadata, tag: "原文件")
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            compactFile(model.output, metadata: model.outputMetadata, tag: "结果")
            Spacer(minLength: 8)
            if let change = model.changeText {
                Text(change).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.volumeDecreased ? Palette.brand : Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(change)
            }
            Menu {
                Button("快速查看原文件") { quickLook(model.source) }
                Button("快速查看结果") { quickLook(model.output) }
                Divider()
                Button("打开原文件") { NSWorkspace.shared.open(model.source) }
                Button("打开结果") { NSWorkspace.shared.open(model.output) }
                Divider()
                Button("在访达显示原文件") { NSWorkspace.shared.activateFileViewerSelecting([model.source]) }
                Button("在访达显示结果") { NSWorkspace.shared.activateFileViewerSelecting([model.output]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityIdentifier("comparison.actions")
            .accessibilityLabel("文件操作")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassSurface(cornerRadius: Palette.Radius.card, tintOpacity: 0.05, strokeOpacity: 0.45)
    }

    private func compactFile(_ url: URL, metadata: FileMetadataSnapshot?, tag: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(tag).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textSecondary)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.path)
            }
            Text(detailLine(metadata))
                .font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .help([metadata?.summary, metadata?.exactSizeText].compactMap { $0 }.joined(separator: "\n"))
        }
        .frame(minWidth: 168, maxWidth: 250, alignment: .leading)
    }

    private func detailLine(_ metadata: FileMetadataSnapshot?) -> String {
        guard let metadata else { return "读取中…" }
        let parts = [metadata.formatName, metadata.resolutionText, metadata.durationText,
                     metadata.pageCount.map { "\($0) 页" }, metadata.sizeText]
            .compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    // MARK: 控件

    private var batchNavigation: some View {
        HStack(spacing: 10) {
            Button { model.previous() } label: { Label("上一张", systemImage: "chevron.left") }
                .disabled(!model.canMovePrevious)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .accessibilityIdentifier("comparison.previous")
                .help("上一张（⌥⌘←）；保留缩放、位置与对比方式")
            Text(model.positionText)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .accessibilityIdentifier("comparison.position")
            Button { model.next() } label: { Label("下一张", systemImage: "chevron.right") }
                .disabled(!model.canMoveNext)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .accessibilityIdentifier("comparison.next")
                .help("下一张（⌥⌘→）；保留缩放、位置与对比方式")
            Spacer()
        }
        .controlSize(.small)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("适应") { model.fit = true; model.anchor = CGPoint(x: 0.5, y: 0.5) }
                    .accessibilityIdentifier("comparison.fit").help("缩放到适合窗口")
                Button("100%") { model.fit = false; model.zoom = 1 }
                    .accessibilityIdentifier("comparison.actualSize").help("按 1:1 像素显示")
                Slider(value: Binding(get: { model.zoom }, set: { model.fit = false; model.zoom = $0 }), in: 0.05...4)
                    .frame(width: 110).accessibilityLabel("共同缩放")
                Text(model.fit ? "适应窗口" : "\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().frame(width: 58, alignment: .leading)

                Spacer(minLength: 6)

                holdButton
                Toggle(isOn: $model.lockOriginal) {
                    Text("锁定原图").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("comparison.lockOriginal")
                .help("锁定后持续显示原图，切换图片时保留；再点一次恢复对比")
            }
            .disabled(!model.hasImagePair)

            HStack(spacing: 8) {
                modeButton(.sideBySide, enabled: model.hasImagePair)
                modeButton(.divider, enabled: model.canUseDivider)

                if model.mode == .divider && model.canUseDivider {
                    Slider(value: Binding(get: { model.divider }, set: { model.setDivider($0) }), in: 0...1)
                        .frame(width: 100)
                        .accessibilityIdentifier("comparison.divider")
                        .accessibilityLabel("分界线位置")
                        .help("左右移动分界线（可用方向键微调）")
                    Text("\(Int((model.divider * 100).rounded()))%")
                        .font(.system(size: 10)).monospacedDigit().frame(width: 32)
                }

                Text(dividerAvailabilityText)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
    }

    private var dividerAvailabilityText: String {
        if model.loading { return "正在读取文件预览…" }
        if model.sourceMetadata?.isReadable == false || model.outputMetadata?.isReadable == false {
            return "文件已移动或无法读取，分界与缩放不可用"
        }
        guard model.hasImagePair else { return "无法生成图片对比；可使用快速查看" }
        if !model.canUseDivider { return "两张图像素尺寸不同，分界不可用；可继续并排查看" }
        return "分界要求两张图像素尺寸相同"
    }

    private func modeButton(_ mode: ComparisonModel.ComparisonMode, enabled: Bool) -> some View {
        Button {
            model.setMode(mode)
        } label: {
            Text(mode.title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Palette.brand.opacity(model.mode == mode ? 0.85 : 0.12)))
                .foregroundStyle(model.mode == mode ? Palette.onAccent : Palette.brand)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("comparison.mode.\(mode.rawValue)")
        .accessibilityLabel(mode == .divider ? "分界对比" : "并排对比")
        .help(mode == .divider
              ? (enabled ? "分界线逐像素对比" : "两张图像素尺寸不同，无法逐像素对齐")
              : "左右并排查看")
    }

    private var holdButton: some View {
        Button { } label: {
            Text("按住看原图").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HoldOriginalButtonStyle(active: model.showingOriginalOnly) { pressed in
            model.holdOriginal = pressed
        })
        .accessibilityIdentifier("comparison.holdOriginal")
        .accessibilityLabel("按住查看原图")
        .accessibilityHint("按住期间只显示原图，松开或取消恢复")
        .help("按住期间只显示原图，松开立即恢复（Esc 也可恢复）")
    }

    private var statusText: String {
        if model.showingOriginalOnly {
            return model.lockOriginal ? "当前：只显示原图（已锁定）" : "当前：只显示原图（松开恢复）"
        }
        if model.dividerUnavailable {
            return "原图与结果像素尺寸不同，无法逐像素对齐；已保持并排查看。"
        }
        return model.mode == .divider ? "当前：分界对比" : "当前：并排对比"
    }

    // MARK: 内容

    private var imageArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(statusText).font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("comparison.status")
                Spacer()
                if (model.sourceMetadata?.frameCount ?? 1) > 1 || (model.outputMetadata?.frameCount ?? 1) > 1 {
                    Text("动图预览显示第一帧；播放请使用“快速查看”。")
                        .font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
                }
            }
            GeometryReader { geometry in
                let viewport = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                let maximumWidth = CGFloat(max(model.sourceMetadata?.pixelWidth ?? 1, model.outputMetadata?.pixelWidth ?? 1))
                let maximumHeight = CGFloat(max(model.sourceMetadata?.pixelHeight ?? 1, model.outputMetadata?.pixelHeight ?? 1))
                let single = model.showingOriginalOnly || (model.mode == .divider && model.canUseDivider)
                let paneWidth = max(1, (single ? viewport.width : (viewport.width - 12) / 2) - 26)
                let fitScale = min(paneWidth / maximumWidth, max(1, viewport.height - 26) / maximumHeight, 1 / backing)
                let scale = model.fit ? fitScale : CGFloat(model.zoom) / backing

                if model.showingOriginalOnly || (model.mode == .divider && model.canUseDivider) {
                    ComparisonImageScroll(image: model.sourceBitmap,
                                          secondImage: model.showingOriginalOnly ? nil : model.outputBitmap,
                                          originalSize: imagePointSize(model.sourceMetadata),
                                          scale: scale,
                                          divider: CGFloat(model.divider),
                                          originalOnly: model.showingOriginalOnly,
                                          onDividerChange: model.showingOriginalOnly
                                              ? nil
                                              : { model.setDivider(Double($0)) },
                                          anchor: $model.anchor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 0.8))
                } else {
                    HStack(spacing: 12) {
                        imagePane(model.sourceBitmap, metadata: model.sourceMetadata, scale: scale)
                        imagePane(model.outputBitmap, metadata: model.outputMetadata, scale: scale)
                    }
                }
            }
        }
    }

    private func imagePointSize(_ metadata: FileMetadataSnapshot?) -> CGSize {
        CGSize(width: max(1, metadata?.pixelWidth ?? 1), height: max(1, metadata?.pixelHeight ?? 1))
    }

    private var fallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .light))
            Text("可通过快速查看检查内容，或打开文件使用对应应用查看。")
                .font(.system(size: 13)).multilineTextAlignment(.center)
            if model.sourceMetadata?.isReadable == false || model.outputMetadata?.isReadable == false {
                Text("原文件或结果已移动、删除或无法读取。可在上方菜单尝试定位文件。")
                    .font(.system(size: 11))
            } else if model.sourceMetadata?.isImage == true && model.outputMetadata?.isImage == true {
                Text("这组图片无法生成并排预览。原文件与转换结果仍可通过上方菜单打开。")
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func imagePane(_ image: CGImage?, metadata: FileMetadataSnapshot?, scale: CGFloat) -> some View {
        ComparisonImageScroll(image: image,
                              originalSize: CGSize(width: metadata?.pixelWidth ?? 1,
                                                   height: metadata?.pixelHeight ?? 1),
                              scale: scale, anchor: $model.anchor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 0.8))
    }
}

/// NSScrollView 保留触控板的横向/纵向滚动；归一化中心让两个不同尺寸的结果也能对齐检查。
enum ComparisonAnchor {
    /// 只有某个轴真的能滚动时，才从滚动位置回写该轴；否则保持原值。
    /// 重建视图/首帧布局时 viewport 与 imageRect 尚未成形，不能当作"滚到边上了"。
    static func afterScroll(viewport: CGRect, imageRect: CGRect, drawnSize: CGSize,
                            canvasSize: CGSize, current: CGPoint) -> CGPoint {
        guard imageRect.width > 1, imageRect.height > 1,
              drawnSize.width > 1, drawnSize.height > 1,
              canvasSize.width > 1, canvasSize.height > 1 else { return current }

        var x = current.x
        var y = current.y
        if canvasSize.width > viewport.width + 0.5 {
            x = (viewport.midX - imageRect.minX) / drawnSize.width
        }
        if canvasSize.height > viewport.height + 0.5 {
            y = (viewport.midY - imageRect.minY) / drawnSize.height
        }
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

enum ComparisonGeometry {
    /// 由画布坐标换算分界比例（含 imageRect 原点/居中/滚动偏移）
    static func fraction(atX x: CGFloat, imageRect: CGRect) -> CGFloat {
        guard imageRect.width > 0 else { return 0.5 }
        return min(1, max(0, (x - imageRect.minX) / imageRect.width))
    }

    static func cutX(fraction: CGFloat, imageRect: CGRect) -> CGFloat {
        imageRect.minX + imageRect.width * min(1, max(0, fraction))
    }

    /// 左（原图）/ 右（结果）裁切矩形
    static func clipRects(fraction: CGFloat, imageRect: CGRect) -> (left: CGRect, right: CGRect) {
        let cut = cutX(fraction: fraction, imageRect: imageRect)
        let left = CGRect(x: imageRect.minX, y: imageRect.minY,
                          width: max(0, cut - imageRect.minX), height: imageRect.height)
        let right = CGRect(x: cut, y: imageRect.minY,
                           width: max(0, imageRect.maxX - cut), height: imageRect.height)
        return (left, right)
    }
}

struct ComparisonImageScroll: NSViewRepresentable {
    var image: CGImage?
    var secondImage: CGImage?
    var originalSize: CGSize
    var scale: CGFloat
    var divider: CGFloat = 0.5
    var originalOnly: Bool = false
    var onDividerChange: ((CGFloat) -> Void)?
    @Binding var anchor: CGPoint

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComparisonScrollContainer()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        let canvas = ComparisonCanvas()
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        canvas.setAccessibilityLabel("图片预览")
        canvas.onDividerFraction = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.onDividerChange?(value)
        }
        scroll.documentView = canvas
        context.coordinator.observe(scroll)
        scroll.layoutChanged = { [weak coordinator = context.coordinator, weak scroll] in
            guard let scroll else { return }
            coordinator?.layout(scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.layout(scroll)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        var parent: ComparisonImageScroll
        var updating = false
        private var lastAppliedOrigin: CGPoint?
        private var laidOutSize: CGSize = .zero
        private var observer: NSObjectProtocol?
        init(_ parent: ComparisonImageScroll) { self.parent = parent }
        func layout(_ scroll: NSScrollView) {
            guard let canvas = scroll.documentView as? ComparisonCanvas, !updating else { return }
            updating = true
            defer { updating = false }
            let viewport = scroll.contentSize
            let drawnSize = CGSize(width: max(1, parent.originalSize.width * parent.scale),
                                   height: max(1, parent.originalSize.height * parent.scale))
            canvas.image = parent.image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            canvas.secondImage = parent.secondImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            canvas.divider = parent.divider
            canvas.originalOnly = parent.originalOnly
            canvas.drawnSize = drawnSize
            canvas.setFrameSize(NSSize(width: max(viewport.width, drawnSize.width),
                                      height: max(viewport.height, drawnSize.height)))
            canvas.needsDisplay = true
            scroll.window?.invalidateCursorRects(for: canvas)
            let centered = CGPoint(x: canvas.imageRect.minX + parent.anchor.x * drawnSize.width - viewport.width / 2,
                                   y: canvas.imageRect.minY + parent.anchor.y * drawnSize.height - viewport.height / 2)
            let origin = CGPoint(x: min(max(0, centered.x), max(0, canvas.frame.width - viewport.width)),
                                 y: min(max(0, centered.y), max(0, canvas.frame.height - viewport.height)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            // 记下我们主动设置的滚动位置；它的异步回显不算用户滚动
            lastAppliedOrigin = scroll.contentView.bounds.origin
            laidOutSize = canvas.frame.size
        }
        func observe(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                              object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll, !self.updating,
                      (scroll as? ComparisonScrollContainer)?.isLayingOut != true,
                      let canvas = scroll.documentView as? ComparisonCanvas,
                      canvas.drawnSize.width > 1, canvas.drawnSize.height > 1,
                      canvas.frame.size == self.laidOutSize else { return }
                let currentOrigin = scroll.contentView.bounds.origin
                if let applied = self.lastAppliedOrigin,
                   abs(currentOrigin.x - applied.x) < 0.5,
                   abs(currentOrigin.y - applied.y) < 0.5 {
                    return   // 程序化滚动的回显
                }
                let point = ComparisonAnchor.afterScroll(
                    viewport: scroll.contentView.bounds,
                    imageRect: canvas.imageRect,
                    drawnSize: canvas.drawnSize,
                    canvasSize: canvas.frame.size,
                    current: self.parent.anchor)
                self.lastAppliedOrigin = currentOrigin
                if abs(point.x - self.parent.anchor.x) + abs(point.y - self.parent.anchor.y) > 0.0001 {
                    self.parent.anchor = point
                }
            }
        }
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { stop() }
    }
}

private final class ComparisonScrollContainer: NSScrollView {
    var layoutChanged: (() -> Void)?
    private var previousViewport = CGSize.zero
    private(set) var isLayingOut = false

    override func layout() {
        isLayingOut = true
        super.layout()
        isLayingOut = false
        if contentSize != previousViewport {
            previousViewport = contentSize
            layoutChanged?()
        }
    }
}

final class ComparisonCanvas: NSView {
    var image: NSImage?
    var secondImage: NSImage?
    var drawnSize = CGSize(width: 1, height: 1)
    var divider: CGFloat = 0.5
    var originalOnly = false
    var onDividerFraction: ((CGFloat) -> Void)?
    private var draggingDivider = false
    override var isFlipped: Bool { true }
    var imageRect: CGRect {
        CGRect(x: (bounds.width - drawnSize.width) / 2, y: (bounds.height - drawnSize.height) / 2,
               width: drawnSize.width, height: drawnSize.height)
    }
    func drawContent(in dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let rect = imageRect.intersection(dirtyRect)
        if !rect.isEmpty { drawCheckerboard(rect) }

        func draw(_ image: NSImage?) {
            image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }

        // 单看原图，或没有可对比的第二张
        guard !originalOnly, let secondImage else {
            draw(image)
            return
        }

        // 左右各自裁切：结果透明处露出棋盘，而不是底下的原图
        let rects = ComparisonGeometry.clipRects(fraction: divider, imageRect: imageRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rects.left).addClip()
        draw(image)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rects.right).addClip()
        draw(secondImage)
        NSGraphicsContext.restoreGraphicsState()

        let cut = ComparisonGeometry.cutX(fraction: divider, imageRect: imageRect)
        NSColor(Palette.brand).setFill()
        NSRect(x: cut - 0.75, y: imageRect.minY, width: 1.5, height: imageRect.height).fill()
        NSBezierPath(ovalIn: CGRect(x: cut - 7, y: imageRect.midY - 7, width: 14, height: 14)).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawContent(in: dirtyRect)
    }

    private func drawCheckerboard(_ rect: CGRect) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        let step: CGFloat = 12
        let xStart = Int(floor(rect.minX / step)), xEnd = Int(ceil(rect.maxX / step))
        let yStart = Int(floor(rect.minY / step)), yEnd = Int(ceil(rect.maxY / step))
        for y in yStart..<yEnd {
            for x in xStart..<xEnd where (x + y) % 2 == 0 {
                CGRect(x: CGFloat(x) * step, y: CGFloat(y) * step, width: step, height: step)
                    .intersection(rect).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cut = ComparisonGeometry.cutX(fraction: divider, imageRect: imageRect)
        draggingDivider = abs(point.x - cut) <= 14 && imageRect.insetBy(dx: -2, dy: -2).contains(point)
        if draggingDivider { onDividerFraction?(ComparisonGeometry.fraction(atX: point.x, imageRect: imageRect)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingDivider else { return }
        let point = convert(event.locationInWindow, from: nil)
        onDividerFraction?(ComparisonGeometry.fraction(atX: point.x, imageRect: imageRect))
    }

    override func mouseUp(with event: NSEvent) {
        draggingDivider = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !originalOnly, secondImage != nil else { return }
        let cut = ComparisonGeometry.cutX(fraction: divider, imageRect: imageRect)
        addCursorRect(CGRect(x: cut - 10, y: imageRect.minY, width: 20, height: imageRect.height),
                      cursor: .resizeLeftRight)
    }
}

private struct HoldOriginalButtonStyle: ButtonStyle {
    var active: Bool
    var onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Palette.brand.opacity(active ? 0.88 : 0.14)))
            .foregroundStyle(active ? Palette.onAccent : Palette.brand)
            .contentShape(Capsule())
            .onChange(of: configuration.isPressed) { pressed in
                onPressChanged(pressed)
            }
    }
}
