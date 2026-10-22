import AppKit
import Quartz

extension ShelfCanvas {
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

    func dragPreviewFrame(for frame: CGRect) -> CGRect {
        if viewMode == .list {
            return CGRect(x: frame.minX + 6, y: frame.midY - 19, width: 38, height: 38)
        }
        return CGRect(x: frame.midX - 23, y: frame.minY + 4, width: 46, height: 46)
    }

    func beginDrag(with event: NSEvent) {
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

    func toggleQuickLook() {
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

    @objc func menuQuickLook() { toggleQuickLook() }

    @objc func menuReveal() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func menuRemove() { removeSelected() }

    @objc func menuClear() { clear() }

    @objc func menuUndo() { undo() }

    // MARK: 拖入

    override func resetCursorRects() {
        super.resetCursorRects()
        if !files.isEmpty {
            addCursorRect(pinRect.insetBy(dx: -3, dy: -3), cursor: .pointingHand)
        }
    }

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
