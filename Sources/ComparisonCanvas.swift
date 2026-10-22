import AppKit
import SwiftUI
import ImageIO
import Quartz

/// NSScrollView 保留触控板的横向/纵向滚动；归一化中心让两个不同尺寸的结果也能对齐检查。
enum ComparisonAnchor {
    /// 只有某个轴真的能滚动时，才从滚动位置回写该轴；否则保持原值。
    /// 重建视图/首帧布局时 viewport 与 imageRect 尚未成形，不能当作"滚到边上了"。
    static func afterScroll(viewport: CGRect, imageRect: CGRect, drawnSize: CGSize,
                            canvasSize: CGSize, current: CGPoint) -> CGPoint {
        guard imageRect.width > 1, imageRect.height > 1,
              drawnSize.width > 1, drawnSize.height > 1,
              canvasSize.width > 1, canvasSize.height > 1 else { return current }

        var x = current.x
        var y = current.y
        if canvasSize.width > viewport.width + 0.5 {
            x = (viewport.midX - imageRect.minX) / drawnSize.width
        }
        if canvasSize.height > viewport.height + 0.5 {
            y = (viewport.midY - imageRect.minY) / drawnSize.height
        }
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

enum ComparisonGeometry {
    /// 由画布坐标换算分界比例（含 imageRect 原点/居中/滚动偏移）
    static func fraction(atX x: CGFloat, imageRect: CGRect) -> CGFloat {
        guard imageRect.width > 0 else { return 0.5 }
        return min(1, max(0, (x - imageRect.minX) / imageRect.width))
    }

    static func cutX(fraction: CGFloat, imageRect: CGRect) -> CGFloat {
        imageRect.minX + imageRect.width * min(1, max(0, fraction))
    }

    /// 左（原图）/ 右（结果）裁切矩形
    static func clipRects(fraction: CGFloat, imageRect: CGRect) -> (left: CGRect, right: CGRect) {
        let cut = cutX(fraction: fraction, imageRect: imageRect)
        let left = CGRect(x: imageRect.minX, y: imageRect.minY,
                          width: max(0, cut - imageRect.minX), height: imageRect.height)
        let right = CGRect(x: cut, y: imageRect.minY,
                           width: max(0, imageRect.maxX - cut), height: imageRect.height)
        return (left, right)
    }
}

struct ComparisonImageScroll: NSViewRepresentable {
    var image: CGImage?
    var secondImage: CGImage?
    var originalSize: CGSize
    var scale: CGFloat
    var divider: CGFloat = 0.5
    var originalOnly: Bool = false
    var onDividerChange: ((CGFloat) -> Void)?
    @Binding var anchor: CGPoint

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComparisonScrollContainer()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        let canvas = ComparisonCanvas()
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        canvas.setAccessibilityLabel("图片预览")
        canvas.onDividerFraction = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.onDividerChange?(value)
        }
        scroll.documentView = canvas
        context.coordinator.observe(scroll)
        scroll.layoutChanged = { [weak coordinator = context.coordinator, weak scroll] in
            guard let scroll else { return }
            coordinator?.layout(scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.layout(scroll)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        var parent: ComparisonImageScroll
        var updating = false
        var lastAppliedOrigin: CGPoint?
        var laidOutSize: CGSize = .zero
        var observer: NSObjectProtocol?
        init(_ parent: ComparisonImageScroll) { self.parent = parent }
        func layout(_ scroll: NSScrollView) {
            guard let canvas = scroll.documentView as? ComparisonCanvas, !updating else { return }
            updating = true
            defer { updating = false }
            let viewport = scroll.contentSize
            let drawnSize = CGSize(width: max(1, parent.originalSize.width * parent.scale),
                                   height: max(1, parent.originalSize.height * parent.scale))
            canvas.image = parent.image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            canvas.secondImage = parent.secondImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            canvas.divider = parent.divider
            canvas.originalOnly = parent.originalOnly
            canvas.drawnSize = drawnSize
            canvas.setFrameSize(NSSize(width: max(viewport.width, drawnSize.width),
                                      height: max(viewport.height, drawnSize.height)))
            canvas.needsDisplay = true
            scroll.window?.invalidateCursorRects(for: canvas)
            let centered = CGPoint(x: canvas.imageRect.minX + parent.anchor.x * drawnSize.width - viewport.width / 2,
                                   y: canvas.imageRect.minY + parent.anchor.y * drawnSize.height - viewport.height / 2)
            let origin = CGPoint(x: min(max(0, centered.x), max(0, canvas.frame.width - viewport.width)),
                                 y: min(max(0, centered.y), max(0, canvas.frame.height - viewport.height)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            // 记下我们主动设置的滚动位置；它的异步回显不算用户滚动
            lastAppliedOrigin = scroll.contentView.bounds.origin
            laidOutSize = canvas.frame.size
        }
        func observe(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                              object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll, !self.updating,
                      (scroll as? ComparisonScrollContainer)?.isLayingOut != true,
                      let canvas = scroll.documentView as? ComparisonCanvas,
                      canvas.drawnSize.width > 1, canvas.drawnSize.height > 1,
                      canvas.frame.size == self.laidOutSize else { return }
                let currentOrigin = scroll.contentView.bounds.origin
                if let applied = self.lastAppliedOrigin,
                   abs(currentOrigin.x - applied.x) < 0.5,
                   abs(currentOrigin.y - applied.y) < 0.5 {
                    return   // 程序化滚动的回显
                }
                let point = ComparisonAnchor.afterScroll(
                    viewport: scroll.contentView.bounds,
                    imageRect: canvas.imageRect,
                    drawnSize: canvas.drawnSize,
                    canvasSize: canvas.frame.size,
                    current: self.parent.anchor)
                self.lastAppliedOrigin = currentOrigin
                if abs(point.x - self.parent.anchor.x) + abs(point.y - self.parent.anchor.y) > 0.0001 {
                    self.parent.anchor = point
                }
            }
        }
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { stop() }
    }
}

final class ComparisonScrollContainer: NSScrollView {
    var layoutChanged: (() -> Void)?
    var previousViewport = CGSize.zero
    private(set) var isLayingOut = false

    override func layout() {
        isLayingOut = true
        super.layout()
        isLayingOut = false
        if contentSize != previousViewport {
            previousViewport = contentSize
            layoutChanged?()
        }
    }
}

final class ComparisonCanvas: NSView {
    var image: NSImage?
    var secondImage: NSImage?
    var drawnSize = CGSize(width: 1, height: 1)
    var divider: CGFloat = 0.5
    var originalOnly = false
    var onDividerFraction: ((CGFloat) -> Void)?
    var draggingDivider = false
    override var isFlipped: Bool { true }
    var imageRect: CGRect {
        CGRect(x: (bounds.width - drawnSize.width) / 2, y: (bounds.height - drawnSize.height) / 2,
               width: drawnSize.width, height: drawnSize.height)
    }
    func drawContent(in dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let rect = imageRect.intersection(dirtyRect)
        if !rect.isEmpty { drawCheckerboard(rect) }

        func draw(_ image: NSImage?) {
            image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }

        // 单看原图，或没有可对比的第二张
        guard !originalOnly, let secondImage else {
            draw(image)
            return
        }

        // 左右各自裁切：结果透明处露出棋盘，而不是底下的原图
        let rects = ComparisonGeometry.clipRects(fraction: divider, imageRect: imageRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rects.left).addClip()
        draw(image)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rects.right).addClip()
        draw(secondImage)
        NSGraphicsContext.restoreGraphicsState()

        let cut = ComparisonGeometry.cutX(fraction: divider, imageRect: imageRect)
        NSColor(Palette.brand).setFill()
        NSRect(x: cut - 0.75, y: imageRect.minY, width: 1.5, height: imageRect.height).fill()
        NSBezierPath(ovalIn: CGRect(x: cut - 7, y: imageRect.midY - 7, width: 14, height: 14)).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawContent(in: dirtyRect)
    }

    func drawCheckerboard(_ rect: CGRect) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        let step: CGFloat = 12
        let xStart = Int(floor(rect.minX / step)), xEnd = Int(ceil(rect.maxX / step))
        let yStart = Int(floor(rect.minY / step)), yEnd = Int(ceil(rect.maxY / step))
        for y in yStart..<yEnd {
            for x in xStart..<xEnd where (x + y) % 2 == 0 {
                CGRect(x: CGFloat(x) * step, y: CGFloat(y) * step, width: step, height: step)
                    .intersection(rect).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cut = ComparisonGeometry.cutX(fraction: divider, imageRect: imageRect)
        draggingDivider = abs(point.x - cut) <= 14 && imageRect.insetBy(dx: -2, dy: -2).contains(point)
        if draggingDivider { onDividerFraction?(ComparisonGeometry.fraction(atX: point.x, imageRect: imageRect)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingDivider else { return }
        let point = convert(event.locationInWindow, from: nil)
        onDividerFraction?(ComparisonGeometry.fraction(atX: point.x, imageRect: imageRect))
    }

    override func mouseUp(with event: NSEvent) {
        draggingDivider = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !originalOnly, secondImage != nil else { return }
        let cut = ComparisonGeometry.cutX(fraction: divider, imageRect: imageRect)
        addCursorRect(CGRect(x: cut - 10, y: imageRect.minY, width: 20, height: imageRect.height),
                      cursor: .resizeLeftRight)
    }
}
