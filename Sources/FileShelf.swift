import AppKit
import Quartz

/// 文件浮窗：缩略图网格 + 按类型分组 + 橡皮筋多选 + 整组拖出 + 空格快览。
/// 对应原版 FloatingFilePanel / FloatingFileDragSourceView /
/// FloatingRubberBandSelectionView / FloatingQuickLookController / FloatingFileGroupModel。
@MainActor
final class FileShelf {
    static let shared = FileShelf()

    enum SnapEdge { case left, right, top, bottom }

    private var panel: NSPanel?
    private var canvas: ShelfCanvas?
    private var container: ShelfContainer?
    private(set) var isVisible = false

    private(set) var isCollapsed = false
    /// 钉住后不再因鼠标移开或贴边而自动收起
    private(set) var isPinned = false
    private var snappedEdge: SnapEdge?
    private var moveWork: DispatchWorkItem?
    private var suppressSnapUntil = Date.distantPast
    private var collapseWork: DispatchWorkItem?

    static let regularHeight: CGFloat = 440
    static let compactHeight: CGFloat = 260
    private(set) var isCompact = UserDefaults.standard.bool(forKey: "totori.shelfCompact")
    private var expandedSize: NSSize {
        NSSize(width: 328, height: isCompact ? Self.compactHeight : Self.regularHeight)
    }
    private let tabThickness: CGFloat = 12
    private let snapTolerance: CGFloat = 28

    var files: [URL] { canvas?.files ?? [] }

    private init() {
        isPinned = UserDefaults.standard.bool(forKey: "totori.shelfPinned")
    }

    /// 从偏好重读（启动时与自检都用它）
    func reloadPinFromDefaults() {
        isPinned = UserDefaults.standard.bool(forKey: "totori.shelfPinned")
        canvas?.isPinned = isPinned
    }
    var debugCanvas: ShelfCanvas? { canvas }

    func toggle() { isVisible ? hide() : show(activate: true) }

    func show(activate: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if isCollapsed { expand() }
        if panel.frame.size != expandedSize {
            var frame = panel.frame
            frame.size = expandedSize
            frame.origin.y = panel.frame.maxY - expandedSize.height
            panel.setFrame(frame, display: true)
        }
        canvas?.isCompact = isCompact
        panel.setFrameOrigin(restoredOrigin(for: panel))
        canvas?.refreshMetadata()   // 打开时刷新一遍，文件可能已被外部修改
        collapseWork?.cancel()
        panel.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        isVisible = true
        // 刚打开时不要因为默认位置就吸附
        suppressSnapUntil = Date().addingTimeInterval(0.6)
    }

    // MARK: 位置记忆

    private static let originKey = "totori.shelfOrigin"

    /// 读取上次展开位置：优先留在仍能看到它的那块屏，只有那块屏没了才夹回
    func restoredOrigin(for panel: NSPanel) -> NSPoint {
        let size = panel.frame.size
        let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double]
        let primary = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        guard let saved, saved.count == 2, saved[0].isFinite, saved[1].isFinite else {
            return clamped(NSPoint(x: primary.minX + 64, y: primary.midY - size.height / 2),
                           size: size, in: primary)
        }

