import AppKit
import CryptoKit

/// 第二批交互回归：使用合成副本和暂存偏好，退出前还原全部涉及的设置。
/// 不发送桌面事件，不删除文件原件；原生键盘焦点和预览另用界面验收。
@MainActor
enum InteractionProbe {
    static func run() -> Int32 {
        _ = NSApplication.shared
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)")
        }
        let defaults = UserDefaults.standard
        let keyNames = FanMode.allCases.map { "xiaoju.key.\($0.rawValue)" }
        let names = keyNames + ["xiaoju.shelfViewMode"]
        let snapshot = names.reduce(into: [String: Any]()) { result, key in result[key] = defaults.object(forKey: key) }
        defer {
            for name in names {
                if let value = snapshot[name] { defaults.set(value, forKey: name) }
                else { defaults.removeObject(forKey: name) }
            }
            NotificationCenter.default.post(name: KeyMap.didChange, object: nil)
        }
        let preservedNames = ["xiaoju.theme", "xiaoju.convertQuality", "xiaoju.compressPreset", "xiaoju.shelfOrigin", "xiaoju.shelfPinned"]
        let preserved = preservedNames.map { String(describing: defaults.object(forKey: $0)) }
        KeyMap.resetToDefaults()

        expect(FileListKeyAction.action(keyCode: 49, modifiers: []) == .preview, "列表空格触发预览")
        expect(FileListKeyAction.action(keyCode: 49, modifiers: .command) == nil, "不接管系统 Command-Space")
        expect(FileListKeyAction.action(keyCode: 51, modifiers: []) == .remove &&
               FileListKeyAction.action(keyCode: 117, modifiers: []) == .remove, "两种 Delete 均只移除引用")
        expect(FileListKeyAction.action(keyCode: 51, modifiers: .control) == nil, "非约定删除组合继续交给系统")
        expect(FileListKeyAction.action(keyCode: 0, modifiers: .command) == .selectAll, "Command-A 全选")
        expect(FileListKeyAction.action(keyCode: 125, modifiers: .shift) == .move(1, extend: true), "Shift 方向键扩展范围选择")
        expect(FileListKeyAction.action(keyCode: 48, modifiers: []) == nil, "Tab 不被列表快捷键截获")
        let order = (0..<5).map { _ in UUID() }
        var selection = FileListSelection()
        selection.select(order[2], order: order)
        _ = selection.move(1, order: order, extend: true)
        expect(selection.ids == Set(order[2...3]), "主列表 Shift 下扩展到活动项")
        _ = selection.move(-1, order: order, extend: true)
        expect(selection.ids == [order[2]], "主列表反向 Shift 上收缩到锚点")
        _ = selection.move(-1, order: order, extend: true)
        expect(selection.ids == Set(order[1...2]), "主列表跨过锚点向反方向扩展")
        selection.select(order[3], order: order)
        selection.select(order[4], order: order, extend: true)
        expect(selection.ids == Set(order[3...4]), "预览单项重设范围锚点")
        selection.select(order[4], order: order, toggle: true)
        expect(selection.ids == [order[3]], "主列表 Command 点击只切换一次")
        selection.selectAll(order)
        selection.prune(Array(order.prefix(2)))
        expect(selection.ids == Set(order.prefix(2)) && selection.lead == nil, "移除文件同时清理失效活动项")
        _ = selection.move(1, order: Array(order.prefix(3)), extend: true)
        expect(selection.ids == Set(order.prefix(3)), "活动项移除后 Shift 方向键沿剩余选区端点继续")
        selection.clear()
        expect(selection.ids.isEmpty && selection.anchor == nil && selection.lead == nil, "清空选择同时清理两个锚点")
        expect(KeyMap.isDefault && KeyMap.conflicts.isEmpty, "默认快捷键没有重复绑定")
        expect(KeyMap.resolvedMode(for: FanModifiers(shift: true)) == .convert, "Shift 打开转换")
        expect(KeyMap.resolvedMode(for: FanModifiers(option: true)) == .tools, "Option 替代键单独打开工具")
        expect(KeyMap.resolvedMode(for: FanModifiers(command: true)) == .tools, "Command 替代键单独打开工具")
        expect(KeyMap.resolvedMode(for: FanModifiers(control: true)) == .actions, "Control 打开动作")
        expect(KeyMap.resolvedMode(for: FanModifiers()) == nil, "无修饰键不触发花瓣")
        KeyMap.toggle(.shift, for: .convert)
        expect(KeyMap.keys(for: .convert) == [.shift], "最后一个按键不能取消")
        KeyMap.setKeys([], for: .convert)
        expect(KeyMap.keys(for: .convert) == [.shift], "空绑定不会覆盖现有配置")
        KeyMap.toggle(.shift, for: .actions)
        expect(KeyMap.conflicts.contains { $0.key == .shift && $0.owners == [.actions, .convert] }, "重复绑定给出准确归属与优先级")
        expect(KeyMap.resolvedMode(for: FanModifiers(shift: true)) == .actions, "重复绑定提示与运行时触发一致")
        expect(KeyMap.effectiveKey(for: .convert) == nil && KeyMap.conversionDragHint.contains("占用"),
               "全部转换键被占用时主窗口提示冲突而非误导")
        KeyMap.toggle(.option, for: .convert)
        KeyMap.toggle(.option, for: .tools)
        expect(KeyMap.effectiveKey(for: .convert) == .option && KeyMap.conversionDragHint.contains("Option"),
               "主窗口选择实际可触发的替代键")
        KeyMap.toggle(.control, for: .actions)
        expect(KeyMap.keys(for: .actions) == [.shift], "先添加替代键再移除旧键可完成重新绑定")
        expect(KeyMap.resolvedMode(for: FanModifiers(shift: true, option: true)) == .actions, "同时按键保留旧版优先级")
        KeyMap.resetToDefaults()
        expect(KeyMap.isDefault && KeyMap.conflicts.isEmpty, "恢复默认清除自定义与冲突")
        expect(preservedNames.map { String(describing: defaults.object(forKey: $0)) } == preserved,
               "恢复快捷键不改主题质量和浮窗设置")
        defaults.set(0x80, forKey: "xiaoju.key.convert")
        expect(KeyMap.keys(for: .convert) == [.shift], "未知旧掩码回退为可用默认键")
        KeyMap.resetToDefaults()

        do {
            let root = ProbeFixtures.work
            let original = ProbeFixtures.inputs.appendingPathComponent("01-旅行照片-家庭合影-精选修订版.png")
            let originalHash = try hash(original)
            let folder = root.appendingPathComponent("interaction-probe-\(getpid())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = try (0..<18).map { index -> URL in
                let url = folder.appendingPathComponent(String(format: "文件-%02d.png", index))
                try FileManager.default.copyItem(at: original, to: url)
                return url
            }
            defaults.set("list", forKey: "xiaoju.shelfViewMode")
            let canvas = ShelfCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 440))
            canvas.add(urls)
            canvas.selectFile(at: 1)
            canvas.selectFile(at: 4, modifiers: .shift)
            expect(canvas.selection == Set(1...4), "Shift 连续选择与原生列表一致")
            canvas.selectFile(at: 2, modifiers: .command)
            expect(canvas.selection == [1, 3, 4], "Command 点击切换单项选择")
            canvas.toggleViewMode()
            canvas.selectFile(at: 6, modifiers: .shift)
            expect(canvas.selection == Set(2...6), "切换模式保留范围选择锚点")
            canvas.selectAllFiles()
            expect(canvas.selection.count == 18, "全选覆盖全部暂存引用")
            canvas.removeSelected()
            expect(canvas.files.isEmpty && canvas.canUndo, "批量移除保留撤销")
            canvas.undo()
            expect(canvas.files == urls && canvas.selection.count == 18, "批量撤销恢复顺序与多选")
            canvas.selectFile(at: 0)
            for _ in 0..<17 { canvas.moveSelection(by: 1) }
            expect(canvas.selection == [17] && canvas.debugScrollOffset > 0 &&
                   canvas.debugScrollOffset <= canvas.debugMaximumScroll + 0.5, "方向键移动到末项并滚入可视范围")
            canvas.debugToggleCollapse("图片")
            canvas.selectFile(at: 0)
            expect(canvas.selection == [17], "折叠组内的隐藏文件不被范围点击误选")
            canvas.debugToggleCollapse("图片")

            let model = AppModel()
            model.add(urls: Array(urls.prefix(3)))
            let removed = model.files[1]
            let output = folder.appendingPathComponent("保留的转换结果.jpg")
            try Data("synthetic completed output".utf8).write(to: output)
            model.results = [ConversionResult(source: removed.url, output: output, error: nil)]
            model.isConverting = true
            model.remove(removed)
            expect(model.files.count == 3, "处理中不能通过移除操作改输入列表")
            model.isConverting = false
            model.remove(removed)
            expect(model.files.count == 2 && model.results.isEmpty, "移除成功项同时清理其界面结果引用")
            expect(FileManager.default.fileExists(atPath: output.path) &&
                   urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "列表与浮窗移除不删除原件或输出")
            expect(try hash(original) == originalHash, "选择预览和移除回归不修改原图")
        } catch {
            expect(false, "测试样本异常：\(error)")
        }
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    /// 直接比较文件字节，避免仅凭路径存在就声称原件未改变。
    private static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
