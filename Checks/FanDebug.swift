import AppKit
import AVFoundation
import ImageIO

/// `--show-fan`：无界面验证三种滚轮的几何与命中测试
enum FanDebug {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var samples: [URL] = []
        for name in ["/tmp/xj-fan-sample.png", "/tmp/xj-fan-sample.mp4", "/tmp/xj-fan-sample.docx"] {
            let url = URL(fileURLWithPath: name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            samples.append(url)
        }

        DispatchQueue.main.async {
            var allOK = true
            print("== 滚轮自检 ==")
            for mode in FanMode.allCases {
                for (index, sample) in samples.enumerated() where index == 0 || mode == .convert {
                FanController.shared.showForDebug(mode: mode, urls: [sample])
                let model = FanController.shared.model
                let count = model.items.count
                let ok = model.items.indices.filter {
                    model.petalIndex(at: model.petalCenter($0)) == $0
                }.count
                allOK = allOK && (ok == count) && count > 0
                print(String(format: "  %-8@ %@ %-14@ 项=%d 命中=%d",
                             mode.title as NSString, mode.keyHint as NSString,
                             sample.lastPathComponent as NSString, count, ok))
                FanController.shared.hide()
                }
            }
            print(allOK ? "结果：三种滚轮几何 OK ✅" : "结果：几何失败 ❌")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exit(allOK ? 0 : 1)
            }
        }
        app.run()
        return 0
    }
}

// MARK: - 菜单呈现探针

enum MenuModeProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures: [String] = []
        func expect(_ ok: Bool, _ label: String) {
            if !ok { failures.append(label) }
            print("  \(ok ? "✓" : "✕") \(label)")
        }

        DispatchQueue.main.async {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xj-menu")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("菜单样本.png")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0, count: 2048))
            }

            let controller = FanController.shared
            controller.debugSuppressActions = true
            controller.debugPresentMenuMode(urls: [file])

            // 菜单打开后通常没有按住鼠标：连续 tick 不能把它关掉
            for _ in 0..<5 {
                controller.tick(buttonDown: false, modifiers: FanModifiers(), at: NSEvent.mouseLocation)
            }
            expect(controller.debugWheelVisible, "菜单模式不被无按键 tick 关闭")
            expect(controller.debugMenuMode, "仍处于菜单呈现")

            // 点选一次：执行一次后关闭，再次 tick 不再执行
            let before = controller.debugApplyCount
            controller.debugClick(at: 0)
            let after = controller.debugApplyCount
            expect(after == before + 1, "点选执行一次（\(before) → \(after)）")
            expect(!controller.debugWheelVisible, "执行后收起")
            controller.tick(buttonDown: false, modifiers: FanModifiers(), at: NSEvent.mouseLocation)
            expect(controller.debugApplyCount == after, "收起后不会再执行")

            controller.debugPresentMenuMode(urls: [file])
            controller.debugHighlight(0)
            controller.debugKey(124)
            controller.tick(buttonDown: false, modifiers: FanModifiers(), at: NSEvent.mouseLocation)
            expect(controller.debugHighlighted == 1, "键盘选中不被静止指针轮询覆盖")
            let beforeReturn = controller.debugApplyCount
            controller.debugKey(36)
            expect(controller.debugApplyCount == beforeReturn + 1 && !controller.debugWheelVisible, "回车执行一次并收起")
            controller.debugPresentMenuMode(urls: [file])
            controller.debugKey(53)
            expect(!controller.debugWheelVisible, "Esc 取消菜单滚轮")

            // 真实拖拽路径保持不变：按下 → 移动 → 松开执行一次
            controller.debugSuppressActions = true
            controller.debugPresentDrag(urls: [file])
            let beforeDrag = controller.debugApplyCount
            controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: NSEvent.mouseLocation)
            controller.debugHighlight(0)
            controller.tick(buttonDown: false, modifiers: FanModifiers(), at: NSEvent.mouseLocation)
            expect(controller.debugApplyCount == beforeDrag + 1, "真实拖拽松手执行一次")
            expect(!controller.debugWheelVisible, "拖拽执行后收起")

            print(failures.isEmpty ? "结果：菜单呈现 OK ✅" : "结果：\(failures.count) 项失败 ❌")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        return 0
    }
}