        let origin = NSPoint(x: saved[0], y: saved[1])
        let savedRect = NSRect(origin: origin, size: size)
        let best = NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.visibleFrame, savedRect) < intersectionArea(rhs.visibleFrame, savedRect)
        }
        guard let best, intersectionArea(best.visibleFrame, savedRect) > 0 else {
            return clamped(origin, size: size, in: primary)
        }
        return best.visibleFrame.contains(savedRect) ? origin : clamped(origin, size: size, in: best.visibleFrame)
    }

    private func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private func clamped(_ origin: NSPoint, size: NSSize, in area: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, area.minX + 8), max(area.minX + 8, area.maxX - size.width - 8)),
                y: min(max(origin.y, area.minY + 8), max(area.minY + 8, area.maxY - size.height - 8)))
    }

    /// 只在展开状态记忆位置；收起边条不覆盖
    func rememberOrigin() {
        guard let panel, !isCollapsed else { return }
        UserDefaults.standard.set([Double(panel.frame.origin.x), Double(panel.frame.origin.y)],
                                  forKey: Self.originKey)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func chooseFiles() {
        // 浮窗是 nonactivatingPanel；显式激活后再开选择器，确保路径快捷键送到对话框。
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        if picker.runModal() == .OK { add(picker.urls) }
        // 添加或取消都回到发起操作的浮窗，避免下一次快捷键落到主窗口。
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            if let canvas { panel?.makeFirstResponder(canvas) }
        }
    }

    // MARK: 钉住

    func togglePin() {
        isPinned.toggle()
        canvas?.isPinned = isPinned
        UserDefaults.standard.set(isPinned, forKey: "totori.shelfPinned")
        DiagLog.write("shelf pin=\(isPinned)")
    }

    // MARK: 贴边

    /// 拖动结束后判断是否靠近屏幕边缘
    private func scheduleSnapCheck() {
        moveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkSnap() }
        moveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func checkSnap() {
        guard !isPinned else { return }          // 钉住就不吸附
        guard Date() > suppressSnapUntil else { return }
        guard let panel, let screen = NSScreen.main, !isCollapsed else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        if frame.minX - visible.minX <= snapTolerance {
            collapse(to: .left)
        } else if visible.maxX - frame.maxX <= snapTolerance {
            collapse(to: .right)
        } else if visible.maxY - frame.maxY <= snapTolerance {
            collapse(to: .top)
        } else if frame.minY - visible.minY <= snapTolerance {
            collapse(to: .bottom)
        } else {
            snappedEdge = nil
        }
    }

    func collapse(to edge: SnapEdge) {
        guard let panel, !isCollapsed else { return }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let old = panel.frame
        let collapsed: NSRect

        switch edge {
        case .left:
            collapsed = NSRect(x: visible.minX, y: clamp(old.midY - 70, visible.minY + 40, visible.maxY - 180),
                               width: tabThickness, height: 140)
        case .right:
            collapsed = NSRect(x: visible.maxX - tabThickness,
                               y: clamp(old.midY - 70, visible.minY + 40, visible.maxY - 180),
                               width: tabThickness, height: 140)
        case .top:
            collapsed = NSRect(x: clamp(old.midX - 80, visible.minX + 20, visible.maxX - 180),
                               y: visible.maxY - tabThickness, width: 160, height: tabThickness)
        case .bottom:
            collapsed = NSRect(x: clamp(old.midX - 80, visible.minX + 20, visible.maxX - 180),
                               y: visible.minY, width: 160, height: tabThickness)
        }

        snappedEdge = edge
        isCollapsed = true
        canvas?.isHidden = true
        container?.showsTab = true

        panel.setFrame(collapsed, display: true, animate: true)
    }

    func expand() {
        collapseWork?.cancel()          // 取消排队中的"移开就收"，否则刚展开又被打回去
        guard let panel, isCollapsed, let edge = snappedEdge, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let current = panel.frame
        var target: NSRect

        switch edge {
        case .left:
            target = NSRect(x: visible.minX + 8,
                            y: clamp(current.midY - expandedSize.height / 2,
                                     visible.minY + 20, visible.maxY - expandedSize.height - 20),
                            width: expandedSize.width, height: expandedSize.height)
        case .right:
            target = NSRect(x: visible.maxX - expandedSize.width - 8,
                            y: clamp(current.midY - expandedSize.height / 2,
                                     visible.minY + 20, visible.maxY - expandedSize.height - 20),
                            width: expandedSize.width, height: expandedSize.height)
        case .top:
            target = NSRect(x: clamp(current.midX - expandedSize.width / 2,
                                     visible.minX + 20, visible.maxX - expandedSize.width - 20),
                            y: visible.maxY - expandedSize.height - 8,
                            width: expandedSize.width, height: expandedSize.height)
        case .bottom:
            target = NSRect(x: clamp(current.midX - expandedSize.width / 2,
                                     visible.minX + 20, visible.maxX - expandedSize.width - 20),
                            y: visible.minY + 8,
                            width: expandedSize.width, height: expandedSize.height)
        }

        isCollapsed = false
        canvas?.isHidden = false
        container?.showsTab = false

        panel.setFrame(target, display: true, animate: true)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }

    private func scheduleCollapseAfterExit() {
        collapseWork?.cancel()
        guard !isPinned else { return }          // 钉住就不收
        guard snappedEdge != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCollapsed, let edge = self.snappedEdge else { return }
            self.collapse(to: edge)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // 自检
    var debugCollapsed: Bool { isCollapsed }
    var debugPinned: Bool { isPinned }
    func debugTogglePin() { togglePin() }
    func debugSimulateExit() { scheduleCollapseAfterExit() }
    var debugPanelFrame: NSRect { panel?.frame ?? .zero }
    func debugSnap(_ edge: SnapEdge) { collapse(to: edge); expand() }

    func add(_ urls: [URL]) {
        if panel == nil || !isVisible { show() }
        canvas?.add(urls)
    }

    var debugFrame: NSRect { panel?.frame ?? .zero }
    var debugCompact: Bool { isCompact }

    @discardableResult
    func toggleCompact() -> Bool {
        if let canvas, canvas.hasActiveDragSession { return false }
        isCompact.toggle()
        UserDefaults.standard.set(isCompact, forKey: "totori.shelfCompact")
        canvas?.isCompact = isCompact
        if let panel, !isCollapsed {
            let top = panel.frame.maxY
            var frame = panel.frame
            frame.size = expandedSize
            frame.origin.y = top - frame.height
            let target = NSScreen.screens.max { a, b in
                intersectionArea(a.visibleFrame, frame) < intersectionArea(b.visibleFrame, frame)
            } ?? NSScreen.main
            let screen = target?.visibleFrame ?? .zero
            frame.origin = clamped(frame.origin, size: frame.size, in: screen)
            panel.setFrame(frame, display: true)
            rememberOrigin()
        }
        return true
    }
    func debugRestoreOrigin() {
        guard let panel else { return }
        panel.setFrameOrigin(restoredOrigin(for: panel))
    }

    private func makePanel() -> NSPanel {
        let size = expandedSize
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Totori · 文件浮窗"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false   // 背景不再整块拖动，避免抢走文件拖出
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let container = ShelfContainer(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.onHoverChange = { [weak self] inside in
            guard let self else { return }
            if inside, self.isCollapsed {
                self.collapseWork?.cancel()
                self.expand()
            } else if !inside {
                self.scheduleCollapseAfterExit()
            }
        }
        self.container = container

        let glass = NSVisualEffectView(frame: container.bounds)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 18
        glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let canvas = ShelfCanvas(frame: container.bounds)
        canvas.autoresizingMask = [.width, .height]
        canvas.onRequestClose = { [weak self] in self?.hide() }
        canvas.onChooseFiles = { [weak self] in self?.chooseFiles() }
        container.addSubview(canvas)

        canvas.isPinned = isPinned
        canvas.onTogglePin = { [weak self] in self?.togglePin() }
        self.canvas = canvas
        canvas.onToggleCompact = { [weak self] in self?.toggleCompact() }
        panel.contentView = container
        panel.shelfCanvas = canvas
        panel.acceptsMouseMovedEvents = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !self.isCollapsed else { return }
                panel.setFrameOrigin(self.restoredOrigin(for: panel))
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleSnapCheck()
                self?.rememberOrigin()
            }
        }
        return panel
    }
}

/// 带悬停跟踪的容器；收起时只画一条细条
final class ShelfContainer: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var showsTab = false { didSet { needsDisplay = true } }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTab else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: min(bounds.width, bounds.height) / 2,
                                yRadius: min(bounds.width, bounds.height) / 2)
        NSColor(Palette.brand).withAlphaComponent(0.6).setFill()
        path.fill()
    }
}

// MARK: - 画布

