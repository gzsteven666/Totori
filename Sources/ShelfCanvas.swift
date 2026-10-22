import AppKit
import Quartz

final class ShelfCanvas: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var files: [URL] = []
    var selection: Set<Int> = []
    var selectionAnchor: URL?
    var onRequestClose: (() -> Void)?
    var onChooseFiles: (() -> Void)?

    struct Block {
        enum Kind {
            case header(String, Int)      // 标题 + 该组真实数量
            case cells([Int])
        }
        var kind: Kind
        var frame: CGRect
    }

    var blocks: [Block] = []
    var cellFrames: [Int: CGRect] = [:]
    var collapsed: Set<String> = []
    var scrollY: CGFloat = 0
    var contentHeight: CGFloat = 0

    var isPinned = false { didSet { needsDisplay = true } }
    var onTogglePin: (() -> Void)?
    var onToggleCompact: (() -> Void)?

    var isCompact = false { didSet { needsDisplay = true } }
    private(set) var notice: String?
    var isDragSourceActive = false
    var isDragDestinationActive = false
    var hasActiveDragSession: Bool { isDragSourceActive || isDragDestinationActive }

    var debugNotice: String? { notice }
    func debugSetDragSession(_ active: Bool) { isDragSourceActive = active }
    func debugSetDestinationDragSession(_ active: Bool) { isDragDestinationActive = active }
    func debugSimulateDelivery(urls: [URL]) { finishDrag(urls: urls, operation: NSDragOperation.copy, returnedToShelf: false) }
    func debugSimulateCancel(urls: [URL]) { finishDrag(urls: urls, operation: [], returnedToShelf: false) }
    func debugSimulateReturn(urls: [URL]) { finishDrag(urls: urls, operation: NSDragOperation.copy, returnedToShelf: true) }

    var undoLinkRect: CGRect { CGRect(x: bounds.width - 148, y: bounds.height - footerHeight, width: 66, height: footerHeight) }
    var compactRect: CGRect { CGRect(x: bounds.width - 76, y: bounds.height - footerHeight, width: 66, height: footerHeight) }
    func setNotice(_ text: String?) { notice = text; needsDisplay = true }

    var draggedURLs: [URL] = []
    var snapshots: [String: FileMetadataSnapshot] = [:]
    var thumbnails: [String: CGImage] = [:]
    var thumbStamps: [String: String] = [:]
    var thumbnailLoading: Set<String> = []
    var wantedThumbnailPaths: Set<String> = []
    var loadingPaths: Set<String> = []

    struct RemovalRecord {
        let urls: [URL]
        let indices: [Int]
        let selected: [URL]
    }
    var undoStack: [RemovalRecord] = []
    let undoLimit = 20

    var canUndo: Bool { !undoStack.isEmpty }

    func recordRemoval(_ removed: [URL], indices: [Int]) {
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
    func refreshVisibleThumbnails() {
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
    func ensureVisible(_ index: Int) {
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
    var rubberStart: NSPoint?
    var rubberRect: CGRect = .zero
    var dragOrigin: NSPoint?
    var startedDrag = false

    let headerHeight: CGFloat = 32
    let footerHeight: CGFloat = 24
    let gridSpacing: CGFloat = 8
    let gridCellH: CGFloat = 138
    let listRowH: CGFloat = 62

    enum ShelfViewMode: String { case grid, list }

    private(set) var viewMode: ShelfViewMode =
        ShelfViewMode(rawValue: UserDefaults.standard.string(forKey: "totori.shelfViewMode") ?? "") ?? .grid

    var gridCellW: CGFloat {
        (bounds.width - padding * 2 - gridSpacing * 2) / 3
    }

    let helpText = """
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

    var maxScroll: CGFloat { max(0, contentHeight - bounds.height) }

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
    let padding: CGFloat = 10

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 让 AppKit 不要把这里的按下当成"拖动窗口"：
    /// 文件拖出、多选拖出、空白框选都走自己的路径，只有标题栏显式 performDrag。
    override var mouseDownCanMoveWindow: Bool { false }

    var axElements: [String: ShelfAXElement] = [:]

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

    var selectedURLs: [URL] {
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

    func groupTitle(for url: URL) -> String {
        switch FormatCatalog.kind(of: url) {
        case .image:    return "图片"
        case .document: return "文档"
        case .media:    return "音视频"
        case .archive:  return "压缩包"
        case .unknown:  return "其他"
        }
    }

    /// 按类型分组，组内保持加入顺序
    var grouped: [(title: String, indices: [Int])] {
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

    func relayout() {
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

    func place(row: [Int], y: inout CGFloat, into cells: inout [Int: CGRect]) {
        for (column, index) in row.enumerated() {
            cells[index] = CGRect(x: padding + CGFloat(column) * (gridCellW + gridSpacing), y: y,
                                  width: gridCellW, height: gridCellH - 4)
        }
        y += gridCellH
    }

    var themeObserver: NSObjectProtocol?

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

    func cellIndex(at point: NSPoint) -> Int? {
        guard contentViewport.contains(point) else { return nil }
        relayout()
        return cellFrames.first { $0.value.contains(point) }?.key
    }

    func headerTitle(at point: NSPoint) -> String? {
        guard contentViewport.contains(point) else { return nil }
        relayout()
        for block in blocks {
            guard case let .header(title, _) = block.kind else { continue }
            if block.frame.contains(point) { return title }
        }
        return nil
    }

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("文件浮窗列表")
    }

    required init?(coder: NSCoder) { fatalError() }
}