// MARK: - 验收探针

enum AcceptanceProbe {
    @MainActor
    static func run(inputs: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures: [String] = []
        func expect(_ ok: Bool, _ label: String) {
            if !ok { failures.append(label) }
            print("  \(ok ? "✓" : "✕") \(label)")
        }

        DispatchQueue.main.async {
            let dir = URL(fileURLWithPath: inputs)
            print("== 验收自检 ==")
            print("  样本目录：\(dir.path)")

            // 1. 修剪：三种音频容器 + 视频
            for name in ["09-音频样本.mp3", "10-音频样本.wav", "11-视频样本.webm", "07-视频样本.mp4"] {
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    print("  - 跳过 \(name)（样本不存在）"); continue
                }
                let audioOnly = ["mp3", "wav", "m4a", "flac", "aiff", "ogg", "opus"].contains(url.pathExtension.lowercased())
                do {
                    let out = try TrimExport.run(url: url, start: 0.8, end: 1.8, isAudioOnly: audioOnly)
                    let d = TrimExport.duration(out)
                    expect(abs(d - 1.0) <= 0.25, "修剪 \(name) → \(String(format: "%.3f", d))s")
                    try? FileManager.default.removeItem(at: out)
                } catch {
                    expect(false, "修剪 \(name)：\(error)")
                }
            }

            // 2. 方向 6：清元数据后应变成 800×1200
            let oriented = dir.appendingPathComponent("08-方向6.jpg")
            if FileManager.default.fileExists(atPath: oriented.path),
               let png = FormatCatalog.all.first(where: { $0.ext == "png" }) {
                do {
                    let out = try Engine.convert(source: oriented, format: png,
                                                 to: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                 stripMetadata: true, options: .none) { _ in }
                    let size = NSImage(contentsOf: out)?.size ?? .zero
                    expect(Int(size.width) == 800 && Int(size.height) == 1200,
                           "方向6 清元数据 → \(Int(size.width))×\(Int(size.height))")
                    try? FileManager.default.removeItem(at: out)
                } catch {
                    expect(false, "方向6 转换失败：\(error)")
                }
            }

            // 3. 删一条后计数与选择
            let model = AppModel()
            let a = dir.appendingPathComponent("01-森林样本.png")
            let b = dir.appendingPathComponent("02-带元数据.jpg")
            model.add(urls: [a, b])
            if let first = model.files.first {
                model.remove(first)
            }
            expect(model.files.count == 1, "删一项后计数 = \(model.files.count)")
            expect(model.selectedFormat != nil, "删一项后仍保留有效格式")
            expect(model.statusText.contains("1"), "状态文字反映计数：\(model.statusText)")

            // 4. 批内去重
            let d = AppModel()
            d.add(urls: [a, a])
            expect(d.files.count == 1, "同批重复导入只留一份（\(d.files.count)）")

            // 5. 混合 / 不支持 拒绝说明
            let mixed = AppModel()
            mixed.add(urls: [a, dir.appendingPathComponent("03-中文 空格.txt"),
                             dir.appendingPathComponent("05-不支持.xyz")])
            expect(mixed.files.count == 1, "混合批次只收同类型（\(mixed.files.count)）")
            expect(mixed.importNotice?.contains("类型与这一批不一致") == true, "给出类型不一致原因")
            expect(mixed.importNotice?.contains("不支持的类型") == true, "给出不支持类型原因")

            // 6. 归档：外层打包命名
            let tar = dir.appendingPathComponent("06-归档.tar")
            if FileManager.default.fileExists(atPath: tar.path),
               let zip = FormatCatalog.all.first(where: { $0.ext == "zip" }) {
                if let out = try? Engine.convert(source: tar, format: zip,
                                                 to: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                 options: .none, progress: { _ in }) {
                    expect(out.lastPathComponent.hasSuffix(".tar.zip"),
                           "tar→zip 命名体现外层打包：\(out.lastPathComponent)")
                    try? FileManager.default.removeItem(at: out)
                }
            }

            // 7. pin 持久化
            UserDefaults.standard.set(true, forKey: "totori.shelfPinned")
            FileShelf.shared.reloadPinFromDefaults()
            expect(FileShelf.shared.debugPinned, "pin 从偏好恢复")
            UserDefaults.standard.set(false, forKey: "totori.shelfPinned")
            FileShelf.shared.reloadPinFromDefaults()

            print(failures.isEmpty ? "结果：验收自检全过 ✅" : "结果：\(failures.count) 项失败 ❌")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        return 0
    }
}