final class ShelfCanvas: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var files: [URL] = []
    var selection: Set<Int> = []
    private var selectionAnchor: URL?
    var onRequestClose: (() -> Void)?
    var onChooseFiles: (() -> Void)?

    private struct Block {
        enum Kind {
            case header(String, Int)      // 标题 + 该组真实数量
            case cells([Int])
        }
        var kind: Kind
        var frame: CGRect
    }

    private var blocks: [Block] = []
    private var cellFrames: [Int: CGRect] = [:]
    private var collapsed: Set<String> = []
    private var scrollY: CGFloat = 0
    private var contentHeight: CGFloat = 0

    var isPinned = false { didSet { needsDisplay = true } }
    var onTogglePin: (() -> Void)?
    var onToggleCompact: (() -> Void)?

    var isCompact = false { didSet { needsDisplay = true } }
    private(set) var notice: String?
    private(set) var isDragSourceActive = false
    private(set) var isDragDestinationActive = false
    var hasActiveDragSession: Bool { isDragSourceActive || isDragDestinationActive }

    var debugNotice: String? { notice }
    func debugSetDragSession(_ active: Bool) { isDragSourceActive = active }
    func debugSetDestinationDragSession(_ active: Bool) { isDragDestinationActive = active }
    func debugSimulateDelivery(urls: [URL]) { finishDrag(urls: urls, operation: NSDragOperation.copy, returnedToShelf: false) }
    func debugSimulateCancel(urls: [URL]) { finishDrag(urls: urls, operation: [], returnedToShelf: false) }
    func debugSimulateReturn(urls: [URL]) { finishDrag(urls: urls, operation: NSDragOperation.copy, returnedToShelf: true) }

    private var undoLinkRect: CGRect { CGRect(x: bounds.width - 148, y: bounds.height - footerHeight, width: 66, height: footerHeight) }
    private var compactRect: CGRect { CGRect(x: bounds.width - 76, y: bounds.height - footerHeight, width: 66, height: footerHeight) }
    private func setNotice(_ text: String?) { notice = text; needsDisplay = true }

    private var draggedURLs: [URL] = []
    private var snapshots: [String: FileMetadataSnapshot] = [:]
    private var thumbnails: [String: CGImage] = [:]
    private var thumbStamps: [String: String] = [:]
    private var thumbnailLoading: Set<String> = []
    private var wantedThumbnailPaths: Set<String> = []
    private var loadingPaths: Set<String> = []

    private struct RemovalRecord {
        let urls: [URL]
        let indices: [Int]
        let selected: [URL]
    }
    private var undoStack: [RemovalRecord] = []
    private let undoLimit = 20

    var canUndo: Bool { !undoStack.isEmpty }

    private func recordRemoval(_ removed: [URL], indices: [Int]) {
        guard !removed.isEmpty else { return }
        undoStack.append(RemovalRecord(urls: removed, indices: indices, selected: selectedURLs))
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
    }

    /// 撤销只恢复引用：不动磁盘文件，跳过已不存在的，避免覆盖拖动后新加入的项
    func undo() {
        guard let record = undoStack.popLast() else { return }
        var inserted: [URL] = []
        for (offset, url) in record.urls.enumerated() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard !files.contains(url) else { continue }
            let wanted = offset < record.indices.count ? record.indices[offset] : files.count
            files.insert(url, at: min(max(0, wanted), files.count))
            inserted.append(url)
        }
        // 只恢复「移除前本来选中的」那些；不要把新恢复出来的项自动并进选择
        let restoredSelection = Set(record.selected.map(\.path))
        selection = Set(files.enumerated().filter { restoredSelection.contains($0.element.path) }.map(\.offset))
        setNotice(inserted.isEmpty ? nil : "已撤销")
        loadMetadata(for: inserted, force: true)
        if let first = inserted.first, let index = files.firstIndex(of: first) {
            ensureVisible(index)
        }
        refreshVisibleThumbnails()
        needsDisplay = true
    }

    /// 重新读取简介：reader 内部按 mtime 缓存，force 用于 show/undo/add 后刷新
    func loadMetadata(for urls: [URL], force: Bool = false) {
        for url in urls {
            let key = url.path
            if loadingPaths.contains(key) { continue }
            if !force, snapshots[key] != nil { continue }
            loadingPaths.insert(key)
            Task { @MainActor [weak self] in
                let snapshot = await FileMetadataReader.read(url)
                guard let self else { return }
                self.loadingPaths.remove(key)
                // 迟到结果：文件已不在浮窗里就丢弃，避免缓存无限增长
                guard self.files.contains(url) else { self.snapshots[key] = nil; return }
                self.snapshots[key] = snapshot
                self.needsDisplay = true
            }
        }
    }

    func refreshMetadata() {
        loadMetadata(for: files, force: true)
        refreshVisibleThumbnails()
    }

    /// 只保留可见项 + 少量预取的缩略图，滚动后补载
    private func refreshVisibleThumbnails() {
        relayout()
        let corrected = min(max(0, scrollY), maxScroll)
        if corrected != scrollY { scrollY = corrected; relayout() }
        let visible = cellFrames.filter { $0.value.intersects(contentViewport) }.keys.sorted()
        var wanted = Array(visible.prefix(12))
        // 最后一个文件已经可见时没有预取项，不能构造下界大于上界的 ClosedRange。
        if let last = visible.last, last + 1 < files.count {
            wanted += Array((last + 1)...min(files.count - 1, last + 4))
        }
        wanted = Array(Set(wanted)).sorted()
        let keep = Set(wanted.compactMap { files.indices.contains($0) ? files[$0].path : nil })
        wantedThumbnailPaths = keep
        thumbnails = thumbnails.filter { keep.contains($0.key) }
        thumbStamps = thumbStamps.filter { keep.contains($0.key) }
        loadThumbnails(for: wanted.compactMap { files.indices.contains($0) ? files[$0] : nil })
    }

    /// 后台生成缩略图；迟到结果按 mtime+size 校验，过期就丢弃并补排新的
    func loadThumbnails(for urls: [URL], force: Bool = false) {
        for url in urls {
            let key = url.path
            let currentStamp = ShelfThumbnailStore.shared.signature(for: url)
            if thumbStamps[key] != currentStamp {
                thumbnails[key] = nil
                thumbStamps[key] = nil
                needsDisplay = true
            }
            if thumbnailLoading.contains(key) { continue }
            if !force, thumbnails[key] != nil, thumbStamps[key] == currentStamp { continue }
            thumbnailLoading.insert(key)
            Task { @MainActor [weak self] in
                let result = await ShelfThumbnailStore.shared.load(url, maxPixel: 220)
                guard let self else { return }
                self.thumbnailLoading.remove(key)
                guard let result, self.files.contains(url), self.wantedThumbnailPaths.contains(key) else { return }

                // 文件已被替换：丢弃旧结果并立即排新的一次
                guard ShelfThumbnailStore.shared.signature(for: url) == result.stamp else {
                    self.loadThumbnails(for: [url], force: true)
                    return
                }
                guard self.files.contains(url) else {
                    self.thumbnails[key] = nil
                    self.thumbStamps[key] = nil
                    return
                }
                // 生成失败也要清掉旧图，避免显示过期缩略图
                guard let image = result.image else {
                    self.thumbnails[key] = nil
                    self.thumbStamps[key] = nil
                    self.needsDisplay = true
                    return
                }
                self.thumbnails[key] = image
                self.thumbStamps[key] = result.stamp
                self.needsDisplay = true
            }
        }
    }

    /// 撤销后把恢复项滚进可视区，避免「看起来没恢复」
    private func ensureVisible(_ index: Int) {
        relayout()
        guard let frame = cellFrames[index] else { return }
        let top = headerHeight + 4 + 22  // 留出一行分组标题，首行恢复时不会压到标题栏
        let bottom = bounds.height - footerHeight
        if frame.minY < top {
            scrollY = max(0, scrollY - (top - frame.minY))
        } else if frame.maxY > bottom {
            scrollY = min(max(0, contentHeight - bounds.height), scrollY + (frame.maxY - bottom))
        }
    }
    private var rubberStart: NSPoint?
    private var rubberRect: CGRect = .zero
    private var dragOrigin: NSPoint?
    private var startedDrag = false

    private let headerHeight: CGFloat = 32
    private let footerHeight: CGFloat = 24
    private let gridSpacing: CGFloat = 8
    private let gridCellH: CGFloat = 138
    private let listRowH: CGFloat = 62

    enum ShelfViewMode: String { case grid, list }

    private(set) var viewMode: ShelfViewMode =
        ShelfViewMode(rawValue: UserDefaults.standard.string(forKey: "totori.shelfViewMode") ?? "") ?? .grid

    private var gridCellW: CGFloat {
        (bounds.width - padding * 2 - gridSpacing * 2) / 3
    }

    private let helpText = """
    拖文件进来：加入暂存
    拖出去：交付后自动移出，取消则保留
    空格：快速查看；⌘ 点击：多选；⇧ 点击：范围选择
    ⌘A：全选；Delete：移除引用，保留原文件
    ⌘Z：撤销移除
    顶部按钮：添加、钉住、网格/列表切换
    """

    var debugScrollOffset: CGFloat { scrollY }
    var debugMaximumScroll: CGFloat { maxScroll }
    var debugVisibleFileCount: Int {
        relayout()
        return cellFrames.filter { $0.value.intersects(contentViewport) }.count
    }
    func debugThumbnailSize(for url: URL) -> NSSize? {
        thumbnails[url.path].map { NSSize(width: $0.width, height: $0.height) }
    }
    var debugThumbnailCount: Int { thumbnails.count }
    func debugDragPreviewFrame(for index: Int) -> CGRect? {
        relayout()
        return cellFrames[index].map { dragPreviewFrame(for: $0) }
    }
    func debugScrollToBottom() {
        relayout()
        scrollY = maxScroll
        refreshVisibleThumbnails()
        needsDisplay = true
    }

    private var maxScroll: CGFloat { max(0, contentHeight - bounds.height) }

    func toggleViewMode() {
        relayout()
        // 记录切换前最上方的可见文件，切换后让它继续停在顶部附近
        let anchor = cellFrames
            .filter { $0.value.maxY > headerHeight + 2 }
            .min { $0.value.minY < $1.value.minY }?.key
        viewMode = viewMode == .grid ? .list : .grid
        UserDefaults.standard.set(viewMode.rawValue, forKey: "totori.shelfViewMode")
        relayout()
        if let anchor, let frame = cellFrames[anchor] {
            scrollY += frame.minY - (headerHeight + 4)
        }
        scrollY = min(max(0, scrollY), maxScroll)
        refreshVisibleThumbnails()
        needsDisplay = true
    }
    private let padding: CGFloat = 10

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 让 AppKit 不要把这里的按下当成"拖动窗口"：
    /// 文件拖出、多选拖出、空白框选都走自己的路径，只有标题栏显式 performDrag。
    override var mouseDownCanMoveWindow: Bool { false }

    private var axElements: [String: ShelfAXElement] = [:]

    override func accessibilityChildren() -> [Any]? {
        relayout()
        guard let window else { return [] }
        var children: [ShelfAXElement] = []
        func add(_ id: String, _ label: String, _ rect: CGRect, value: String? = nil, action: @escaping () -> Void) {
            let item = axElements[id] ?? ShelfAXElement()
            item.setAccessibilityRole(.button)
            item.setAccessibilityEnabled(true)
            item.setAccessibilityLabel(label)
            item.setAccessibilityValue(value)
            item.setAccessibilityIdentifier(id)
            item.setAccessibilityParent(self)
            item.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            item.press = action
            axElements[id] = item
            children.append(item)
        }
        add("shelf.close", "关闭文件浮窗", CGRect(x: bounds.width - 28, y: 0, width: 28, height: headerHeight)) { [weak self] in self?.onRequestClose?() }
        add("shelf.add", "添加文件…", CGRect(x: bounds.width - 60, y: 0, width: 28, height: headerHeight)) { [weak self] in self?.onChooseFiles?() }
        if canUndo {
            add("shelf.notice.undo", "撤销移除", undoLinkRect, value: notice ?? "") { [weak self] in self?.undo() }
        }
        add("shelf.compactToggle", isCompact ? "展开浮窗" : "紧凑浮窗", compactRect) { [weak self] in self?.onToggleCompact?() }
        add("shelf.viewMode", viewMode == .grid ? "切换为列表视图" : "切换为网格视图",
            viewModeRect.insetBy(dx: -3, dy: -3)) { [weak self] in self?.toggleViewMode() }
        if canUndo {
            add("shelf.undo", "撤销移除", CGRect(x: bounds.width - 92, y: 0, width: 28, height: headerHeight)) { [weak self] in self?.undo() }
        }
        if !files.isEmpty {
            add("shelf.pin", isPinned ? "取消钉住" : "钉住文件浮窗", pinRect.insetBy(dx: -3, dy: -3)) { [weak self] in self?.onTogglePin?() }
        }
        for block in blocks {
            if case let .header(title, count) = block.kind {
                add("shelf.group.\(title)", "\(collapsed.contains(title) ? "展开" : "折叠")\(title)，\(count) 个文件", block.frame) { [weak self] in self?.debugToggleCollapse(title) }
            }
        }
        for (index, frame) in cellFrames.sorted(by: { $0.key < $1.key }) where files.indices.contains(index) {
            let snapshot = snapshots[files[index].path]
            let help = [snapshot?.summary, snapshot?.exactSizeText].compactMap { $0 }.joined(separator: "，")
            add("shelf.file.\(index)", files[index].lastPathComponent, frame,
                value: "\(selection.contains(index) ? "已选" : "未选")· \(help)") { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                self.selectFile(at: index, modifiers: NSEvent.modifierFlags)
            }
        }
        let activeIDs = Set(children.compactMap { $0.accessibilityIdentifier() })
        axElements = axElements.filter { activeIDs.contains($0.key) }
        return children
    }

    // MARK: 数据

    /// 与原生列表一致：⌘ 切换单项，⇧ 按显示顺序连续选择；锚点用 URL 避免增删后错位。
    /// 鼠标准备拖出已选多项时保留整组，AX 单击则选中这一项。
    func selectFile(at index: Int, modifiers: NSEvent.ModifierFlags = [], preserveGroup: Bool = false) {
        relayout()
        guard files.indices.contains(index), cellFrames[index] != nil else { return }
        if modifiers.contains(.shift) {
            let ordered = cellFrames.keys.sorted { a, b in
                let left = cellFrames[a]!, right = cellFrames[b]!
                return abs(left.minY - right.minY) < 1 ? left.minX < right.minX : left.minY < right.minY
            }
            let anchor = selectionAnchor.flatMap { files.firstIndex(of: $0) } ?? selection.min() ?? index
            if let from = ordered.firstIndex(of: anchor), let to = ordered.firstIndex(of: index) {
                let range = Set(ordered[min(from, to)...max(from, to)])
                selection = modifiers.contains(.command) ? selection.union(range) : range
            } else { selection = [index]; selectionAnchor = files[index] }
        } else {
            if modifiers.contains(.command) {
                if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            } else if !preserveGroup || !selection.contains(index) { selection = [index] }
            selectionAnchor = files[index]
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    /// 全选只改变暂存引用的选择状态，移除仍可通过既有撤销恢复。
    func selectAllFiles() {
        selection = Set(files.indices)
        selectionAnchor = files.first
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    /// 方向键移动后滚动到选中项，避免长列表中焦点落到屏幕外。
    func moveSelection(by step: Int) {
        relayout()
        let ordered = cellFrames.keys.sorted { a, b in
            let left = cellFrames[a]!, right = cellFrames[b]!
            return abs(left.minY - right.minY) < 1 ? left.minX < right.minX : left.minY < right.minY
        }
        guard !ordered.isEmpty else { return }
        let current = selection.sorted().first.flatMap { ordered.firstIndex(of: $0) }
        let target = min(ordered.count - 1, max(0, (current ?? (step > 0 ? -1 : ordered.count)) + step))
        selectFile(at: ordered[target])
        ensureVisible(ordered[target])
        refreshVisibleThumbnails()
    }

    func add(_ urls: [URL]) {
        var existing = Set(files.map(\.path))
        var added: [URL] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if existing.insert(url.path).inserted { files.append(url); added.append(url) }
        }
        setNotice(nil)
        loadMetadata(for: added)
        refreshVisibleThumbnails()
        needsDisplay = true
    }

    func clear() {
        recordRemoval(files, indices: Array(files.indices))
        setNotice("已清空 \(files.count) 个")
        files.removeAll()
        selection.removeAll()
        selectionAnchor = nil
        snapshots.removeAll()
        thumbnails.removeAll()
        thumbStamps.removeAll()
        wantedThumbnailPaths.removeAll()
        scrollY = 0
        needsDisplay = true
    }

    func removeSelected() {
        let doomed = selection
        let removed = files.enumerated().filter { doomed.contains($0.offset) }.map(\.element)
        recordRemoval(removed, indices: doomed.sorted())
        setNotice("已移除 \(removed.count) 个")
        files = files.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        for url in removed { snapshots[url.path] = nil; thumbnails[url.path] = nil; thumbStamps[url.path] = nil }
        selection.removeAll()
        refreshVisibleThumbnails()
        needsDisplay = true
    }

    private var selectedURLs: [URL] {
        selection.sorted().compactMap { files.indices.contains($0) ? files[$0] : nil }
    }

    // 自检用
    var debugGroups: [String] { grouped.map { "\($0.title):\($0.indices.count)" } }
    var debugCellCount: Int { relayout(); return cellFrames.count }
    var debugCellFrames: [String] { relayout(); return cellFrames.sorted { $0.key < $1.key }.map { "\($0.key)@\(Int($0.value.minX)),\(Int($0.value.minY))" } }
    var debugPreviewCount: Int { selectedURLs.count }
    func debugToggleCollapse(_ title: String) {
        if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
        refreshVisibleThumbnails()
        needsDisplay = true
    }

    // MARK: 分组

    private func groupTitle(for url: URL) -> String {
        switch FormatCatalog.kind(of: url) {
        case .image:    return "图片"
        case .document: return "文档"
        case .media:    return "音视频"
        case .archive:  return "压缩包"
        case .unknown:  return "其他"
        }
    }

    /// 按类型分组，组内保持加入顺序
    private var grouped: [(title: String, indices: [Int])] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for (index, url) in files.enumerated() {
            let title = groupTitle(for: url)
            if map[title] == nil { order.append(title); map[title] = [] }
            map[title]?.append(index)
        }
        let preferred = ["图片", "文档", "音视频", "压缩包", "其他"]
        return preferred.filter { map[$0] != nil }.map { ($0, map[$0] ?? []) }
            + order.filter { !preferred.contains($0) }.map { ($0, map[$0] ?? []) }
    }

    // MARK: 布局

    private func relayout() {
        var y = headerHeight + 4 - scrollY
        var newBlocks: [Block] = []
        var newCells: [Int: CGRect] = [:]

        for group in grouped {
            let headerFrame = CGRect(x: 0, y: y, width: bounds.width, height: 22)
            newBlocks.append(Block(kind: .header(group.title, group.indices.count), frame: headerFrame))
            y += 22

            if collapsed.contains(group.title) {
                y += 4
                continue
            }

            if viewMode == .list {
                for index in group.indices {
                    newCells[index] = CGRect(x: padding, y: y + 2,
                                             width: bounds.width - padding * 2,
                                             height: listRowH - 4)
                    y += listRowH
                }
            } else {
                var row: [Int] = []
                for index in group.indices {
                    row.append(index)
                    if row.count == 3 {
                        place(row: row, y: &y, into: &newCells)
                        row.removeAll()
                    }
                }
                if !row.isEmpty { place(row: row, y: &y, into: &newCells) }
            }
            newBlocks.append(Block(kind: .cells(group.indices), frame: .zero))
            y += 6
        }

        blocks = newBlocks
        cellFrames = newCells
        contentHeight = y + scrollY + footerHeight
    }

    private func place(row: [Int], y: inout CGFloat, into cells: inout [Int: CGRect]) {
        for (column, index) in row.enumerated() {
            cells[index] = CGRect(x: padding + CGFloat(column) * (gridCellW + gridSpacing), y: y,
                                  width: gridCellW, height: gridCellH - 4)
        }
        y += gridCellH
    }

    private var themeObserver: NSObjectProtocol?

    /// 浮窗是自绘的，主题变了不会自动重画；挂到窗口后监听偏好变化并刷新。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = nil
        guard window != nil else { return }
        themeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if helpRect.insetBy(dx: -3, dy: -3).contains(point) {
            toolTip = helpText
            return
        }
        if let index = cellIndex(at: point), files.indices.contains(index),
           let snapshot = snapshots[files[index].path] {
            toolTip = [files[index].lastPathComponent,
                       files[index].path,
                       snapshot.summary,
                       snapshot.exactSizeText].compactMap { $0 }.joined(separator: "\n")
        } else {
            toolTip = nil
        }
    }

    private func cellIndex(at point: NSPoint) -> Int? {
        guard contentViewport.contains(point) else { return nil }
        relayout()
        return cellFrames.first { $0.value.contains(point) }?.key
    }

    private func headerTitle(at point: NSPoint) -> String? {
        guard contentViewport.contains(point) else { return nil }
        relayout()
        for block in blocks {
            guard case let .header(title, _) = block.kind else { continue }
            if block.frame.contains(point) { return title }
        }
        return nil
    }

    // MARK: 绘制

    /// 文件内容只在固定标题栏和底栏之间绘制，命中范围使用同一矩形。
    private var contentViewport: NSRect {
        NSRect(x: 0, y: headerHeight, width: bounds.width,
               height: max(0, bounds.height - headerHeight - footerHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        relayout()
        // 底色比之前更实：系统材质本身偏灰，盖得太薄会和主窗口的浅绿底色不是一个色调
        NSColor(Palette.surface).withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        NSColor(Palette.brand).withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: contentViewport).addClip()
        drawBlocks()
        drawRubberBand()
        NSGraphicsContext.restoreGraphicsState()
        drawHeader()
        drawFooter()
    }

    // MARK: 标题栏控件

    private var pinRect: CGRect { CGRect(x: bounds.width - 124, y: 6, width: 26, height: 20) }
    private var viewModeRect: CGRect { CGRect(x: bounds.width - 156, y: 6, width: 26, height: 20) }
    private var helpRect: CGRect { CGRect(x: padding + 30, y: 6, width: 18, height: 20) }

    private func drawPinButton() {
        let rect = pinRect
        (isPinned ? NSColor(Palette.brand).withAlphaComponent(0.85)
                  : NSColor(Palette.surface).withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let pinned = isPinned
        if let symbol = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                accessibilityDescription: pinned ? "取消钉住" : "钉住文件浮窗") {
            let tinted = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
                symbol.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
                (pinned ? NSColor.white : NSColor(Palette.brand)).set()
                NSRect(x: 0, y: 0, width: 12, height: 12).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12))
        }
    }

    private func drawViewModeButton() {
        let rect = viewModeRect
        NSColor(Palette.surface).withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let name = viewMode == .grid ? "list.bullet" : "square.grid.2x2"
        if let symbol = NSImage(systemSymbolName: name,
                                accessibilityDescription: viewMode == .grid ? "切换为列表" : "切换为网格") {
            let tinted = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
                symbol.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
                NSColor(Palette.brand).set()
                NSRect(x: 0, y: 0, width: 12, height: 12).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12))
        }
    }

    private func drawHelpButton() {
        let rect = helpRect
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(Palette.brand).withAlphaComponent(0.85),
        ]
        ("?" as NSString).draw(in: CGRect(x: rect.minX + 3, y: rect.minY + 2, width: rect.width, height: 16),
                               withAttributes: style)
    }

    private func drawFooter() {
        let base = selection.isEmpty
            ? "\(files.count) 个文件 · 空格预览"
            : "已选 \(selection.count) / \(files.count)"
        let line = notice ?? base
        (line as NSString).draw(
            in: CGRect(x: padding, y: bounds.height - footerHeight + 5,
                       width: max(40, bounds.width - padding - 156), height: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                             .foregroundColor: notice == nil ? NSColor.tertiaryLabelColor : NSColor(Palette.textSecondary)])

        if canUndo {
            ("撤销" as NSString).draw(in: undoLinkRect.insetBy(dx: 8, dy: 4),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                      .foregroundColor: NSColor(Palette.brand)])
        }
        let title = isCompact ? "展开" : "紧凑"
        (title as NSString).draw(in: compactRect.insetBy(dx: 16, dy: 4),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                                                  .foregroundColor: NSColor(Palette.textSecondary)])
    }

    private func drawHeader() {
        ("浮窗" as NSString).draw(at: NSPoint(x: padding, y: 9), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(Palette.textPrimary),
        ])
        ("＋" as NSString).draw(at: NSPoint(x: bounds.width - 56, y: 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(Palette.brand),
        ])
        drawHelpButton()
        drawViewModeButton()
        drawPinButton()
        if canUndo {
            ("↶" as NSString).draw(at: NSPoint(x: bounds.width - 87, y: 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor(Palette.brand),
            ])
        }

        let close = "✕" as NSString
        let size = close.size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold)])
        close.draw(at: NSPoint(x: bounds.width - padding - size.width, y: 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func drawBlocks() {
        guard !files.isEmpty else {
            let hint = "把文件拖进来" as NSString
            let size = hint.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.midY - 8),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                       .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }

        for block in blocks {
            switch block.kind {
            case .header(let title, let count):
                let arrow = collapsed.contains(title) ? "▸" : "▾"
                let text = "\(arrow) \(title) \(count)" as NSString
                text.draw(at: NSPoint(x: padding, y: block.frame.minY + 5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor(Palette.textSecondary),
                ])
            case .cells(let indices):
                for index in indices {
                    guard let frame = cellFrames[index], files.indices.contains(index) else { continue }
                    drawCell(index: index, frame: frame)
                }
            }
        }
    }

    private func drawCell(index: Int, frame: CGRect) {
        let url = files[index]
        let selected = selection.contains(index)
        let snapshot = snapshots[url.path]

        if selected {
            let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
            NSColor(Palette.brand).withAlphaComponent(0.20).setFill()
            path.fill()
            NSColor(Palette.brand).withAlphaComponent(0.68).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if viewMode == .list {
            drawListCell(url: url, snapshot: snapshot, frame: frame, selected: selected)
        } else {
            drawGridCell(url: url, snapshot: snapshot, frame: frame, selected: selected)
        }
    }

    /// 主摘要 + 次摘要：图片给分辨率/大小，视频加时长，PDF 页数，音频时长
    private func summaryLines(_ snapshot: FileMetadataSnapshot?) -> (primary: String, secondary: String) {
        guard let snapshot else { return ("", "") }
        let secondary = [snapshot.formatName, snapshot.sizeText]
            .compactMap { $0 }
            .joined(separator: " · ")

        if snapshot.isVideo {
            let parts = [snapshot.resolutionText, snapshot.durationText].compactMap { $0 }
            return (parts.joined(separator: " · "), secondary)
        }
        if snapshot.isImage {
            return (snapshot.resolutionText ?? "", secondary)
        }
        if let pages = snapshot.pageCount {
            return ("\(pages) 页", secondary)
        }
        if let duration = snapshot.durationText {
            return (duration, secondary)
        }
        return ("", secondary)
    }

    private func drawThumbnail(_ url: URL, in rect: CGRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(Palette.surface).withAlphaComponent(0.55).setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let thumbnail = thumbnails[url.path] {
            let size = NSSize(width: thumbnail.width, height: thumbnail.height)
            var target = rect
            let scale = max(rect.width / size.width, rect.height / size.height)
            target.size = NSSize(width: size.width * scale, height: size.height * scale)
            target.origin = NSPoint(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2)
            NSImage(cgImage: thumbnail, size: size).draw(in: target, from: .zero,
                                                         operation: .sourceOver, fraction: 1,
                                                         respectFlipped: true, hints: nil)
        } else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let side = min(rect.width, rect.height) * 0.62
            icon.size = NSSize(width: side, height: side)
            icon.draw(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1.0,
                      respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawGridCell(url: URL, snapshot: FileMetadataSnapshot?, frame: CGRect, selected: Bool) {
        let inset: CGFloat = 5
        let thumbHeight: CGFloat = 62
        drawThumbnail(url, in: CGRect(x: frame.minX + inset, y: frame.minY + inset,
                                      width: frame.width - inset * 2, height: thumbHeight),
                      radius: 8)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        (url.lastPathComponent as NSString).draw(
            in: CGRect(x: frame.minX + 3, y: frame.minY + 71, width: frame.width - 6, height: 24),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor(Palette.textPrimary).withAlphaComponent(selected ? 1 : 0.88),
                .paragraphStyle: style,
            ])

        // 视频：分辨率一行 + 时长/大小一行；其它：主信息 + 格式·大小
        let lines: (String, String)
        if snapshot?.isVideo == true, let resolution = snapshot?.resolutionText {
            let second = [snapshot?.durationText, snapshot?.sizeText].compactMap { $0 }.joined(separator: " · ")
            lines = (resolution, second)
        } else {
            lines = summaryLines(snapshot)
        }
        let summary = [lines.0, lines.1].filter { !$0.isEmpty }.joined(separator: "\n")
        if !summary.isEmpty {
            (summary as NSString).draw(
                in: CGRect(x: frame.minX + 3, y: frame.minY + 96, width: frame.width - 6, height: 30),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor(Palette.textSecondary),
                    .paragraphStyle: style,
                ])
        }
    }

    private func drawListCell(url: URL, snapshot: FileMetadataSnapshot?, frame: CGRect, selected: Bool) {
        let side: CGFloat = 38
        drawThumbnail(url, in: CGRect(x: frame.minX + 6, y: frame.midY - side / 2, width: side, height: side),
                      radius: 6)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textX = frame.minX + 6 + side + 9
        let textWidth = frame.maxX - textX - 6

        (url.lastPathComponent as NSString).draw(
            in: CGRect(x: textX, y: frame.minY + 8, width: textWidth, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor(Palette.textPrimary).withAlphaComponent(selected ? 1 : 0.9),
                .paragraphStyle: style,
            ])

        let lines = summaryLines(snapshot)
        if !lines.primary.isEmpty {
            (lines.primary as NSString).draw(
                in: CGRect(x: textX, y: frame.minY + 26, width: textWidth, height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor(Palette.textSecondary),
                                 .paragraphStyle: style])
        }
        if !lines.secondary.isEmpty {
            (lines.secondary as NSString).draw(
                in: CGRect(x: textX, y: frame.minY + 41, width: textWidth, height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor(Palette.textSecondary).withAlphaComponent(0.85),
                                 .paragraphStyle: style])
        }
    }

    private func drawRubberBand() {
        guard !rubberRect.isEmpty else { return }
        let path = NSBezierPath(rect: rubberRect)
        NSColor(Palette.brand).withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor(Palette.brand).withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if point.y > bounds.height - footerHeight {
            if canUndo, undoLinkRect.contains(point) { undo(); return }
            if compactRect.contains(point) { onToggleCompact?(); return }
            return
        }

        if point.y < headerHeight, point.x > bounds.width - 28 {
            onRequestClose?()
            return
        }

        if point.y < headerHeight, viewModeRect.insetBy(dx: -3, dy: -3).contains(point) {
            toggleViewMode()
            return
        }

        // 钉住按钮：必须在通用 performDrag 之前，否则会被拖窗分支吃掉
        if !files.isEmpty, point.y < headerHeight,
           pinRect.insetBy(dx: -3, dy: -3).contains(point) {
            onTogglePin?()
            return
        }

        if point.y < headerHeight, canUndo, point.x > bounds.width - 92, point.x <= bounds.width - 64 {
            undo()
            return
        }

        if point.y < headerHeight {
            if point.x > bounds.width - 60 { onChooseFiles?() }
            else { window?.performDrag(with: event) }
            return
        }

        if let title = headerTitle(at: point) {
            debugToggleCollapse(title)
            return
        }

        if let index = cellIndex(at: point) {
            selectFile(at: index, modifiers: event.modifierFlags, preserveGroup: true)
            dragOrigin = point
            startedDrag = false
            needsDisplay = true
            return
        }

        if !event.modifierFlags.contains(.command) { selection.removeAll() }
        rubberStart = point
        rubberRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let start = rubberStart {
            rubberRect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                width: abs(point.x - start.x), height: abs(point.y - start.y))
            relayout()
            selection = Set(cellFrames.filter { $0.value.intersects(rubberRect) }.keys)
            needsDisplay = true
            return
        }

        guard let origin = dragOrigin, !startedDrag else { return }
        guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
        startedDrag = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        rubberStart = nil
        rubberRect = .zero
        dragOrigin = nil
        startedDrag = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        relayout()
        let maxScroll = max(0, contentHeight - bounds.height)
        scrollY = min(max(0, scrollY - event.scrollingDeltaY), maxScroll)
        refreshVisibleThumbnails()
        needsDisplay = true
    }

    // MARK: 拖出

    private func dragPreviewFrame(for frame: CGRect) -> CGRect {
        if viewMode == .list {
            return CGRect(x: frame.minX + 6, y: frame.midY - 19, width: 38, height: 38)
        }
        return CGRect(x: frame.midX - 23, y: frame.minY + 4, width: 46, height: 46)
    }

    private func beginDrag(with event: NSEvent) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        isDragSourceActive = true
        draggedURLs = urls          // 固定本次拖出的快照，之后新增/取消都不影响判定
        relayout()

        var items: [NSDraggingItem] = []
        for url in urls {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let index = files.firstIndex(of: url)
            let frame = index.flatMap { cellFrames[$0] } ?? CGRect(x: 0, y: 0, width: 46, height: 46)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(dragPreviewFrame(for: frame), contents: icon)
            items.append(item)
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// 拖出会话结束（成功或取消）都清一次，避免下次按下还带着旧锚点
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // 落点仍在浮窗自己身上 = 拖回自身，不算交付
        // 用窗口命中而不是几何矩形：被其他窗口遮住时不会误判成「拖回自身」
        let hitWindow = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        let returned = hitWindow != 0 && hitWindow == window?.windowNumber
        finishDrag(urls: draggedURLs, operation: operation, returnedToShelf: returned)
    }

    /// 拖出结果处理：只有「真的交付出去」才把这批条目从暂存台移走。
    /// 取消/拒收（operation 为空）与拖回自身都保留；磁盘文件一概不动。
    func finishDrag(urls: [URL], operation: NSDragOperation, returnedToShelf: Bool) {
        defer {
            isDragSourceActive = false
            draggedURLs = []
            dragOrigin = nil
            startedDrag = false
            rubberStart = nil
            rubberRect = .zero
            needsDisplay = true
        }
        guard !urls.isEmpty, !operation.isEmpty, !returnedToShelf else { return }

        let doomedIndices = files.enumerated().filter { urls.contains($0.element) }.map(\.offset)
        let doomedURLs = files.enumerated().filter { urls.contains($0.element) }.map(\.element)
        recordRemoval(doomedURLs, indices: doomedIndices)
        for url in doomedURLs { snapshots[url.path] = nil; thumbnails[url.path] = nil; thumbStamps[url.path] = nil }

        let delivered = Set(urls.map(\.path))
        // 未被拖走的选中项，删除后按 URL 重新映射
        let stillSelected = Set(selectedURLs.map(\.path)).subtracting(delivered)

        let removedCount = files.filter { delivered.contains($0.path) }.count
        files.removeAll { delivered.contains($0.path) }
        if removedCount > 0 { setNotice("已拖出 \(removedCount) 个") }

        let keep = Set(files.map(\.path)).intersection(stillSelected)
        selection = Set(files.enumerated().filter { keep.contains($0.element.path) }.map(\.offset))
        relayout()
        scrollY = min(scrollY, max(0, contentHeight - bounds.height))
        refreshVisibleThumbnails()
    }

    /// 拖拽期间不让 ⌘/⌥ 改变拖放语义（原版同样实现）
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    // MARK: 键盘 / 快览

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:                          // space → 快速预览
            toggleQuickLook()
        case 51, 117:
            removeSelected()
        case 6 where event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command:
            undo()
        case 0 where event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command:
            selectAllFiles()
        case 53:
            selection.removeAll()
            needsDisplay = true
        case 123, 126:
            moveSelection(by: -1)
        case 124, 125:
            moveSelection(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard !selectedURLs.isEmpty else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: 右键

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let index = cellIndex(at: point) {
            if !selection.contains(index) { selection = [index]; needsDisplay = true }
            for (title, action) in [("快速查看", #selector(menuQuickLook)),
                                    ("在访达中显示", #selector(menuReveal)),
                                    ("从浮窗移除", #selector(menuRemove))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        let undoItem = NSMenuItem(title: "撤销移除", action: #selector(menuUndo), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = .command
        undoItem.target = self
        undoItem.isEnabled = canUndo
        menu.addItem(undoItem)

        let clear = NSMenuItem(title: "清空", action: #selector(menuClear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        return menu
    }

    @objc private func menuQuickLook() { toggleQuickLook() }

    @objc private func menuReveal() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func menuRemove() { removeSelected() }

    @objc private func menuClear() { clear() }

    @objc private func menuUndo() { undo() }

    // MARK: 拖入

    override func resetCursorRects() {
        super.resetCursorRects()
        if !files.isEmpty {
            addCursorRect(pinRect.insetBy(dx: -3, dy: -3), cursor: .pointingHand)
        }
    }

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("文件浮窗列表")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragDestinationActive = true
        return .copy
    }

    /// 目标会话结束（含停在窗口内按 Esc）时解锁
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragDestinationActive = false
    }

    /// 外部文件拖进来又离开（未在浮窗放下）时解锁紧凑切换
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        isDragDestinationActive = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragDestinationActive = false
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        add(urls)
        return true
    }
}


private final class ShelfPanel: NSPanel {
    weak var shelfCanvas: ShelfCanvas?

    override var canBecomeKey: Bool { true }

    /// 窗口级 ⌘Z：不依赖 canvas 是否第一响应者（点过标题栏后也能撤销）
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z",
           let canvas = shelfCanvas, canvas.canUndo {
            canvas.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ShelfAXElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}
