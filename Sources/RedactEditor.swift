import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// 涂黑 / 打码：拖出方框，覆盖成纯色。对应原版 Annotate Photo 的涂黑部分：
///  "Draw a rectangle over the area to hide."
@MainActor
final class RedactEditor {
    static let shared = RedactEditor()

    private var panel: NSPanel?

    func present(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            let alert = NSAlert()
            alert.messageText = "读不到这张图片"
            alert.runModal()
            return
        }

        let model = RedactModel(url: url, image: image)
        let content = RedactEditorView(
            model: model,
            onSave: { [weak self] in self?.save(model) },
            onCancel: { [weak self] in self?.panel?.orderOut(nil) }
        )
        panel?.orderOut(nil)
        let panel = PanelKit.make(title: "涂黑", size: NSSize(width: 780, height: 600), content: content)
        self.panel = panel
        PanelKit.present(panel)
    }

    private func save(_ model: RedactModel) {
        do {
            let output = try model.render()
            panel?.orderOut(nil)
            Feedback.success("已保存", outputs: [output], comparisons: [OutputComparison(source: model.url, output: output)])
        } catch {
            let alert = NSAlert()
            alert.messageText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            alert.runModal()
        }
    }
}

@MainActor
final class RedactModel: ObservableObject {
    enum AnnotateMode { case redact, brush }

    let url: URL
    let image: NSImage
    /// 归一化矩形（0-1，原点左上）
    @Published var rects: [CGRect] = []
    @Published var draft: CGRect?
    @Published var mode: AnnotateMode = .redact
    @Published var strokes: [[CGPoint]] = []
    @Published var currentStroke: [CGPoint] = []

    init(url: URL, image: NSImage) {
        self.url = url
        self.image = image
    }

    var pixelSize: CGSize {
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var canUndo: Bool { mode == .brush ? !strokes.isEmpty : !rects.isEmpty }

    func undo() {
        if mode == .brush {
            if !strokes.isEmpty { strokes.removeLast() }
        } else if !rects.isEmpty {
            rects.removeLast()
        }
    }

    func render() throws -> URL {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.failed("无法解码图片")
        }
        let width = cgImage.width, height = cgImage.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("无法创建画布")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(NSColor.black.cgColor)
        for rect in rects {
            // 归一化坐标（左上原点）→ 位图坐标（左下原点）
            let x = rect.minX * CGFloat(width)
            let w = rect.width * CGFloat(width)
            let h = rect.height * CGFloat(height)
            let y = CGFloat(height) - rect.minY * CGFloat(height) - h
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }

        // 自由画笔：线宽按图片宽度取比例，保证在不同分辨率下观感一致
        if !strokes.isEmpty {
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(max(2, CGFloat(width) * 0.006))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                context.beginPath()
                for (index, point) in stroke.enumerated() {
                    let pt = CGPoint(x: point.x * CGFloat(width),
                                     y: CGFloat(height) - point.y * CGFloat(height))
                    if index == 0 { context.move(to: pt) } else { context.addLine(to: pt) }
                }
                context.strokePath()
            }
        }

        guard let output = context.makeImage() else {
            throw ConversionError.failed("渲染失败")
        }

        let destination = OutputNaming.path(for: url, suffix: "-涂黑")
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .png
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL,
                                                        type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("无法写出图片")
        }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.failed("写出失败")
        }
        return destination
    }
}

struct RedactEditorView: View {
    @ObservedObject var model: RedactModel
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var dragStart: CGPoint?

    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: model.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                    ForEach(Array(model.rects.enumerated()), id: \.offset) { _, rect in
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: rect.width * fitted.width, height: rect.height * fitted.height)
                            .position(x: fitted.minX + (rect.midX) * fitted.width,
                                      y: fitted.minY + (rect.midY) * fitted.height)
                    }

                    ForEach(Array(model.strokes.enumerated()), id: \.offset) { _, stroke in
                        strokePath(stroke, in: fitted)
                            .stroke(Color.black, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    strokePath(model.currentStroke, in: fitted)
                        .stroke(Color.black.opacity(0.85),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    if let draft = model.draft {
                        Rectangle()
                            .fill(Color.black.opacity(0.75))
                            .overlay(Rectangle().strokeBorder(Palette.brand, lineWidth: 1.2))
                            .frame(width: draft.width * fitted.width, height: draft.height * fitted.height)
                            .position(x: fitted.minX + draft.midX * fitted.width,
                                      y: fitted.minY + draft.midY * fitted.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if model.mode == .redact {
                                let start = dragStart ?? value.startLocation
                                dragStart = start
                                model.draft = normalized(from: start, to: value.location, in: fitted)
                            } else {
                                if model.currentStroke.isEmpty {
                                    model.currentStroke.append(normalizePoint(value.startLocation, in: fitted))
                                }
                                let point = normalizePoint(value.location, in: fitted)
                                if model.currentStroke.last != point { model.currentStroke.append(point) }
                            }
                        }
                        .onEnded { value in
                            if model.mode == .redact {
                                let start = dragStart ?? value.startLocation
                                dragStart = nil
                                let rect = normalized(from: start, to: value.location, in: fitted)
                                model.draft = nil
                                if rect.width > 0.01 && rect.height > 0.01 {
                                    model.rects.append(rect)
                                }
                            } else {
                                if model.currentStroke.isEmpty {
                                    model.currentStroke.append(normalizePoint(value.startLocation, in: fitted))
                                }
                                let end = normalizePoint(value.location, in: fitted)
                                if model.currentStroke.last != end { model.currentStroke.append(end) }
                                if model.currentStroke.count > 1 {
                                    model.strokes.append(model.currentStroke)
                                }
                                model.currentStroke = []
                            }
                        }
                )
            }

            HStack(spacing: 8) {
                Picker("", selection: $model.mode) {
                    Text("涂黑").tag(RedactModel.AnnotateMode.redact)
                    Text("画笔").tag(RedactModel.AnnotateMode.brush)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)

                Text(model.mode == .redact ? "拖出方框即可涂黑，可叠加多个" : "按住拖动即可画线")
                    .font(.system(size: Palette.TypeSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("撤销") { model.undo() }
                    .disabled(!model.canUndo)
                Button("取消") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存") { onSave() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 540)
        .tint(Palette.brand)
        .background(Palette.surface)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let imageSize = model.image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func normalizePoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: max(0, min(1, (point.x - rect.minX) / rect.width)),
                       y: max(0, min(1, (point.y - rect.minY) / rect.height)))
    }

    private func strokePath(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let pt = CGPoint(x: rect.minX + point.x * rect.width,
                             y: rect.minY + point.y * rect.height)
            if index == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    private func normalized(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x0 = min(start.x, end.x), x1 = max(start.x, end.x)
        let y0 = min(start.y, end.y), y1 = max(start.y, end.y)
        let nx0 = max(0, (x0 - rect.minX) / rect.width)
        let nx1 = min(1, (x1 - rect.minX) / rect.width)
        let ny0 = max(0, (y0 - rect.minY) / rect.height)
        let ny1 = min(1, (y1 - rect.minY) / rect.height)
        return CGRect(x: nx0, y: ny0, width: max(0, nx1 - nx0), height: max(0, ny1 - ny0))
    }
}
