import AppKit
import Quartz

extension ShelfCanvas {
    // MARK: 绘制

    /// 文件内容只在固定标题栏和底栏之间绘制，命中范围使用同一矩形。
    var contentViewport: NSRect {
        NSRect(x: 0, y: headerHeight, width: bounds.width,
               height: max(0, bounds.height - headerHeight - footerHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        relayout()
        // 底色比之前更实：系统材质本身偏灰，盖得太薄会和主窗口的浅绿底色不是一个色调
        NSColor(Palette.surface).withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        NSColor(Palette.brand).withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: contentViewport).addClip()
        drawBlocks()
        drawRubberBand()
        NSGraphicsContext.restoreGraphicsState()
        drawHeader()
        drawFooter()
    }

    // MARK: 标题栏控件

    var pinRect: CGRect { CGRect(x: bounds.width - 124, y: 6, width: 26, height: 20) }
    var viewModeRect: CGRect { CGRect(x: bounds.width - 156, y: 6, width: 26, height: 20) }
    var helpRect: CGRect { CGRect(x: padding + 30, y: 6, width: 18, height: 20) }

    func drawPinButton() {
        let rect = pinRect
        (isPinned ? NSColor(Palette.brand).withAlphaComponent(0.85)
                  : NSColor(Palette.surface).withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let pinned = isPinned
        if let symbol = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                accessibilityDescription: pinned ? "取消钉住" : "钉住文件浮窗") {
            let tinted = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
                symbol.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
                (pinned ? NSColor.white : NSColor(Palette.brand)).set()
                NSRect(x: 0, y: 0, width: 12, height: 12).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12))
        }
    }

    func drawViewModeButton() {
        let rect = viewModeRect
        NSColor(Palette.surface).withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let name = viewMode == .grid ? "list.bullet" : "square.grid.2x2"
        if let symbol = NSImage(systemSymbolName: name,
                                accessibilityDescription: viewMode == .grid ? "切换为列表" : "切换为网格") {
            let tinted = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
                symbol.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
                NSColor(Palette.brand).set()
                NSRect(x: 0, y: 0, width: 12, height: 12).fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12))
        }
    }

    func drawHelpButton() {
        let rect = helpRect
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(Palette.brand).withAlphaComponent(0.85),
        ]
        ("?" as NSString).draw(in: CGRect(x: rect.minX + 3, y: rect.minY + 2, width: rect.width, height: 16),
                               withAttributes: style)
    }

    func drawFooter() {
        let base = selection.isEmpty
            ? "\(files.count) 个文件 · 空格预览"
            : "已选 \(selection.count) / \(files.count)"
        let line = notice ?? base
        (line as NSString).draw(
            in: CGRect(x: padding, y: bounds.height - footerHeight + 5,
                       width: max(40, bounds.width - padding - 156), height: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                             .foregroundColor: notice == nil ? NSColor.tertiaryLabelColor : NSColor(Palette.textSecondary)])

        if canUndo {
            ("撤销" as NSString).draw(in: undoLinkRect.insetBy(dx: 8, dy: 4),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                      .foregroundColor: NSColor(Palette.brand)])
        }
        let title = isCompact ? "展开" : "紧凑"
        (title as NSString).draw(in: compactRect.insetBy(dx: 16, dy: 4),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                                                  .foregroundColor: NSColor(Palette.textSecondary)])
    }

    func drawHeader() {
        ("浮窗" as NSString).draw(at: NSPoint(x: padding, y: 9), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(Palette.textPrimary),
        ])
        ("＋" as NSString).draw(at: NSPoint(x: bounds.width - 56, y: 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(Palette.brand),
        ])
        drawHelpButton()
        drawViewModeButton()
        drawPinButton()
        if canUndo {
            ("↶" as NSString).draw(at: NSPoint(x: bounds.width - 87, y: 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor(Palette.brand),
            ])
        }

        let close = "✕" as NSString
        let size = close.size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold)])
        close.draw(at: NSPoint(x: bounds.width - padding - size.width, y: 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    func drawBlocks() {
        guard !files.isEmpty else {
            let hint = "把文件拖进来" as NSString
            let size = hint.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.midY - 8),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                       .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }

        for block in blocks {
            switch block.kind {
            case .header(let title, let count):
                let arrow = collapsed.contains(title) ? "▸" : "▾"
                let text = "\(arrow) \(title) \(count)" as NSString
                text.draw(at: NSPoint(x: padding, y: block.frame.minY + 5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor(Palette.textSecondary),
                ])
            case .cells(let indices):
                for index in indices {
                    guard let frame = cellFrames[index], files.indices.contains(index) else { continue }
                    drawCell(index: index, frame: frame)
                }
            }
        }
    }

    func drawCell(index: Int, frame: CGRect) {
        let url = files[index]
        let selected = selection.contains(index)
        let snapshot = snapshots[url.path]

        if selected {
            let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
            NSColor(Palette.brand).withAlphaComponent(0.20).setFill()
            path.fill()
            NSColor(Palette.brand).withAlphaComponent(0.68).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if viewMode == .list {
            drawListCell(url: url, snapshot: snapshot, frame: frame, selected: selected)
        } else {
            drawGridCell(url: url, snapshot: snapshot, frame: frame, selected: selected)
        }
    }

    /// 主摘要 + 次摘要：图片给分辨率/大小，视频加时长，PDF 页数，音频时长
    func summaryLines(_ snapshot: FileMetadataSnapshot?) -> (primary: String, secondary: String) {
        guard let snapshot else { return ("", "") }
        let secondary = [snapshot.formatName, snapshot.sizeText]
            .compactMap { $0 }
            .joined(separator: " · ")

        if snapshot.isVideo {
            let parts = [snapshot.resolutionText, snapshot.durationText].compactMap { $0 }
            return (parts.joined(separator: " · "), secondary)
        }
        if snapshot.isImage {
            return (snapshot.resolutionText ?? "", secondary)
        }
        if let pages = snapshot.pageCount {
            return ("\(pages) 页", secondary)
        }
        if let duration = snapshot.durationText {
            return (duration, secondary)
        }
        return ("", secondary)
    }

    func drawThumbnail(_ url: URL, in rect: CGRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(Palette.surface).withAlphaComponent(0.55).setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let thumbnail = thumbnails[url.path] {
            let size = NSSize(width: thumbnail.width, height: thumbnail.height)
            var target = rect
            let scale = max(rect.width / size.width, rect.height / size.height)
            target.size = NSSize(width: size.width * scale, height: size.height * scale)
            target.origin = NSPoint(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2)
            NSImage(cgImage: thumbnail, size: size).draw(in: target, from: .zero,
                                                         operation: .sourceOver, fraction: 1,
                                                         respectFlipped: true, hints: nil)
        } else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let side = min(rect.width, rect.height) * 0.62
            icon.size = NSSize(width: side, height: side)
            icon.draw(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1.0,
                      respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawGridCell(url: URL, snapshot: FileMetadataSnapshot?, frame: CGRect, selected: Bool) {
        let inset: CGFloat = 5
        let thumbHeight: CGFloat = 62
        drawThumbnail(url, in: CGRect(x: frame.minX + inset, y: frame.minY + inset,
                                      width: frame.width - inset * 2, height: thumbHeight),
                      radius: 8)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        (url.lastPathComponent as NSString).draw(
            in: CGRect(x: frame.minX + 3, y: frame.minY + 71, width: frame.width - 6, height: 24),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor(Palette.textPrimary).withAlphaComponent(selected ? 1 : 0.88),
                .paragraphStyle: style,
            ])

        // 视频：分辨率一行 + 时长/大小一行；其它：主信息 + 格式·大小
        let lines: (String, String)
        if snapshot?.isVideo == true, let resolution = snapshot?.resolutionText {
            let second = [snapshot?.durationText, snapshot?.sizeText].compactMap { $0 }.joined(separator: " · ")
            lines = (resolution, second)
        } else {
            lines = summaryLines(snapshot)
        }
        let summary = [lines.0, lines.1].filter { !$0.isEmpty }.joined(separator: "\n")
        if !summary.isEmpty {
            (summary as NSString).draw(
                in: CGRect(x: frame.minX + 3, y: frame.minY + 96, width: frame.width - 6, height: 30),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor(Palette.textSecondary),
                    .paragraphStyle: style,
                ])
        }
    }

    func drawListCell(url: URL, snapshot: FileMetadataSnapshot?, frame: CGRect, selected: Bool) {
        let side: CGFloat = 38
        drawThumbnail(url, in: CGRect(x: frame.minX + 6, y: frame.midY - side / 2, width: side, height: side),
                      radius: 6)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textX = frame.minX + 6 + side + 9
        let textWidth = frame.maxX - textX - 6

        (url.lastPathComponent as NSString).draw(
            in: CGRect(x: textX, y: frame.minY + 8, width: textWidth, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor(Palette.textPrimary).withAlphaComponent(selected ? 1 : 0.9),
                .paragraphStyle: style,
            ])

        let lines = summaryLines(snapshot)
        if !lines.primary.isEmpty {
            (lines.primary as NSString).draw(
                in: CGRect(x: textX, y: frame.minY + 26, width: textWidth, height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor(Palette.textSecondary),
                                 .paragraphStyle: style])
        }
        if !lines.secondary.isEmpty {
            (lines.secondary as NSString).draw(
                in: CGRect(x: textX, y: frame.minY + 41, width: textWidth, height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor(Palette.textSecondary).withAlphaComponent(0.85),
                                 .paragraphStyle: style])
        }
    }

    func drawRubberBand() {
        guard !rubberRect.isEmpty else { return }
        let path = NSBezierPath(rect: rubberRect)
        NSColor(Palette.brand).withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor(Palette.brand).withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

}
