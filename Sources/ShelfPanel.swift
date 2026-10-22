import AppKit
import Quartz

final class ShelfPanel: NSPanel {
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

final class ShelfAXElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}
