import AppKit
import SwiftUI

// MARK: - 承接拖放的宿主视图

final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onHoverPoint: ((NSPoint) -> Void)?
    var onDropFiles: (([URL], NSPoint) -> Void)?
    var onDragEnterFiles: (([URL]) -> Void)?
    var onExit: (() -> Void)?
    var onClickPoint: ((NSPoint) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    override func mouseUp(with event: NSEvent) {
        onClickPoint?(convert(event.locationInWindow, from: nil))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(sender)
        if !urls.isEmpty { onDragEnterFiles?(urls) }
        onHoverPoint?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let local = convert(sender.draggingLocation, from: nil)
        onHoverPoint?(local)
        if !loggedUpdate {
            loggedUpdate = true
            DiagLog.write("draggingUpdated first at=(\(Int(local.x)),\(Int(local.y)))")
        }
        return .copy
    }

    private var loggedUpdate = false

    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onExit?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls, convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// 底盘：真·系统毛玻璃（原版用 NSVisualEffectView，不是 SwiftUI 材质近似）
final class FanGlassBackdrop: NSView {
    private let effect = NSVisualEffectView()
    var discDiameter: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        addSubview(effect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let diameter = discDiameter > 0 ? discDiameter : min(bounds.width, bounds.height)
        let rect = NSRect(x: (bounds.width - diameter) / 2,
                          y: (bounds.height - diameter) / 2,
                          width: diameter, height: diameter)
        effect.frame = rect
        effect.layer?.cornerRadius = diameter / 2
    }
}

final class FanPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制器

@MainActor
final class FanController {
    static let shared = FanController()

    let model = FanModel()

    private let monitor = DragMonitor()
    private var panel: FanPanel?

    private var wheelVisible = false
    private var dropHandled = false
    /// Esc 取消后，本次按住不再允许重新展开；必须等鼠标抬起
    private var suppressUntilMouseUp = false
    private var dragAnchor: NSPoint?
    private var activeMode: FanMode = .convert
    private var cachedURLs: [URL] = []
    /// 一次呼出期间固定格式及顺序；包括切轮与重新进入拖放区域。
    private var favoriteSnapshot: [FileKind: [OutputFormat]] = [:]
    private var sawButtonDown = false
    private var visibleSince: Date?
    private var wheelCenter: NSPoint?
    private var backgroundView: FanGlassBackdrop?
    private var hostView: NSView?
    private var localKeyMonitor: Any?
    private var keyboardPointer: NSPoint?

    private init() {
        monitor.onTick = { [weak self] buttonDown, modifiers in
            self?.tick(buttonDown: buttonDown, modifiers: modifiers, at: NSEvent.mouseLocation)
        }
        monitor.onKey = { [weak self] code in
            self?.handleKey(code)
        }
    }

    // 自检用
    var debugVisible: Bool { wheelVisible }
    var debugMode: FanMode { activeMode }
    var debugItems: Int { model.items.count }
    /// 模拟一次成功拖放（performDragOperation 里会置位），用于回归测试
    func debugMarkDropped() { dropHandled = true }
    var debugSuppressedUntilMouseUp: Bool { suppressUntilMouseUp }
    var debugAnimationKeys: [String] { panel?.contentView?.layer?.animationKeys() ?? [] }
    var debugLayer: CALayer? { panel?.contentView?.layer }
    var debugWheelCenter: NSPoint? { wheelCenter }
    var debugCenterSnapshot: NSPoint? { wheelCenter }
    var debugApplyCount = 0
    private(set) var debugMoreRequests = 0
    func debugPopulate(_ urls: [URL]) { populate(urls: urls) }
    var debugSuppressActions = false
    func debugSetURLs(_ urls: [URL]) { cachedURLs = urls }
    var debugHighlighted: Int? { model.highlighted }

    // MARK: 生命周期

    func prepare() { _ = panel ?? makePanel() }

    func startMonitoring() {
        _ = monitor.start()
        guard localKeyMonitor == nil else { return }
        // 全局键盘监听不接收本应用的事件；菜单打开的滚轮也要能导航和取消。
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.wheelVisible, self.menuPresentation,
                      [UInt16(53), 123, 124, 125, 126, 36, 76].contains(event.keyCode),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                self.handleKey(event.keyCode)
                return true
            }
            return handled ? nil : event
        }
    }
    func stopMonitoring() {
        monitor.stop()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
    }

    // MARK: 核心状态机（每次 tick 只依赖状态查询，不做事件假设）

    private var menuPresentation = false

    func tick(buttonDown: Bool, modifiers: FanModifiers, at point: NSPoint) {
        // 取消后同一次按住里继续移动不应重开/执行
        if suppressUntilMouseUp {
            if buttonDown { return }
            suppressUntilMouseUp = false
        }

        let wheel = mode(for: modifiers)

        // 滚轮已展开：跟手高亮、松手收起、换键切轮
        if wheelVisible {
            if let since = visibleSince, Date().timeIntervalSince(since) > 20 {
                hide()
                return
            }
            if !buttonDown {
                // 菜单打开时用户通常没按鼠标：只跟随高亮，不自动执行
                if menuPresentation {
                    if let origin = keyboardPointer, hypot(point.x - origin.x, point.y - origin.y) > 2 {
                        keyboardPointer = nil
                    }
                    if keyboardPointer == nil { updateHighlight(at: point) }
                    return
                }
                if let index = model.highlighted, model.items.indices.contains(index) {
                    // 拖放的 drop 事件有时收不到（拖影没跟过来、窗口刚移动过等），
                    // 这里用缓存的文件列表兜底，保证「选了就一定执行」。
                    if !dropHandled {
                        let urls = cachedURLs.isEmpty ? dragURLs() : cachedURLs
                        DiagLog.write("fallback apply #\(index) urls=\(urls.count)")
                        apply(model.items[index], urls: urls)
                    }
                } else {
                    DiagLog.write("cancel (落在中心/空隙)")
                }
                hide()
                return
            }
            updateHighlight(at: point)
            if let wheel, wheel != activeMode { refresh(mode: wheel) }
            return
        }

        if buttonDown { menuPresentation = false }   // 真实拖动接管

        // 没有「按键 + 按下鼠标」就重置锚点
        guard buttonDown, let wheel else {
            dragAnchor = nil
            sawButtonDown = buttonDown
            return
        }

        if dragAnchor == nil {
            dragAnchor = point
            return
        }

        guard let anchor = dragAnchor else { return }
        guard hypot(point.x - anchor.x, point.y - anchor.y) > 6 else { return }
        present(mode: wheel, at: anchor)
    }

    /// 自检用：以菜单呈现模式打开（不依赖访达选中）
    func debugPresentMenuMode(urls: [URL]) {
        presentMenu(urls: urls, mode: .convert)
    }

    var debugWheelVisible: Bool { wheelVisible }

    /// 自检用：模拟在菜单模式下点某一瓣
    func debugClick(at index: Int) {
        guard wheelVisible, menuPresentation, !dropHandled,
              model.items.indices.contains(index) else { return }
        dropHandled = true
        apply(model.items[index], urls: cachedURLs)
        hide()
    }

    /// 自检用：直接以拖拽模式呈现
    func debugPresentDrag(urls: [URL]) {
        dropHandled = false
        keyboardPointer = nil
        cachedURLs = urls
        favoriteSnapshot.removeAll()
        activeMode = .convert
        let list = items(for: .convert, urls: urls)
        guard !list.isEmpty else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.configure(mode: .convert, items: list, fileCount: urls.count)
        model.appeared = true
        model.bloom = 1
        position(panel, at: NSEvent.mouseLocation)
        panel.orderFrontRegardless()
        wheelVisible = true
        menuPresentation = false
        visibleSince = Date()
    }

    func debugHighlight(_ index: Int) { model.highlighted = index }
    func debugKey(_ code: UInt16) { handleKey(code) }
    var debugMenuMode: Bool { menuPresentation }

    /// 键盘导航：只有拿到键盘权限时才收得到，收不到也不影响
    private func handleKey(_ code: UInt16) {
        guard wheelVisible else { return }
        switch code {
        case 53:
            suppressUntilMouseUp = true
            hide(); dropHandled = true
        case 123, 126:
            model.step(-1)
            if menuPresentation { keyboardPointer = NSEvent.mouseLocation }
        case 124, 125:
            model.step(1)
            if menuPresentation { keyboardPointer = NSEvent.mouseLocation }
        case 36, 76:
            if let index = model.highlighted, model.items.indices.contains(index) {
                apply(model.items[index], urls: cachedURLs)
                hide()
                dropHandled = true
            }
        default:
            break
        }
    }

    private func mode(for modifiers: FanModifiers) -> FanMode? {
        KeyMap.resolvedMode(for: modifiers)
    }

    // MARK: 文件

    private func dragURLs() -> [URL] {
        let board = NSPasteboard(name: .drag)
        let urls = (board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func items(for mode: FanMode, urls: [URL]) -> [FanItem] {
        switch mode {
        case .convert:
            guard let first = urls.first else { return [] }
            let kind = FormatCatalog.kind(of: first)
            let pinned = favoriteSnapshot[kind] ?? FavoriteFormats.formats(for: kind)
            favoriteSnapshot[kind] = pinned
            // 快照保存的是原始常用顺序；按本次文件能产出的格式过滤，避免出现必然失败的花瓣。
            let allowed = FormatCatalog.formats(for: kind, sources: urls)
            var shown = pinned.filter { allowed.contains($0) }
            if shown.isEmpty { shown = allowed }   // 常用格式都不适用时（如 PDF 只能转 HTML）直接列出可用项
            var result = shown.map { FanItem.format($0) }
            if shown.count < allowed.count { result.append(.moreFormats(kind)) }
            return result
        case .tools:
            let kind = urls.first.map { FormatCatalog.kind(of: $0) } ?? .unknown
            let ext = urls.first?.pathExtension.lowercased() ?? ""
            return ToolKind.allCases
                .filter { tool in
                    switch tool {
                    case .cropImage, .redactImage, .compressImage, .rotateRight, .resizeSmall, .stripMetadata, .qrText:
                        return kind == .image
                    case .toPDF:
                        return kind == .image || kind == .document
                    case .splitPDF:
                        return ext == "pdf"
                    case .mergePDF:
                        return !urls.isEmpty && urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
                    case .trimMedia:
                        return kind == .media
                    case .zipArchive:
                        return true
                    }
                }
                .map { .tool($0) }
        case .actions:
            return ActionKind.allCases.map { .action($0) }
        }
    }

    // MARK: 显示

    private func present(mode: FanMode, at anchor: NSPoint) {
        guard !wheelVisible else { return }

        menuPresentation = false
        dropHandled = false
        cachedURLs = dragURLs()
        favoriteSnapshot.removeAll()
        let list = items(for: mode, urls: cachedURLs)
        activeMode = mode

        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.configure(mode: mode, items: list, fileCount: cachedURLs.count)
        model.loadImpactSources(cachedURLs)
        if let first = cachedURLs.first {
            model.fileIcon = NSWorkspace.shared.icon(forFile: first.path)
            model.fileLabel = first.pathExtension.uppercased()
        }
        wheelCenter = anchor
        position(panel, at: anchor)

        // 先以全透明出现，强制提交一帧（此时 content 还是 appeared=false 的初始态），
        // 下一帧再播 spring + 淡入。否则 SwiftUI 会把两次状态合并，直接呈现终态。
        raiseAboveDrag(panel)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        wheelVisible = true
        visibleSince = Date()
        // 下一轮再挂动画：窗口还没上屏时挂上去，CA 会把动画丢掉
        DispatchQueue.main.async { [weak self] in self?.animateEntrance() }

        DiagLog.write("present mode=\(mode) files=\(cachedURLs.count) items=\(list.count) at=(\(Int(anchor.x)),\(Int(anchor.y)))")
    }

    private func refresh(mode: FanMode) {
        activeMode = mode
        let list = items(for: mode, urls: cachedURLs)
        guard !list.isEmpty else { return }
        model.configure(mode: mode, items: list, fileCount: cachedURLs.count)
        // 常用轮与工具轮数量不同，同步窗口尺寸与轮心，避免新花瓣超出旧面板。
        if let panel {
            position(panel, at: wheelCenter ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        }
        if let first = cachedURLs.first {
            model.fileIcon = NSWorkspace.shared.icon(forFile: first.path)
            model.fileLabel = first.pathExtension.uppercased()
        }
        DispatchQueue.main.async { [weak self] in self?.model.playEntrance() }
    }

    private func populate(urls: [URL]) {
        cachedURLs = urls
        let list = items(for: activeMode, urls: urls)
        guard !list.isEmpty else { return }
        model.configure(mode: activeMode, items: list, fileCount: urls.count)
        model.loadImpactSources(urls)
        if let panel {
            position(panel, at: wheelCenter ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        }
        model.appeared = true
        DiagLog.write("populate files=\(urls.count) items=\(list.count)")
    }

    /// 面板尺寸 = 内容尺寸，这样 AppKit 不需要做居中，中心必然落在 anchor 上
    /// 照搬原版的机制：NSAnimationContext 里挂 CABasicAnimation（缩放 + 淡入），
    /// 带轻微回弹的 timing function。不用 SwiftUI 隐式动画，避免状态被合并。
    private func animateEntrance() {
        model.playEntrance()          // 花瓣错峰时间轴
        guard let host = panel?.contentView else { return }
        host.wantsLayer = true
        guard let layer = host.layer else { return }

        layer.removeAllAnimations()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.82
        scale.toValue = 1.0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.32
        // 0.16 / 1.24 让收尾有一点过冲，就是那种"弹出来"的手感
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.24, 0.42, 1.0)
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = group.duration
            context.allowsImplicitAnimation = false
            layer.add(group, forKey: "fan.entrance")
        }

        DiagLog.write("entrance keys=\(layer.animationKeys() ?? [])")

        // 60ms 后回报渲染中的真实值，用来区分"没播"和"播了但看不出来"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak layer] in
            let pres = layer?.presentation()
            let scale = pres?.value(forKeyPath: "transform.scale") as? Double
            let opacity = pres?.opacity
            DiagLog.write(String(format: "entrance@60ms scale=%@ opacity=%@",
                                 (scale.map { String(format: "%.3f", $0) } ?? "nil") as NSString,
                                 (opacity.map { String(format: "%.2f", $0) } ?? "nil") as NSString))
        }
    }

    private func position(_ panel: NSPanel, at point: NSPoint) {
        let size = model.canvas
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: size, height: size)
        backgroundView?.discDiameter = model.radius * 2 + 26
        backgroundView?.needsLayout = true
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: false)
    }

    /// 系统拖影所在的层级；+1 让轮盘（含爪子）压在文件拖影之上
    static let aboveDragLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.draggingWindow)) + 1
    )

    private func raiseAboveDrag(_ panel: NSPanel) {
        panel.level = Self.aboveDragLevel
    }

    private func makePanel() -> FanPanel {
        let panel = FanPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.canvas, height: model.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let container = FanGlassBackdrop(frame: NSRect(x: 0, y: 0, width: model.canvas, height: model.canvas))
        container.discDiameter = model.radius * 2 + 26

        let host = DropHostingView(rootView: FanView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.onHoverPoint = { [weak self] point in
            guard let self else { return }
            let index = self.model.petalIndex(at: point)
            if index != self.model.highlighted { self.model.highlighted = index }
        }
        host.onExit = { [weak self] in self?.model.highlighted = nil }
        host.onClickPoint = { [weak self] point in
            guard let self, self.wheelVisible, self.menuPresentation else { return }
            let index = self.model.petalIndex(at: point)
            guard let index, self.model.items.indices.contains(index) else { return }
            guard !self.dropHandled else { return }
            self.dropHandled = true
            self.apply(self.model.items[index], urls: self.cachedURLs)
            self.hide()
        }
        host.onDragEnterFiles = { [weak self] urls in self?.populate(urls: urls) }
        host.onDropFiles = { [weak self] urls, point in
            guard let self else { return }
            DiagLog.write("drop urls=\(urls.count) at=(\(Int(point.x)),\(Int(point.y)))")
            self.dropHandled = true
            if let index = self.model.petalIndex(at: point), self.model.items.indices.contains(index) {
                self.apply(self.model.items[index], urls: urls)
            }
            self.hide()
        }
        // 缩放动画要从中心长出来，NSView 的 backing layer 默认锚点在左下
        host.wantsLayer = true
        if let layer = host.layer {
            let bounds = host.bounds
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        container.addSubview(host)
        panel.contentView = container
        self.backgroundView = container
        self.hostView = host
        return panel
    }

    /// 自己算悬停，不用拖放事件：拖拽期间光标位置每 tick 都能拿到
    private func updateHighlight(at screenPoint: NSPoint) {
        guard let panel, let host = hostView else { return }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let local = host.convert(windowPoint, from: nil)
        model.updatePointer(local)
        let index = model.petalIndex(at: local)
        if index != model.highlighted {
            model.highlighted = index
            if let index, model.items.indices.contains(index) {
                DiagLog.write("hover #\(index) \(model.items[index].title) at=(\(Int(local.x)),\(Int(local.y)))")
            }
        }
    }

    func hide() {
        wheelVisible = false
        menuPresentation = false
        keyboardPointer = nil
        wheelCenter = nil
        dropHandled = false
        dragAnchor = nil
        sawButtonDown = false
        visibleSince = nil
        favoriteSnapshot.removeAll()
        model.highlighted = nil
        model.resetPaw()   // 指针清空 → 爪子收回
        model.clearImpactSources()
        model.appeared = false
        panel?.alphaValue = 1
        panel?.level = .floating
        panel?.orderOut(nil)
    }

    // MARK: 执行

    private func apply(_ item: FanItem, urls: [URL]) {
        DiagLog.write("apply \(item.title) urls=\(urls.count) first=\(urls.first?.lastPathComponent ?? "-")")
        debugApplyCount += 1
        if case .moreFormats = item { debugMoreRequests += 1 }
        if debugSuppressActions { return }
        guard !urls.isEmpty else {
            DiagLog.write("apply 被跳过：没有文件")
            return
        }
        switch item {
        case .format(let format):
            ConversionRunner.run(urls: urls, format: format)

        case .tool(let tool):
            ToolRunner.run(urls: urls, tool: tool)

        case .action(let action):
            ActionRunner.run(urls: urls, action: action)
        case .moreFormats:
            // 先让当前松手/菜单事件完成并收起花瓣，再显示选择器；此处不执行转换。
            DispatchQueue.main.async { MoreFormatsWindow.shared.present(urls: urls) }
        }
    }

    // MARK: 菜单栏

    /// 菜单栏入口：等用户点选，不随「没有按住鼠标」立刻取消
    func showAtMouse(mode: FanMode = .convert) {
        let urls = selectedFinderFiles()
        guard !urls.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "没有选中文件"
            alert.informativeText = "先在访达里选中文件，再从菜单栏打开滚轮。"
            alert.runModal()
            return
        }
        presentMenu(urls: urls, mode: mode)
    }

    func showMenu(mode: FanMode, urls: [URL]) {
        presentMenu(urls: urls, mode: mode)
    }

    private func presentMenu(urls: [URL], mode: FanMode) {
        favoriteSnapshot.removeAll()
        let list = items(for: mode, urls: urls)
        guard !list.isEmpty else { return }
        cachedURLs = urls
        activeMode = mode
        menuPresentation = true
        keyboardPointer = nil
        dropHandled = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.configure(mode: mode, items: list, fileCount: urls.count)
        model.loadImpactSources(urls)
        if let first = urls.first {
            model.fileIcon = NSWorkspace.shared.icon(forFile: first.path)
            model.fileLabel = first.pathExtension.uppercased()
        }
        wheelCenter = NSEvent.mouseLocation
        position(panel, at: NSEvent.mouseLocation)
        raiseAboveDrag(panel)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        wheelVisible = true
        visibleSince = Date()
        DispatchQueue.main.async { [weak self] in self?.animateEntrance() }
    }

    func presentForProbe(urls: [URL], mode: FanMode) {
        cachedURLs = urls
        favoriteSnapshot.removeAll()
        activeMode = mode
        let list = items(for: mode, urls: urls)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.configure(mode: mode, items: list, fileCount: urls.count)
        position(panel, at: NSPoint(x: 600, y: 400))
        raiseAboveDrag(panel)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        wheelVisible = true
        visibleSince = Date()
        // 下一轮再挂动画：窗口还没上屏时挂上去，CA 会把动画丢掉
        DispatchQueue.main.async { [weak self] in self?.animateEntrance() }
    }

    /// 自检用：把面板内容截成 PNG（不需要屏幕录制权限）
    @discardableResult
    func debugCapture(to path: String) -> Bool {
        guard let panel, let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: URL(fileURLWithPath: path))
        print("panel frame=\(panel.frame)")
        print("content bounds=\(view.bounds)")
        print("model canvas=\(model.canvas) items=\(model.items.count)")
        return true
    }

    /// 自检用
    func showForDebug(mode: FanMode, urls: [URL]) {
        cachedURLs = urls
        favoriteSnapshot.removeAll()
        activeMode = mode
        let list = items(for: mode, urls: urls)
        guard !list.isEmpty else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.configure(mode: mode, items: list, fileCount: urls.count)
        model.appeared = true
        position(panel, at: NSEvent.mouseLocation)
        raiseAboveDrag(panel)
        panel.orderFrontRegardless()
        wheelVisible = true
    }

    private func selectedFinderFiles() -> [URL] {
        let script = """
        tell application "Finder" to try
            set sel to selection as alias list
            set out to ""
            repeat with f in sel
                set out to out & (POSIX path of f) & linefeed
            end repeat
            return out
        end try
        """
        guard let apple = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