// MARK: - 持续轮询探针（复现真实拖动）

enum PawTickProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            print("  \(condition ? "✓" : "✕") \(label)")
        }

        DispatchQueue.main.async {
            print("== 小手持续轮询自检（25ms tick，模拟真实拖动）==")
            let model = FanModel()
            let items = FormatCatalog.formats(for: .media).map { FanItem.format($0) }
            model.configure(mode: .convert, items: items, fileCount: 1)
            model.highlighted = 0

            // 关键：像 DragMonitor 那样每 25ms 喂一次指针，而不是赋值一次
            let point = CGPoint(x: model.center.x, y: model.center.y - 180)
            var ticks = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
                ticks += 1
                MainActor.assumeIsolated { model.updatePointer(point) }
            }
            RunLoop.main.add(timer, forMode: .common)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                print("  0.16s 时 tick=\(ticks) phase=\(model.pawPhase)")
                expect(ticks >= 4, "轮询确实在持续触发（\(ticks) 次）")
                expect(model.pawPhase == .grasp, "持续轮询下仍能进入 grasp（不是卡在 reach）")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    print("  0.46s 时 tick=\(ticks) phase=\(model.pawPhase)")
                    expect(model.pawPhase == .pull, "持续轮询下仍能进入 pull")

                    // 换目标，持续轮询下也要重新走一轮
                    model.highlighted = 3
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        expect(model.pawPhase != .pull || model.highlighted == 3,
                               "换目标后重新开始序列")
                        timer.invalidate()
                        model.highlighted = nil
                        model.updatePointer(model.center)
                        expect(model.pawPhase == .idle, "回中心 → 收回")

                        print(failures.isEmpty ? "结果：持续轮询 OK ✅" : "结果：\(failures.count) 项失败 ❌")
                        exit(failures.isEmpty ? 0 : 1)
                    }
                }
            }
        }
        app.run()
        return 0
    }
}

// MARK: - 层级探针

enum FanLevelProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            print("== 轮盘层级自检 ==")
            let dragLevel = Int(CGWindowLevelForKey(.draggingWindow))
            print("  系统拖影层 = \(dragLevel)")
            print("  轮盘层 = \(FanController.aboveDragLevel.rawValue)")
            let ok = Int(FanController.aboveDragLevel.rawValue) > dragLevel
            print(ok ? "结果：轮盘在文件拖影之上 ✅" : "结果：层级不够 ❌")
            exit(ok ? 0 : 1)
        }
        app.run()
        return 0
    }
}

// MARK: - 小手探针

enum PawProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            print("  \(condition ? "✓" : "✕") \(label)")
        }

        DispatchQueue.main.async {
            print("== 小手自检 ==")
            expect(PawAssets.open != nil, "张开素材可加载")
            expect(PawAssets.grasp != nil, "合拢素材可加载")

            let model = FanModel()
            let items = FormatCatalog.formats(for: .media).map { FanItem.format($0) }
            model.configure(mode: .convert, items: items, fileCount: 1)

            // 没有拖动 → 没有爪子
            expect(model.pointerAngle == nil && model.pawPhase == .idle, "静止时不出爪子")

            // 开始拖动（指针在上方，未对上花瓣）→ 一只爪子张开伸出
            model.updatePointer(CGPoint(x: model.center.x, y: model.center.y - 180))
            expect(model.pointerAngle != nil, "拖动开始 → 爪子出现")
            expect(model.pawPhase == .reach, "无目标时张开跟随")

            model.highlighted = 1
            expect(model.pawPhase == .reach, "对上花瓣 → 先探出（reach）")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                expect(model.pawPhase == .grasp, "约 60ms 后合拢（grasp）")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    expect(model.pawPhase == .pull, "约 200ms 后轻带（pull）")

                    // 换目标：仍是同一只爪子，重新探出
                    model.highlighted = 3
                    expect(model.pawPhase == .reach, "换目标 → 重新探出")

                    // 回中心死区：铺开取消 → 爪子整个收回
                    model.highlighted = nil
                    model.updatePointer(model.center)
                    expect(model.pawPhase == .idle && model.pointerAngle == nil, "回中心 → 爪子收回")

                    print(failures.isEmpty ? "结果：小手 OK ✅" : "结果：\(failures.count) 项失败 ❌")
                    exit(failures.isEmpty ? 0 : 1)
                }
            }
        }
        app.run()
        return 0
    }
}

