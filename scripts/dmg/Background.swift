import AppKit

// 只绘制安装窗口背景，不修改 App 的图标、爪子或任何已签名资源。
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CGFloat(Double(CommandLine.arguments[2])!)
let size = NSSize(width: 680, height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                          pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let ink = NSColor(srgbRed: 0.16, green: 0.28, blue: 0.19, alpha: 1)
let muted = NSColor(srgbRed: 0.36, green: 0.45, blue: 0.37, alpha: 1)
NSColor(srgbRed: 0.94, green: 0.96, blue: 0.92, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
"安装 Totori".draw(at: NSPoint(x: 42, y: 326), withAttributes: [
    .font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: ink])
"将左侧的 Totori 拖入右侧 Applications 文件夹".draw(at: NSPoint(x: 42, y: 294), withAttributes: [
    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: muted])
for x: CGFloat in [170, 510] {
    let rect = NSRect(x: x - 79, y: 120, width: 158, height: 158)
    let path = NSBezierPath(ovalIn: rect)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.85),
               ending: NSColor(srgbRed: 0.83, green: 0.90, blue: 0.79, alpha: 0.65))!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.8).setStroke()
    path.lineWidth = 1
    path.stroke()
}
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 303, y: 200))
arrow.line(to: NSPoint(x: 374, y: 200))
arrow.move(to: NSPoint(x: 358, y: 215))
arrow.line(to: NSPoint(x: 374, y: 200))
arrow.line(to: NSPoint(x: 358, y: 185))
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.lineWidth = 3.5
NSColor(srgbRed: 0.36, green: 0.55, blue: 0.39, alpha: 0.85).setStroke()
arrow.stroke()
"复制完成后，从“应用程序”启动 Totori，再推出此磁盘。".draw(at: NSPoint(x: 42, y: 34), withAttributes: [
    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: muted])
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!.write(to: output)
