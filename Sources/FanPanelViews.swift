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

final class FanPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

