import AppKit
import SwiftUI
import CoreGraphics

/// 纯状态/几何回归：不构造 UI 事件、不启动应用窗口。
@MainActor
enum ComparisonUIProbe {
    static func run() -> Int32 {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✕") \(label)")
        }

        func bitmap(_ width: Int, _ height: Int) -> CGImage? {
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let source = tmp.appendingPathComponent("comparison-probe-src.png")
        let output = tmp.appendingPathComponent("comparison-probe-out.png")

        print("== 对比视图状态 ==")
        let model = ComparisonModel(source: source, output: output)
        let image = bitmap(120, 80)

        // 1. 分界线 0 / 50 / 100
        model.setDivider(-0.4)
        expect(model.divider == 0, "分界线下限夹到 0")
        model.setDivider(0.5)
        expect(model.divider == 0.5, "分界线 50%")
        model.setDivider(1.6)
        expect(model.divider == 1, "分界线上限夹到 1")

        // 2. 同像素尺寸才能分界
        model.debugSetImages(source: image, output: image,
                             sourceSize: (120, 80), outputSize: (120, 80))
        expect(model.canUseDivider, "同尺寸允许分界")
        model.setMode(.divider)
        expect(model.mode == .divider, "可进入分界模式")
        expect(!model.dividerUnavailable, "分界可用时不报警")

        model.debugSetImages(source: image, output: image,
                             sourceSize: (120, 80), outputSize: (120, 40))
        expect(!model.canUseDivider, "尺寸不同禁用分界")
        model.setMode(.divider)
        expect(model.mode == .sideBySide, "尺寸不同保持并排")
        expect(model.dividerUnavailable, "给出无法对齐提示")

        // 3. 按住/松开/失焦恢复
        model.setMode(.sideBySide)
        model.holdOriginal = true
        expect(model.showingOriginalOnly, "按住显示原图")
        model.releaseHold()
        expect(!model.showingOriginalOnly, "松开恢复对比")
        model.holdOriginal = true
            model.releaseHold()                           // 失焦与取消路径复用的临时状态释放
            expect(!model.showingOriginalOnly, "取消临时原图状态后恢复对比")
        model.lockOriginal = true
        expect(model.showingOriginalOnly, "锁定方式持续显示原图")
        model.lockOriginal = false

        // 4. 切换模式不影响缩放
        model.debugSetImages(source: image, output: image,
                             sourceSize: (120, 80), outputSize: (120, 80))
        model.zoom = 1.7
        model.fit = false
        model.setMode(.divider)
        expect(model.zoom == 1.7 && !model.fit, "切到分界保留缩放")
        model.setMode(.sideBySide)
        expect(model.zoom == 1.7 && !model.fit, "切回并排保留缩放")

        // 5. 取消后旧请求不再被接受
        let token = model.debugRequestToken
        model.cancel()
        expect(model.debugRequestToken != token, "取消后请求令牌失效")


        // 6. 几何：非零原点 / 0、50、100% / 超界
        let rect = CGRect(x: 13, y: 7, width: 100, height: 50)
        expect(ComparisonGeometry.fraction(atX: 13, imageRect: rect) == 0, "原点处比例 0")
        expect(abs(ComparisonGeometry.fraction(atX: 63, imageRect: rect) - 0.5) < 0.0001, "中点比例 50%")
        expect(ComparisonGeometry.fraction(atX: 113, imageRect: rect) == 1, "右端比例 1")
        expect(ComparisonGeometry.fraction(atX: 300, imageRect: rect) == 1, "超出右界夹到 1")
        expect(ComparisonGeometry.fraction(atX: -40, imageRect: rect) == 0, "超出左界夹到 0")
        let zero = ComparisonGeometry.clipRects(fraction: 0, imageRect: rect)
        expect(zero.left.width == 0 && zero.right.width == 100, "0% 全部给结果")
        let half = ComparisonGeometry.clipRects(fraction: 0.5, imageRect: rect)
        expect(abs(half.left.width - 50) < 0.001 && abs(half.right.width - 50) < 0.001, "50% 各占一半")
        let full = ComparisonGeometry.clipRects(fraction: 1, imageRect: rect)
        expect(full.left.width == 100 && full.right.width == 0, "100% 全部给原图")

        // 7. 像素：左原图、右结果、透明结果露出棋盘
        func solid(_ color: NSColor?, _ width: Int, _ height: Int) -> NSImage? {
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            if let color {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            guard let image = context.makeImage() else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: width, height: height))
        }
        func render(_ canvas: ComparisonCanvas) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 40,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            canvas.drawContent(in: canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        let canvas = ComparisonCanvas(frame: CGRect(x: 0, y: 0, width: 60, height: 40))
        canvas.drawnSize = CGSize(width: 40, height: 20)
        canvas.image = solid(.red, 40, 20)
        canvas.secondImage = solid(.blue, 40, 20)

        func sample(_ divider: CGFloat, x: Int) -> NSColor? {
            canvas.divider = divider
            guard let rep = render(canvas) else { return nil }
            return rep.colorAt(x: x, y: 20)
        }

        if let left = sample(0.5, x: 15), let right = sample(0.5, x: 45) {
            expect(left.redComponent > 0.6 && left.blueComponent < 0.3, "50% 左侧显示原图")
            expect(right.blueComponent > 0.6 && right.redComponent < 0.3, "50% 右侧显示结果")
        } else { expect(false, "分界画布可渲染") }

        // 端点的拖柄占用边缘 7pt，采样图像中心，避免把控件色当成图片色。
        if let edge = sample(0, x: 30) {
            expect(edge.blueComponent > 0.6 && edge.redComponent < 0.3, "0% 分界在最左：全为结果")
        } else { expect(false, "0% 可渲染") }

        if let edge = sample(1, x: 30) {
            expect(edge.redComponent > 0.6 && edge.blueComponent < 0.3, "100% 分界在最右：全为原图")
        } else { expect(false, "100% 可渲染") }

        // 透明结果：右侧应露出棋盘，不能透出下面的红色原图
        canvas.secondImage = solid(nil, 40, 20)
        if let transparent = sample(0.5, x: 45) {
            let gray = abs(transparent.redComponent - transparent.greenComponent) < 0.12
                && abs(transparent.greenComponent - transparent.blueComponent) < 0.12
            let redDominant = transparent.redComponent > 0.6 && transparent.greenComponent < 0.4
            expect(gray && !redDominant, "透明结果右侧显示棋盘而非原图")
        } else { expect(false, "透明结果可渲染") }

        // 棋盘本身
        canvas.image = nil
        canvas.secondImage = nil
        if let rep = render(canvas), let a = rep.colorAt(x: 13, y: 12), let b = rep.colorAt(x: 25, y: 12) {
            expect(a != b, "透明区域绘制棋盘格")
        } else { expect(false, "空图可渲染棋盘") }

        // 8. 按住不改变缩放/分界
        model.debugSetImages(source: image, output: image,
                             sourceSize: (120, 80), outputSize: (120, 80))
        model.fit = false
        model.zoom = 2.2
        model.setDivider(0.35)
        let before = (model.zoom, model.fit, model.divider, model.mode)
        model.holdOriginal = true
        model.releaseHold()
        expect(model.zoom == before.0 && model.fit == before.1
               && model.divider == before.2 && model.mode == before.3, "按住不污染缩放/分界")


        // 9. 锚点规则：只在真的有滚动范围时回写
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 100)
        let small = ComparisonAnchor.afterScroll(viewport: viewport,
                                                 imageRect: CGRect(x: 20, y: 10, width: 160, height: 80),
                                                 drawnSize: CGSize(width: 160, height: 80),
                                                 canvasSize: CGSize(width: 200, height: 100),
                                                 current: CGPoint(x: 0.731, y: 0.538))
        expect(small == CGPoint(x: 0.731, y: 0.538), "无滚动范围时锚点不变")
        let blank = ComparisonAnchor.afterScroll(viewport: .zero, imageRect: .zero,
                                                 drawnSize: .zero, canvasSize: .zero,
                                                 current: CGPoint(x: 0.4, y: 0.6))
        expect(blank == CGPoint(x: 0.4, y: 0.6), "首帧空几何不污染锚点")
        let scrolled = ComparisonAnchor.afterScroll(viewport: CGRect(x: 200, y: 100, width: 200, height: 100),
                                                    imageRect: CGRect(x: 0, y: 0, width: 600, height: 300),
                                                    drawnSize: CGSize(width: 600, height: 300),
                                                    canvasSize: CGSize(width: 600, height: 300),
                                                    current: .zero)
        expect(abs(scrolled.x - 0.5) < 0.001 && abs(scrolled.y - 0.5) < 0.001, "滚到中间回写 0.5")

        // 10. 真实 NSScrollView：首帧不污染、用户滚动回写、双窗同步
        final class AnchorBox { var value = CGPoint(x: 0.731, y: 0.538) }
        @MainActor final class Harness {
            let scroll: NSScrollView
            let canvas: ComparisonCanvas
            let coordinator: ComparisonImageScroll.Coordinator
            init(_ config: ComparisonImageScroll) {
                scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
                canvas = ComparisonCanvas(frame: .zero)
                scroll.documentView = canvas
                scroll.contentView.postsBoundsChangedNotifications = true
                coordinator = ComparisonImageScroll.Coordinator(config)
                coordinator.observe(scroll)
                coordinator.layout(scroll)
            }
        }
        let box = AnchorBox()
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        func config(_ binding: Binding<CGPoint>) -> ComparisonImageScroll {
            ComparisonImageScroll(image: image, secondImage: nil,
                                  originalSize: CGSize(width: 600, height: 300), scale: 1,
                                  divider: 0.5, originalOnly: true, onDividerChange: nil,
                                  anchor: binding)
        }

        let first = Harness(config(binding))
        withExtendedLifetime(first.coordinator) {
            expect(box.value == CGPoint(x: 0.731, y: 0.538), "首次布局不回写锚点")
            expect(first.canvas.frame.width >= 600, "内容按 600pt 展开")

            // 首次布局的程序化滚动回显也不应改写
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(box.value == CGPoint(x: 0.731, y: 0.538), "程序化滚动回显不改锚点")

            // 用户等价滚动：100,50 → 归一化中心约 1/3
            first.scroll.contentView.scroll(to: NSPoint(x: 100, y: 50))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(abs(box.value.x - 1.0 / 3) < 0.02 && abs(box.value.y - 1.0 / 3) < 0.02,
                   "用户滚动写回约 1/3（实际 \(String(format: "%.3f", box.value.x))）")

            // 另一窗共享同一锚点：布局后对齐同一位置
            let beforeSecond = box.value
            let second = Harness(config(binding))
            withExtendedLifetime(second.coordinator) {
                let origin = second.scroll.contentView.bounds.origin
                expect(abs(origin.x - 100) < 0.5 && abs(origin.y - 50) < 0.5,
                       "另一窗对齐同一锚点（x=\(Int(origin.x)) y=\(Int(origin.y))）")
                expect(box.value == beforeSecond, "双窗不互相改写")
            }
        }

        print(failures == 0 ? "结果：对比状态 OK ✅" : "结果：\(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }
}
