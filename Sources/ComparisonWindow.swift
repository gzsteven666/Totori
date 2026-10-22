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
        }.followsTheme())
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
