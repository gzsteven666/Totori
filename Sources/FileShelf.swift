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