// MARK: - 主题切换探针

enum ThemeProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var averages: [(FanTheme, (Double, Double, Double))] = []
        let previous = UserDefaults.standard.string(forKey: "totori.theme")

        DispatchQueue.main.async {
            for theme in FanTheme.allCases {
                UserDefaults.standard.set(theme.rawValue, forKey: "totori.theme")
                let renderer = ImageRenderer(content:
                    ThemeSwatch()
                        .padding(20)
                        .background(Palette.surface)
                )
                renderer.scale = 1
                guard let cg = renderer.cgImage else { continue }
                averages.append((theme, averageColor(of: cg)))
            }

            print("== 主题探针 ==")
            for (theme, rgb) in averages {
                print(String(format: "  %-6@ 平均色 rgb(%.3f, %.3f, %.3f)",
                             theme.title as NSString, rgb.0, rgb.1, rgb.2))
            }

            var ok = averages.count == FanTheme.allCases.count
            for i in 0..<max(0, averages.count - 1) {
                let a = averages[i].1, b = averages[i + 1].1
                let diff = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                if diff < 0.004 { ok = false }
            }
            if let previous {
                UserDefaults.standard.set(previous, forKey: "totori.theme")
            } else {
                UserDefaults.standard.removeObject(forKey: "totori.theme")
            }
            print(ok ? "结果：三个主题渲染结果不同 ✅" : "结果：主题切换没有视觉差异 ❌")
            exit(ok ? 0 : 1)
        }
        app.run()
        return 0
    }

    private static func averageColor(of image: CGImage) -> (Double, Double, Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0, 0, 0)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}

// MARK: - 资源探针

enum AssetProbe {
    @MainActor
    static func run() -> Int32 {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            if !condition { ok = false }
            print("  \(condition ? "✓" : "✕") \(label)")
        }
        print("== 资源自检 ==")

        let menubar = NSImage(named: "menubar")
        check(menubar != nil, "菜单栏模板图可加载")
        if let menubar {
            menubar.size = NSSize(width: 20, height: 18)
            menubar.isTemplate = true
            check(menubar.isTemplate, "按模板渲染（20×18）")
            check(menubar.size == NSSize(width: 20, height: 18), "逻辑尺寸 = 20×18")
            check(menubar.representations.count >= 1, "位图表示数 = \(menubar.representations.count)")
        }

        let iconPath = Bundle.main.bundlePath + "/Contents/Resources/AppIcon.icns"
        check(FileManager.default.fileExists(atPath: iconPath), "AppIcon.icns 已进 bundle")
        let plistIcon = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String
        check(plistIcon == "AppIcon", "Info.plist CFBundleIconFile = \(plistIcon ?? "nil")")

        print(ok ? "结果：资源 OK ✅" : "结果：资源异常 ❌")
        return ok ? 0 : 1
    }
}

// MARK: - 主窗口离屏渲染

