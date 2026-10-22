import AppKit
import ImageIO
import CryptoKit

/// 浮窗视觉功能的行为回归：使用合成副本验证缓存失效、切换锚点和有界预览。
/// 不合成桌面输入事件，不接触用户原文件；最终可读性另外通过原生界面验收。
enum ShelfUIProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in exit(await execute()) }
        app.run()
        return 0
    }

    @MainActor
    private static func execute() async -> Int32 {
        var passed = 0, failed = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: "totori.shelfViewMode")
        defer {
            if let previousMode { defaults.set(previousMode, forKey: "totori.shelfViewMode") }
            else { defaults.removeObject(forKey: "totori.shelfViewMode") }
        }
        defaults.set("grid", forKey: "totori.shelfViewMode")
        let inputs = ProbeFixtures.inputs
        let folder = ProbeFixtures.work.appendingPathComponent("shelf-probe-\(getpid())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = inputs.appendingPathComponent("01-森林样本.png")
            let originalHash = try hash(original)
            let mutable = folder.appendingPathComponent("原地更新.png")
            try FileManager.default.copyItem(at: original, to: mutable)
            let video = inputs.appendingPathComponent("07-视频样本.mp4")
            let rotated = inputs.appendingPathComponent("08-方向6.jpg")
            let canvas = ShelfCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 440))
            canvas.add([mutable, video, rotated])
            expect(await until { canvas.debugThumbnailSize(for: mutable) != nil }, "图片真实缩略图就绪")
            expect(await until { canvas.debugThumbnailSize(for: video) != nil }, "视频首帧缩略图就绪")
            expect(await until { canvas.debugThumbnailSize(for: rotated) != nil }, "EXIF方向图片缩略图就绪")
            if let size = canvas.debugThumbnailSize(for: rotated) {
                expect(size.height > size.width, "缩略图遵循EXIF旋转方向")
            } else { expect(false, "EXIF方向可验证") }
            canvas.selection = [0, 2]
            let ordered = canvas.files
            canvas.toggleViewMode()
            expect(canvas.viewMode == .list && canvas.files == ordered && canvas.selection == [0, 2],
                   "切列表保留顺序与多选")
            expect(ShelfCanvas(frame: canvas.frame).viewMode == .list, "后续浮窗读取上次视图模式")
            if let preview = canvas.debugDragPreviewFrame(for: 0) {
                expect(preview.minX == 16 && preview.width == 38 && preview.height == 38,
                       "列表拖影对齐左侧缩略图而非行中心")
            } else { expect(false, "列表拖影位置可验证") }
            canvas.removeSelected()
            canvas.toggleViewMode()
            canvas.undo()
            expect(canvas.files == ordered && canvas.selection == [0, 2], "切换视图不破坏移除撤销与原选择")

            try makePNG(width: 64, height: 32, url: mutable)
            canvas.refreshMetadata()
            expect(await until {
                guard let size = canvas.debugThumbnailSize(for: mutable) else { return false }
                return abs(size.width / size.height - 2) < 0.02
            }, "原地替换图片后缩略图刷新")
            try Data("invalid PNG after valid image".utf8).write(to: mutable)
            canvas.refreshMetadata()
            expect(await until { canvas.debugThumbnailSize(for: mutable) == nil }, "有效图片损坏后不残留旧缩略图")

            // 连续覆盖模拟解码期间源文件变化，最后一次内容必须收敛而非丢弃后不再重试。
            for i in 0..<8 {
                try makePNG(width: 100 + i * 7, height: 60 + i, url: mutable)
                canvas.refreshMetadata()
                await Task.yield()
            }
            try makePNG(width: 77, height: 33, url: mutable)
            canvas.refreshMetadata()
            expect(await until {
                guard let size = canvas.debugThumbnailSize(for: mutable) else { return false }
                return abs(size.width / size.height - 77.0 / 33.0) < 0.02
            }, "连续原地覆盖后最终缩略图收敛到最新版本")

            let large = ShelfCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 440))
            var urls: [URL] = []
            for i in 0..<120 {
                let url = folder.appendingPathComponent(String(format: "批量-%03d.png", i))
                try FileManager.default.copyItem(at: original, to: url)
                urls.append(url)
            }
            large.add(urls)
            if large.viewMode != .list { large.toggleViewMode() }
            large.debugScrollToBottom()
            let beforeSwitch = large.files
            large.selection = [119]
            large.toggleViewMode()
            expect(large.viewMode == .grid && large.debugScrollOffset <= large.debugMaximumScroll + 0.5 &&
                   large.debugScrollOffset >= 0 && large.debugVisibleFileCount > 0,
                   "列表底部切网格有可见文件且滚动范围有效")
            expect(large.files == beforeSwitch && large.selection == [119], "大批切换保留全部文件与选择")
            expect(await until { large.debugThumbnailCount > 0 }, "滚动后可见项补载缩略图")
            expect(large.debugThumbnailCount <= 96, "浮窗自身不强持有超过96张缩略图")
            large.clear()
            expect(large.debugThumbnailCount == 0, "清空引用释放浮窗缩略图")
            expect(try hash(original) == originalHash, "缩略图与模式操作不修改源图")
        } catch {
            failed += 1
            print("FAIL exception: \(error)")
        }
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makePNG(width: Int, height: Int, url: URL) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.failed("无法创建缩略图回归样本")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("回归图片写入失败") }
    }
}
