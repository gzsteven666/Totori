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
        controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: point)
        controller.tick(buttonDown: true, modifiers: FanModifiers(shift: true), at: NSPoint(x: 620, y: 400))
        expect(controller.debugVisible, "抬起后下一次拖动可以重新呼出花瓣")
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