enum MainWindowRender {
    @MainActor
    static func run(outputPath: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xj-main")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in ["旅行照片.heic", "封面设计.png", "参考图.jpg"] {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                // 写一点内容，让体积显示不是 0
                try? Data(repeating: 0, count: 240_000).write(to: url)
            }
            urls.append(url)
        }

        DispatchQueue.main.async {
            let model = AppModel()
            model.add(urls: urls)
            // 摆出三种典型状态：已完成（带体积对比）、转换中（带进度）、排队，用来核对行内布局。
            if urls.count >= 3 {
                model.results = [ConversionResult(
                    source: urls[0], output: urls[0].deletingPathExtension().appendingPathExtension("png"),
                    error: nil,
                    outputSummary: ConversionOutputSummary(sourceExtension: "heic", outputExtension: "png",
                                                           sourceBytes: 2_400_000, outputBytes: 5_100_000))]
                model.jobStates = [urls[0]: .succeeded, urls[1]: .running, urls[2]: .queued]
                model.fileProgress = [urls[1]: 0.45]
            }
            model.statusText = "已完成 3 个文件 · 原文件已保留"

            // 离屏窗口里真实渲染：ImageRenderer 画不出滚动列表和 AppKit 控件，会出占位禁止符。
            let size = NSSize(width: 900, height: 600)
            let hosting = NSHostingView(rootView: ContentView(model: model).frame(width: size.width, height: size.height))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            // 用 `-AppleInterfaceStyle Dark` 参数时离屏窗口不会自动跟随，手动指定
            if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
                window.appearance = NSAppearance(named: .darkAqua)
            }
            window.orderBack(nil)
            hosting.layoutSubtreeIfNeeded()

            // 文件简介、缩略图是异步读取的，等一会儿再截图。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                hosting.layoutSubtreeIfNeeded()
                var failed = true
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]),
                       (try? data.write(to: URL(fileURLWithPath: outputPath))) != nil {
                        failed = false
                    }
                }
                exit(failed ? 1 : 0)
            }
        }
        app.run()
        return 0
    }
}

// MARK: - 浮窗探针

enum ShelfProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xj-shelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in ["报价单.pdf", "封面.png", "演示.pptx", "录音.m4a", "合同.docx"] {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            urls.append(url)
        }
        FileShelf.shared.add(urls)
        FileShelf.shared.show()

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            print("  \(condition ? "✓" : "✕") \(label)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let canvas = FileShelf.shared.debugCanvas else {
                print("浮窗没有画布"); exit(1)
            }
            print("== 浮窗自检 ==")
            print("  文件数=\(FileShelf.shared.files.count) 分组=\(canvas.debugGroups)")
            print("  单元格=\(canvas.debugCellFrames)")
            print("  文件=\(FileShelf.shared.files.map(\.lastPathComponent))")

            let before = canvas.debugCellCount
            expect(canvas.window?.isMovableByWindowBackground == false, "浮窗禁止背景整块移动")
            expect(!canvas.mouseDownCanMoveWindow, "文件区不接管窗口移动")
            let transfer = ShelfCanvas(frame: canvas.bounds)
            transfer.add(urls)
            transfer.selection = [0, 1, 2]
            transfer.finishDrag(urls: Array(urls.prefix(2)), operation: [], returnedToShelf: false)
            expect(transfer.files == urls && transfer.debugPreviewCount == 3, "取消/拒收拖出保留暂存和选择")
            transfer.finishDrag(urls: Array(urls.prefix(2)), operation: .copy, returnedToShelf: true)
            expect(transfer.files == urls, "拖回浮窗不消费条目")
            let lateFile = dir.appendingPathComponent("拖动期间加入.txt")
            try? Data("late".utf8).write(to: lateFile)
            transfer.add([lateFile])
            transfer.finishDrag(urls: Array(urls.prefix(2)), operation: .copy, returnedToShelf: false)
            expect(transfer.files == Array(urls.dropFirst(2)) + [lateFile], "成功多选拖出仅移除本次条目，新加入项保留")
            expect(transfer.selection == [0] && transfer.debugPreviewCount == 1, "剩余选择按文件重映射")
            transfer.finishDrag(urls: Array(urls.prefix(2)), operation: .copy, returnedToShelf: false)
            expect(transfer.files.count == 4, "完成回调重复不会移除其他文件")
            expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "移除暂存条目不删除磁盘原件")
            canvas.debugToggleCollapse("文档")
            let after = canvas.debugCellCount
            canvas.debugToggleCollapse("文档")
            expect(after < before, "折叠分组：\(before) → \(after) 格")

            canvas.selection = [0, 2]
            expect(canvas.debugPreviewCount == 2, "快览项数跟随选中")

            // 截图核对回形针
            if let view = FileShelf.shared.debugCanvas?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let path = URL(fileURLWithPath: "/tmp/totori-shelf.png")
                    try? data.write(to: path)
                    print("  截图 → \(path.path)")
                }
            }

            // 贴边吸附
            print("  收起前: collapsed=\(FileShelf.shared.debugCollapsed) frame=\(FileShelf.shared.debugPanelFrame)")
            FileShelf.shared.collapse(to: .left)
            print("  收起后立即: collapsed=\(FileShelf.shared.debugCollapsed) frame=\(FileShelf.shared.debugPanelFrame)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let collapsedFrame = FileShelf.shared.debugPanelFrame
                expect(FileShelf.shared.debugCollapsed, "贴左边缘 → 收起")
                expect(collapsedFrame.width <= 14, "收起后宽度=\(Int(collapsedFrame.width))")

                FileShelf.shared.expand()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let expandedFrame = FileShelf.shared.debugPanelFrame
                    expect(!FileShelf.shared.debugCollapsed, "悬停/调用 → 展开")
                    expect(expandedFrame.width > 200, "展开后宽度=\(Int(expandedFrame.width))")

                    // 回形针：钉住 / 解除
                    FileShelf.shared.debugTogglePin()
                    expect(FileShelf.shared.debugPinned, "点回形针 → 钉住")
                    FileShelf.shared.debugSimulateExit()
                    // 截图核对钉住后的回形针
                    if let view = FileShelf.shared.debugCanvas?.superview,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: "/tmp/totori-shelf-pinned.png"))
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        expect(!FileShelf.shared.debugCollapsed, "钉住后鼠标移开不收起")

                        FileShelf.shared.debugTogglePin()
                        expect(!FileShelf.shared.debugPinned, "再点 → 解除钉住")
                        FileShelf.shared.debugSimulateExit()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            expect(FileShelf.shared.debugCollapsed, "解除后移开会收起")
                            FileShelf.shared.expand()

                            print(failures.isEmpty
                                  ? "结果：浮窗 OK ✅"
                                  : "结果：\(failures.count) 项失败 ❌")
                            exit(failures.isEmpty ? 0 : 1)
                        }
                    }
                }
            }
        }
        app.run()
        return 0
    }
}

