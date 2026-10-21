import AppKit

/// 覆盖常用格式的保存、固定位置和“更多”分流；探针禁止执行文件动作并恢复测试偏好。
@MainActor
enum FavoriteFormatsProbe {
    static func run() -> Int32 {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let preferenceKeys = FavoriteFormats.configurableKinds.map(FavoriteFormats.storageKey)
        let snapshot = preferenceKeys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        let controller = FanController.shared
        controller.debugSuppressActions = true
        defer {
            controller.hide()
            controller.tick(buttonDown: false, modifiers: FanModifiers(), at: .zero)
            controller.debugSuppressActions = false
            for key in preferenceKeys {
                if let value = snapshot[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        var passed = 0, failed = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let base = URL(fileURLWithPath: "/Users/mac/Documents/Codex/2026-10-19/zhe/work/iteration8/native-inputs")
        let png = base.appendingPathComponent("02-透明图层.png")
        let jpeg = base.appendingPathComponent("02-透明图层.jpg")
        let before = try? Data(contentsOf: png)
        FavoriteFormats.reset(.image)
        FavoriteFormats.reset(.media)
        FavoriteFormats.reset(.document)
        expect(FavoriteFormats.formats(for: .image).map(\.ext) == ["png", "jpg", "heic", "webp"], "默认图片四项顺序固定")
        let normalized = FavoriteFormats.normalized([".JPG", "jpg", "not-valid", "png"], kind: .image)
        expect(normalized == ["jpg", "png", "heic", "webp"], "无效和重复项过滤后补足四个")
        expect(FavoriteFormats.normalized(FormatCatalog.images.map(\.ext), kind: .image).count == 6, "常用最多六项")
        expect(FavoriteFormats.formats(for: .archive).map(\.ext) == ["zip"] && FavoriteFormats.formats(for: .unknown).isEmpty,
               "格式不足四个时保留全部，未知类型保持空")
        FavoriteFormats.set(["jpg", "png", "heic", "webp"], for: .image)
        expect(defaults.stringArray(forKey: FavoriteFormats.storageKey(.image)) == ["jpg", "png", "heic", "webp"],
               "用户指定顺序持久化保存")
        controller.debugPresentMenuMode(urls: [png])
        let ids = controller.model.items.map(\.id)
        let centers = controller.model.items.indices.map { controller.model.petalCenter($0) }
        expect(ids.count == 5 && ids.first == "f.image.jpg" && ids.last == "more.image", "常用四项加一个更多入口")
        FavoriteFormats.set(["webp", "jpg", "png", "heic"], for: .image)
        controller.debugPopulate([jpeg])
        expect(controller.model.items.map(\.id) == ids && controller.model.items.indices.map { controller.model.petalCenter($0) } == centers,
               "花瓣已展开时改设置及重新进入拖放区域，不改变顺序或角度")
        controller.hide()
        controller.debugPresentMenuMode(urls: [png])
        expect(controller.model.items.first?.id == "f.image.webp", "新顺序在下次呼出时生效")
        let beforeMore = controller.debugMoreRequests
        controller.debugClick(at: controller.model.items.count - 1)
        controller.debugClick(at: 4)
        expect(controller.debugMoreRequests == beforeMore + 1 && !controller.debugVisible, "更多菜单只分流一次并收起花瓣")
        controller.debugPresentDrag(urls: [png])
        let beforeApply = controller.debugApplyCount
        controller.debugHighlight(0)
        controller.tick(buttonDown: false, modifiers: FanModifiers(shift: true), at: .zero)
        expect(controller.debugApplyCount == beforeApply + 1 && controller.debugMoreRequests == beforeMore + 1 && !controller.debugVisible,
               "常用格式拖动松手仍执行一次，不进入更多")
        controller.debugPresentDrag(urls: [png])
        let moreIndex = controller.model.items.count - 1
        controller.debugHighlight(moreIndex)
        let hoverCount = controller.debugMoreRequests
        expect(hoverCount == beforeMore + 1 && controller.debugVisible, "只高亮更多不会提前打开或转换")
        controller.debugKey(53)
        controller.tick(buttonDown: false, modifiers: FanModifiers(), at: .zero)
        expect(controller.debugMoreRequests == hoverCount && !controller.debugVisible && controller.model.pawPhase == .idle,
               "更多高亮后Esc取消不分流并收回爪子")
        controller.debugPresentDrag(urls: [png])
        controller.tick(buttonDown: true, modifiers: FanModifiers(option: true), at: NSEvent.mouseLocation)
        expect(controller.debugMode == .tools && abs((controller.debugLayer?.bounds.width ?? 0) - controller.model.canvas) < 1,
               "常用轮切到工具轮时窗口同步变大，不裁切花瓣")
        controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: NSEvent.mouseLocation)
        expect(controller.debugMode == .convert && abs((controller.debugLayer?.bounds.width ?? 0) - controller.model.canvas) < 1 && controller.model.items.first?.id == "f.image.webp",
               "切回常用轮窗口同步恢复，顺序快照保留")
        controller.hide()
        for (kind, name) in [(FileKind.document, "样本.txt"), (.media, "样本.mp4"), (.archive, "样本.zip")] {
            controller.showMenu(mode: .convert, urls: [base.appendingPathComponent(name)])
            let hasMore = controller.model.items.contains { if case .moreFormats = $0 { return true }; return false }
            expect(hasMore == (FormatCatalog.formats(for: kind).count > 6), "\(kind.title)的更多入口与完整格式数量一致")
            controller.hide()
        }
        expect((try? Data(contentsOf: png)) == before, "常用格式配置与状态回归不修改原件")
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
