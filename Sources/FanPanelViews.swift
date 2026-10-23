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

    func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
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

    var loggedUpdate = false

    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onExit?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls, convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// 底盘：真·系统玻璃。
///
/// macOS 26 起用 Liquid Glass 的 `.clear` 样式：几乎透明，背后的桌面会被折射、带边缘高光，
/// 比磨砂材质通透得多。更早的系统、或用户开了“降低透明度”时，退回原来的 `.popover` 磨砂。
/// 凝胶的边缘加厚、底部透光等细节由 SwiftUI 的 `FanView.backdrop` 叠在上面。
final class FanGlassBackdrop: NSView {
    private let glass: NSView
    var discDiameter: CGFloat = 0

    override init(frame: NSRect) {
        if #available(macOS 26.0, *), !Palette.reduceTransparency {
            let liquid = NSGlassEffectView()
            liquid.style = .clear
            liquid.tintColor = NSColor(Palette.brand).withAlphaComponent(0.10)
            glass = liquid
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            glass = effect
        }
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let diameter = discDiameter > 0 ? discDiameter : min(bounds.width, bounds.height)
        glass.frame = NSRect(x: (bounds.width - diameter) / 2,
                             y: (bounds.height - diameter) / 2,
                             width: diameter, height: diameter)
        if #available(macOS 26.0, *), let liquid = glass as? NSGlassEffectView {
            liquid.cornerRadius = diameter / 2
        } else {
            glass.layer?.cornerRadius = diameter / 2
        }
    }
}

final class FanPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