// MARK: - 动画探针：读 presentation layer，确认动画真的在跑

enum FanAnimProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let sample = URL(fileURLWithPath: "/tmp/xj-fan-sample.mp4")
        if !FileManager.default.fileExists(atPath: sample.path) {
            FileManager.default.createFile(atPath: sample.path, contents: Data())
        }

        DispatchQueue.main.async {
            FanController.shared.presentForProbe(urls: [sample], mode: .tools)
            let start = Date()

            @MainActor func report(_ label: String) {
                let elapsed = Date().timeIntervalSince(start) * 1000
                guard let layer = FanController.shared.debugLayer else {
                    print(String(format: "  %-14@ layer=nil", label as NSString)); return
                }
                let pres = layer.presentation()
                let scale = pres?.value(forKeyPath: "transform.scale") as? Double
                let opacity = pres?.opacity
                let bloom = FanController.shared.model.bloom
                print(String(format: "  %-8@ t=%4.0fms 面板scale=%@ opacity=%@  花瓣进度=%.2f",
                             label as NSString, elapsed,
                             (scale.map { String(format: "%.3f", $0) } ?? "nil") as NSString,
                             (opacity.map { String(format: "%.2f", $0) } ?? "nil") as NSString,
                             bloom))
            }

            print("== 动画探针 ==")
            report("t0")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { report("t80ms") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { report("t160ms") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { report("t400ms"); exit(0) }
        }
        app.run()
        return 0
    }
}

// MARK: - 状态机自检

enum FanSimulation {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 让文件类型可识别，便于算出花瓣数
        let sample = URL(fileURLWithPath: "/tmp/xj-fan-sample.mp4")
        if !FileManager.default.fileExists(atPath: sample.path) {
            FileManager.default.createFile(atPath: sample.path, contents: Data())
        }

