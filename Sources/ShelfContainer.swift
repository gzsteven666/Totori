import AppKit
import Quartz

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
