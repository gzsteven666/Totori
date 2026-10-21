import AppKit

/// 浮窗增强回归：拖出提示与撤销、紧凑/展开尺寸与持久化、拖动期间不缩放、原件不动。
@MainActor
enum ShelfEnhancementProbe {
    static func run() -> Int32 {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✕") \(label)")
        }

        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousCompact = defaults.object(forKey: "xiaoju.shelfCompact")
        let previousOrigin = defaults.object(forKey: "xiaoju.shelfOrigin")
        let previousPin = defaults.object(forKey: "xiaoju.shelfPinned")
        defer {
            for (key, value) in [("xiaoju.shelfCompact", previousCompact),
                                 ("xiaoju.shelfOrigin", previousOrigin),
                                 ("xiaoju.shelfPinned", previousPin)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "xiaoju.shelfCompact")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-enhance-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [URL] = []
        for index in 1...3 {
            let url = folder.appendingPathComponent("样本\(index).png")
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: 64))
            urls.append(url)
        }

        print("== 浮窗增强 ==")
        let canvas = ShelfCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 440))
        canvas.add(urls)
        expect(canvas.files.count == 3, "添加 3 个文件")

        canvas.selection = [0, 1]
        canvas.debugSimulateDelivery(urls: [urls[0], urls[1]])
        expect(canvas.files.count == 1, "拖出交付后移除 2 个")
        expect(canvas.notice == "已拖出 2 个", "显示已拖出数量")
        expect(canvas.canUndo, "拖出后可撤销")

        canvas.undo()
        expect(canvas.files.count == 3, "撤销恢复 3 个")
        expect(canvas.notice == "已撤销", "撤销后提示一致")

        canvas.debugSimulateCancel(urls: [urls[0]])
        expect(canvas.files.count == 3, "取消不移除")
        canvas.debugSimulateReturn(urls: [urls[0]])
        expect(canvas.files.count == 3 && canvas.notice != "已拖出 1 个", "拖回自身不伪报成功")

        canvas.selection = [2]
        canvas.removeSelected()
        expect(canvas.files.count == 2 && canvas.notice == "已移除 1 个", "手动移除有提示")
        canvas.undo()
        expect(canvas.files.count == 3, "手动移除可撤销")

        canvas.clear()
        expect(canvas.files.count == 0 && canvas.notice == "已清空 3 个", "清空有提示")
        canvas.undo()
        expect(canvas.files.count == 3, "清空可撤销")

        expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "磁盘原件未被删除")

        let shelf = FileShelf.shared
        shelf.show()
        expect(shelf.debugFrame.height == FileShelf.regularHeight, "默认普通高度 440")
        expect(shelf.toggleCompact(), "可切换紧凑")
        expect(shelf.debugFrame.height == FileShelf.compactHeight, "紧凑高度 260")
        expect(UserDefaults.standard.bool(forKey: "xiaoju.shelfCompact"), "紧凑写入偏好")
        shelf.toggleCompact()
        expect(shelf.debugFrame.height == FileShelf.regularHeight, "可切回普通")

        shelf.debugCanvas?.debugSetDragSession(true)
        expect(shelf.toggleCompact() == false, "拖动会话中拒绝切换")
        expect(shelf.debugFrame.height == FileShelf.regularHeight, "拒绝切换时尺寸不变")
        shelf.debugCanvas?.debugSetDragSession(false)

        // 外部拖入：进入/退出后可切换
        shelf.debugCanvas?.debugSetDestinationDragSession(true)
        expect(shelf.toggleCompact() == false, "外部拖入期间拒绝切换")
        shelf.debugCanvas?.debugSetDestinationDragSession(false)
        expect(shelf.toggleCompact(), "外部进入退出后可切换")
        expect(shelf.debugFrame.height == FileShelf.compactHeight, "退出后尺寸生效")
        shelf.toggleCompact()

        // 源会话：离开目标区不解除保护
        shelf.debugCanvas?.debugSetDragSession(true)
        shelf.debugCanvas?.debugSetDestinationDragSession(true)
        shelf.debugCanvas?.debugSetDestinationDragSession(false)
        expect(shelf.toggleCompact() == false, "源会话离开目标仍拒绝切换")
        expect(shelf.debugFrame.height == FileShelf.regularHeight, "源会话尺寸不变")
        shelf.debugCanvas?.debugSetDragSession(false)
        shelf.hide()

        print(failures == 0 ? "结果：浮窗增强 OK ✅" : "结果：\(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }
}