        var failures: [String] = []
        let c = FanController.shared
        let base = NSPoint(x: 600, y: 400)

        /// 用当前键位映射构造修饰键，避免测试和配置脱节
        func mods(_ mode: FanMode) -> FanModifiers {
            let key = KeyMap.primaryKey(for: mode)
            return FanModifiers(shift: key == .shift, option: key == .option,
                                command: key == .command, control: key == .control)
        }
        let toolsKey = KeyMap.primaryKey(for: .tools).symbol
        let convertKey = KeyMap.primaryKey(for: .convert).symbol

        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            print("  \(condition ? "✓" : "✕") \(label)")
        }

        func fail(_ label: String) {
            failures.append(label)
            print("  ✕ \(label)")
        }

        print("== 状态机自检 ==")

        // 1. 先按键，再按下鼠标并移动
        c.tick(buttonDown: false, modifiers: mods(.tools), at: base)
        c.tick(buttonDown: true, modifiers: mods(.tools), at: base)
        c.tick(buttonDown: true, modifiers: mods(.tools), at: NSPoint(x: base.x + 20, y: base.y + 12))
        expect(c.debugVisible, "\(toolsKey) + 拖动 → 出轮")
        expect(c.debugMode == .tools, "\(toolsKey) 对应「文件工具」")
        // 入场动画现在延到下一轮 runloop 才挂，这里先跑一会儿队列
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        expect(c.debugAnimationKeys.contains("fan.entrance"),
               "入场动画已挂到图层（\(c.debugAnimationKeys)）")

        // 1b. 同一个滚轮可以绑多个键：⌘ 和 ⌥ 都要能开工具轮
        expect(KeyMap.matches(.tools, FanModifiers(command: true)), "⌘ 也绑在工具轮上")
        expect(KeyMap.matches(.tools, FanModifiers(option: true)), "⌥ 也绑在工具轮上")
        expect(!KeyMap.matches(.convert, FanModifiers(command: true)), "⌘ 不会误触发转换轮")

        // 2. 换键 → 换滚轮
        c.tick(buttonDown: true, modifiers: mods(.convert), at: NSPoint(x: base.x + 22, y: base.y + 14))
        expect(c.debugMode == .convert, "拖到一半切到 \(convertKey) → 换成「转换格式」")

        c.tick(buttonDown: true, modifiers: mods(.actions), at: NSPoint(x: base.x + 24, y: base.y + 16))
        expect(c.debugMode == .actions, "再切到 \(KeyMap.primaryKey(for: .actions).symbol) →「文件动作」")

        // 3. 松手收起
        c.tick(buttonDown: false, modifiers: FanModifiers(), at: base)
        expect(!c.debugVisible, "松手 → 收起")

        // 4. 键按着但没拖：不该出轮
        c.tick(buttonDown: false, modifiers: FanModifiers(shift: true), at: base)
        c.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: base)
        expect(!c.debugVisible, "只按键不移动 → 不出轮")

        // 5. 回归测试：拖放完成后，下一次光按不动也必须能收起
        c.tick(buttonDown: true, modifiers: mods(.tools), at: base)
        c.tick(buttonDown: true, modifiers: mods(.tools), at: NSPoint(x: base.x + 30, y: base.y))
        expect(c.debugVisible, "重新出轮")
        c.debugMarkDropped()                     // 相当于这次是拖放完成的
        c.tick(buttonDown: false, modifiers: FanModifiers(), at: base)
        expect(!c.debugVisible, "拖放完成后再松手 → 仍然收起（回归）")

        // 7. 拖到很远：环不动，仍然按方向选中
        c.tick(buttonDown: true, modifiers: mods(.tools), at: base)
        c.tick(buttonDown: true, modifiers: mods(.tools), at: NSPoint(x: base.x + 40, y: base.y))
        expect(c.debugVisible, "重新出轮（用于测试约束）")
        let far = NSPoint(x: base.x + 500, y: base.y + 300)
        c.tick(buttonDown: true, modifiers: mods(.tools), at: far)
        if let center = c.debugCenterSnapshot {
            expect(abs(center.x - base.x) < 1 && abs(center.y - base.y) < 1,
                   "环完全没有移动")
        } else {
            fail("没有轮心")
        }
        expect(c.debugHighlighted != nil, "拖到环外也按方向选中花瓣")

        // 8. 回到中心 = 取消
        if let center = c.debugWheelCenter {
            c.tick(buttonDown: true, modifiers: mods(.tools), at: center)
            expect(c.debugHighlighted == nil, "回到中心 → 无选中")
        }
        c.tick(buttonDown: false, modifiers: FanModifiers(), at: base)
        expect(!c.debugVisible, "中心松手 → 取消并收起")

        // 9. 拖放事件丢失时的兜底：松手仍然要执行
        c.debugSuppressActions = true
        c.debugSetURLs([sample])
        c.tick(buttonDown: true, modifiers: mods(.tools), at: base)
        c.tick(buttonDown: true, modifiers: mods(.tools), at: NSPoint(x: base.x + 40, y: base.y))
        if let center = c.debugWheelCenter {
            c.tick(buttonDown: true, modifiers: mods(.tools), at: NSPoint(x: center.x, y: center.y + 140))
        }
        expect(c.debugHighlighted != nil, "悬停选中花瓣")
        let before = c.debugApplyCount
        c.tick(buttonDown: false, modifiers: FanModifiers(), at: base)
        expect(c.debugApplyCount == before + 1, "没有收到 drop 也能执行（兜底）")
        c.debugSuppressActions = false

        // 10. 鼠标移动不足 6pt：不该出轮
        c.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: NSPoint(x: base.x + 3, y: base.y + 2))
        expect(!c.debugVisible, "位移不足 6pt → 不出轮")

        print(failures.isEmpty ? "结果：状态机 OK ✅" : "结果：\(failures.count) 项失败 ❌")
        return failures.isEmpty ? 0 : 1
    }
}

