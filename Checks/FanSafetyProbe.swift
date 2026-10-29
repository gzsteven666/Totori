import AppKit

/// 取消手势回归：驱动控制器状态，不发送桌面事件，也不执行转换或文件动作。
@MainActor
enum FanSafetyProbe {
    /// 验证 Esc 后的同次按住不会重新打开花瓣，抬起后新手势与菜单仍可使用。
    static func run() -> Int32 {
        _ = NSApplication.shared
        var failed = 0, passed = 0
        func expect(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failed += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let controller = FanController.shared
        let file = ProbeFixtures.inputs.appendingPathComponent("抓取测试-B.png")
        controller.debugSuppressActions = true
        defer {
            controller.hide()
            controller.tick(buttonDown: false, modifiers: FanModifiers(), at: .zero)
            controller.debugSuppressActions = false
        }
        let point = NSPoint(x: 600, y: 400)
        controller.tick(buttonDown: false, modifiers: FanModifiers(), at: point)
        controller.debugPresentDrag(urls: [file])
        controller.debugHighlight(1)
        let before = controller.debugApplyCount
        controller.debugKey(53)
        expect(!controller.debugVisible && controller.model.pawPhase == .idle, "Esc 收起花瓣并复位爪子")
        for index in 0..<50 {
            controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true),
                            at: NSPoint(x: point.x + CGFloat(index * 10), y: point.y))
        }
        expect(!controller.debugVisible, "Esc 后同次按住并移动不重开花瓣")
        controller.tick(buttonDown: false, modifiers: FanModifiers(shift: true), at: NSPoint(x: 1090, y: 400))
        expect(controller.debugApplyCount == before, "取消后的松手不执行缓存目标")
        SimulatedDrag.begin([file])   // 来源应用开始新的文件拖动
        controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: point)
        controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: NSPoint(x: 620, y: 400))
        expect(controller.debugVisible, "抬起后下一次拖动可以重新呼出花瓣")
        controller.hide()
        controller.tick(buttonDown: false, modifiers: FanModifiers(), at: point)

        // 没有新的文件拖动时，修饰键 + 按住鼠标 + 移动（例如 Excel 里按 ⌘ 拖选多列）不能呼出花瓣，
        // 即使拖放粘贴板里还留着上一次拖动的文件
        SimulatedDrag.begin([file])                     // 上一次拖动的残留
        controller.tick(buttonDown: false, modifiers: FanModifiers(command: true), at: point)
        controller.tick(buttonDown: true, modifiers: FanModifiers(command: true), at: point)
        for step in 1...20 {
            controller.tick(buttonDown: true, modifiers: FanModifiers(command: true),
                            at: NSPoint(x: point.x + CGFloat(step * 12), y: point.y))
        }
        expect(!controller.debugVisible, "拖放粘贴板里是旧文件、没有新拖动：⌘ + 拖动不呼出花瓣")
        controller.tick(buttonDown: false, modifiers: FanModifiers(command: true), at: NSPoint(x: 900, y: 400))
        expect(controller.debugApplyCount == before, "没有呼出时松手不执行任何动作")

        // 新的拖动不含文件（拖文字）：同样不呼出
        controller.tick(buttonDown: false, modifiers: FanModifiers(command: true), at: point)
        SimulatedDrag.beginText()
        controller.tick(buttonDown: true, modifiers: FanModifiers(command: true), at: point)
        controller.tick(buttonDown: true, modifiers: FanModifiers(command: true), at: NSPoint(x: point.x + 60, y: point.y))
        expect(!controller.debugVisible, "拖的不是文件：不呼出花瓣")
        controller.tick(buttonDown: false, modifiers: FanModifiers(), at: point)

        // 先按住鼠标开始拖，之后才有新的文件拖动（来源应用稍后才写入粘贴板）：仍应呼出
        controller.tick(buttonDown: false, modifiers: FanModifiers(command: true), at: point)
        controller.tick(buttonDown: true, modifiers: FanModifiers(command: true), at: point)
        controller.tick(buttonDown: true, modifiers: FanModifiers(command: true), at: NSPoint(x: point.x + 20, y: point.y))
        expect(!controller.debugVisible, "拖动还没开始（粘贴板未变）：暂不呼出")
        SimulatedDrag.begin([file])
        controller.tick(buttonDown: true, modifiers: FanModifiers(command: true), at: NSPoint(x: point.x + 40, y: point.y))
        expect(controller.debugVisible, "文件拖动随后开始：呼出花瓣")
        controller.hide()
        controller.tick(buttonDown: false, modifiers: FanModifiers(), at: point)
        controller.debugPresentMenuMode(urls: [file])
        let beforeMenu = controller.debugApplyCount
        controller.debugClick(at: 1)
        controller.debugClick(at: 1)
        expect(controller.debugApplyCount == beforeMenu + 1 && !controller.debugVisible, "菜单入口仍执行一次并收起")
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
