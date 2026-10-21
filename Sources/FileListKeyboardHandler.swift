import AppKit
import SwiftUI

/// 文件列表只在自己的键盘承接视图持有焦点时接管按键，不抢占按钮、输入框或其他窗口。
enum FileListKeyAction: Equatable {
    case preview, remove, selectAll, clear, move(Int, extend: Bool)

    /// 只处理本列表承诺的按键，其他组合继续交给系统菜单与控件。
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> FileListKeyAction? {
        let keys = modifiers.intersection([.command, .shift, .control, .option])
        switch keyCode {
        case 49: return keys.isEmpty ? .preview : nil
        case 51, 117: return keys.isEmpty || keys == .command ? .remove : nil
        case 0: return keys == .command ? .selectAll : nil
        case 53: return keys.isEmpty ? .clear : nil
        case 123, 126: return keys.isEmpty || keys == .shift ? .move(-1, extend: keys == .shift) : nil
        case 124, 125: return keys.isEmpty || keys == .shift ? .move(1, extend: keys == .shift) : nil
        default: return nil
        }
    }
}

/// 范围锚点与活动项分开保存，反向 Shift 方向键可以收缩选择。
struct FileListSelection {
    var ids: Set<UUID> = []
    var anchor: UUID?
    var lead: UUID?

    mutating func select(_ id: UUID, order: [UUID], extend: Bool = false, toggle: Bool = false) {
        guard let target = order.firstIndex(of: id) else { return }
        if extend, let start = anchor.flatMap({ order.firstIndex(of: $0) }) {
            let range = Set(order[min(start, target)...max(start, target)])
            ids = toggle ? ids.union(range) : range
        } else {
            if toggle {
                if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            } else { ids = [id] }
            anchor = id
        }
        lead = id
    }

    mutating func move(_ step: Int, order: [UUID], extend: Bool) -> UUID? {
        guard !order.isEmpty else { return nil }
        let selected = order.indices.filter { ids.contains(order[$0]) }
        let anchorIndex = anchor.flatMap { order.firstIndex(of: $0) }
        let survivingLead = selected.max { abs($0 - (anchorIndex ?? $0)) < abs($1 - (anchorIndex ?? $1)) }
        let current = extend
            ? (lead.flatMap { order.firstIndex(of: $0) } ?? survivingLead)
            : (step > 0 ? selected.last : selected.first)
        let index = min(order.count - 1, max(0, (current ?? (step > 0 ? -1 : order.count)) + step))
        select(order[index], order: order, extend: extend)
        return order[index]
    }

    mutating func clear() { ids.removeAll(); anchor = nil; lead = nil }
    mutating func selectAll(_ order: [UUID]) { ids = Set(order); anchor = order.first; lead = order.last }
    mutating func prune(_ order: [UUID]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
        if let lead, !order.contains(lead) { self.lead = nil }
    }
}

struct FileListKeyboardHandler: NSViewRepresentable {
    var focusRequest: Int
    var onTab: (Bool) -> Void
    var handle: (FileListKeyAction) -> Void

    func makeNSView(context: Context) -> SpaceView { SpaceView() }

    func updateNSView(_ view: SpaceView, context: Context) {
        view.handle = handle
        view.onTab = onTab
        if focusRequest != view.focusRequest {
            view.focusRequest = focusRequest
            // 等 SwiftUI 同一轮焦点绑定更新结束，再承接列表按键。
            DispatchQueue.main.async { [weak view] in
                guard let view, view.focusRequest == focusRequest,
                      view.window?.isKeyWindow == true else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ view: SpaceView, coordinator: ()) { view.stop() }

    final class SpaceView: NSView {
        var focusRequest = 0
        var handle: ((FileListKeyAction) -> Void)?
        var onTab: ((Bool) -> Void)?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      self.window?.isKeyWindow == true, self.window?.firstResponder === self,
                      let action = FileListKeyAction.action(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
                self.handle?(action)
                return nil
            }
        }

        /// Tab 交给界面中的明确控件，避免背景承接视图在原生循环中选回自己。
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48 {
                window?.makeFirstResponder(nil)
                onTab?(event.modifierFlags.contains(.shift))
            } else { super.keyDown(with: event) }
        }

        /// 从视图层级移除时释放本地监听，避免空列表仍接收快捷键。
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