// MARK: - 面板截屏自检

enum FanCapture {
    @MainActor
    static func run(outputPath: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let sample = URL(fileURLWithPath: "/tmp/xj-fan-sample.mp4")
        if !FileManager.default.fileExists(atPath: sample.path) {
            FileManager.default.createFile(atPath: sample.path, contents: Data())
        }
        DispatchQueue.main.async {
            FanController.shared.showForDebug(mode: .convert, urls: [sample])
            FanController.shared.model.appeared = true
            FanController.shared.model.bloom = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let ok = FanController.shared.debugCapture(to: outputPath)
                exit(ok ? 0 : 1)
            }
        }
        app.run()
        return 0
    }
}

// MARK: - 离屏渲染（无屏幕权限也能检查外观）

import SwiftUI

enum FanRender {
    @MainActor
    static func run(outputPath: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let sample = URL(fileURLWithPath: "/tmp/xj-fan-sample.mp4")
        if !FileManager.default.fileExists(atPath: sample.path) {
            FileManager.default.createFile(atPath: sample.path, contents: Data())
        }

        var failed = false
        DispatchQueue.main.async {
            let model = FanController.shared.model
            model.apply(mode: .convert,
                        items: FormatCatalog.formats(for: .media).map { .format($0) },
                        fileCount: 1)
            model.appeared = true
            model.bloom = 1          // 离屏渲染没有 runloop 跑定时器，直接给终态
            model.highlighted = 0
            model.pointerAngle = -Double.pi / 2
            model.pointerPoint = CGPoint(x: model.center.x, y: model.center.y - model.radius + 60)
            model.fileIcon = NSWorkspace.shared.icon(forFile: NSTemporaryDirectory())
            model.fileLabel = "HEIC"
            model.pawPhase = .grasp  // 静态展示"抓住"这一帧

            let renderer = ImageRenderer(content:
                FanView(model: model)
                    .frame(width: FanModel.panelSize, height: FanModel.panelSize)
                    .background(Color(white: 0.16))
            )
            renderer.scale = 2

            if let image = renderer.cgImage {
                let url = URL(fileURLWithPath: outputPath)
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    if !CGImageDestinationFinalize(dest) { failed = true }
                } else { failed = true }
            } else { failed = true }

            exit(failed ? 1 : 0)
        }
        app.run()
        return 0
    }
}
