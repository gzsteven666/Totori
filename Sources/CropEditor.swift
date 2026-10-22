import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - 裁剪编辑器

@MainActor
final class CropEditor {
    static let shared = CropEditor()

    private var window: NSWindow?
    private var model: CropModel?

    func present(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            presentAlert("读不到这张图片：\(url.lastPathComponent)")
            return
        }

        let model = CropModel(url: url, image: image)
        self.model = model

        let window = self.window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: CropEditorView(
            model: model,
            onApply: { [weak self] in self?.apply() },
            onCancel: { [weak self] in self?.close() }
        ))
        window.setContentSize(NSSize(width: 720, height: 560))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "裁剪"
        window.level = .floating
        window.isReleasedWhenClosed = false
        return window
    }

    private func apply() {
        guard let model else { return }
        do {
            let output = try model.performCrop()
            close()
            Feedback.success("已保存", outputs: [output], comparisons: [OutputComparison(source: model.url, output: output)])
        } catch {
            presentAlert((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func close() {
        window?.orderOut(nil)
        model = nil
    }

    private func presentAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

@MainActor
final class CropModel: ObservableObject {
    let url: URL
    let image: NSImage
    /// 归一化选择框（0-1，原点左上）
    @Published var selection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    init(url: URL, image: NSImage) {
        self.url = url
        self.image = image
    }

    var pixelSize: CGSize {
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var cropPixels: CGSize {
        CGSize(width: (pixelSize.width * selection.width).rounded(),
               height: (pixelSize.height * selection.height).rounded())
    }

    enum Aspect: String, CaseIterable, Identifiable {
        case free, square, fourThree, sixteenNine, nineSixteen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: return "自由"
            case .square: return "1:1"
            case .fourThree: return "4:3"
            case .sixteenNine: return "16:9"
            case .nineSixteen: return "9:16"
            }
        }
        var ratio: CGFloat? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .fourThree: return 4.0 / 3.0
            case .sixteenNine: return 16.0 / 9.0
            case .nineSixteen: return 9.0 / 16.0
            }
        }
    }

    /// 按比例把选区收成居中矩形
    func applyAspect(_ aspect: Aspect) {
        guard let ratio = aspect.ratio else { return }
        let imageRatio = pixelSize.width / max(pixelSize.height, 1)
        var width: CGFloat = 0.8
        var height = width * imageRatio / ratio
        if height > 0.8 {
            height = 0.8
            width = height * ratio / imageRatio
        }
        selection = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// 直接指定输出像素尺寸，保持选区中心不动
    func applyPixelSize(width: CGFloat, height: CGFloat) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let w = min(1, max(0.02, width / pixelSize.width))
        let h = min(1, max(0.02, height / pixelSize.height))
        let cx = selection.midX, cy = selection.midY
        selection = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func performCrop() throws -> URL {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.failed("无法解码图片")
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let rect = CGRect(
            x: (selection.minX * width).rounded(),
            y: (selection.minY * height).rounded(),
            width: max(1, (selection.width * width).rounded()),
            height: max(1, (selection.height * height).rounded())
        )
        guard let cropped = cgImage.cropping(to: rect) else {
            throw ConversionError.failed("裁剪失败")
        }

        let ext = url.pathExtension.lowercased()
        let destination = OutputNaming.path(for: url, suffix: "-裁剪")
        guard let type = UTType(filenameExtension: ext) ?? UTType.png as UTType?,
              let dest = CGImageDestinationCreateWithURL(destination as CFURL,
                                                        type.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("无法写出图片")
        }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.failed("写出失败")
        }
        return destination
    }
}

struct CropEditorView: View {
    @ObservedObject var model: CropModel
    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }
    var onApply: () -> Void
    var onCancel: () -> Void

    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 12) {
            Text(model.url.lastPathComponent)
                .font(.system(size: Palette.TypeSize.label, weight: .medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: model.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                    // 选择框
                    let box = CGRect(
                        x: fitted.minX + model.selection.minX * fitted.width,
                        y: fitted.minY + model.selection.minY * fitted.height,
                        width: model.selection.width * fitted.width,
                        height: model.selection.height * fitted.height
                    )

                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(
                            ZStack {
                                Rectangle().fill(.white)
                                Rectangle().fill(.black)
                                    .frame(width: box.width, height: box.height)
                                    .position(x: box.midX, y: box.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        )
                        .allowsHitTesting(false)

                    Rectangle()
                        .strokeBorder(Palette.brand, lineWidth: 1.5)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let start = dragStart ?? value.startLocation
                            dragStart = start
                            model.selection = normalized(from: start, to: value.location, in: fitted)
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }

            HStack(spacing: 8) {
                ForEach(CropModel.Aspect.allCases) { aspect in
                    Button(aspect.title) { model.applyAspect(aspect) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                Text("宽").font(.system(size: Palette.TypeSize.micro)).foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { Int(model.cropPixels.width) },
                    set: { model.applyPixelSize(width: CGFloat($0), height: model.cropPixels.height) }
                ), format: .number)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
                Text("高").font(.system(size: Palette.TypeSize.micro)).foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { Int(model.cropPixels.height) },
                    set: { model.applyPixelSize(width: model.cropPixels.width, height: CGFloat($0)) }
                ), format: .number)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Text("选区 \(Int(model.cropPixels.width)) × \(Int(model.cropPixels.height)) px")
                    .font(.system(size: Palette.TypeSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("裁剪") { onApply() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 500)
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

    private func normalized(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return model.selection }
        let x0 = min(start.x, end.x), x1 = max(start.x, end.x)
        let y0 = min(start.y, end.y), y1 = max(start.y, end.y)
        let nx0 = max(0, (x0 - rect.minX) / rect.width)
        let nx1 = min(1, (x1 - rect.minX) / rect.width)
        let ny0 = max(0, (y0 - rect.minY) / rect.height)
        let ny1 = min(1, (y1 - rect.minY) / rect.height)
        let width = max(0.02, nx1 - nx0)
        let height = max(0.02, ny1 - ny0)
        return CGRect(x: nx0, y: ny0, width: width, height: height)
    }
}
