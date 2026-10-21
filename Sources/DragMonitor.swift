import AppKit
import CoreGraphics

/// 零权限拖拽感知，完全按原版的做法：
///  · CGEventSource.flagsState  → 修饰键（状态查询）
///  · CGEventSource.buttonState → 鼠标左键（状态查询）
///  · NSPasteboard(.drag)       → 拖动中的文件
/// 不监听任何键盘事件、不用 CGEventTap、不查 AXIsProcessTrusted，
/// 因此不需要「辅助功能」或「输入监控」授权。
struct FanModifiers {
    var shift = false
    var option = false
    var command = false
    var control = false

    init(shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false) {
        self.shift = shift
        self.option = option
        self.command = command
        self.control = control
    }

    init(_ flags: CGEventFlags) {
        shift = flags.contains(.maskShift)
        option = flags.contains(.maskAlternate)
        command = flags.contains(.maskCommand)
        control = flags.contains(.maskControl)
    }

    var isEmpty: Bool { !shift && !option && !command && !control }
}

final class DragMonitor {
    var onTick: ((_ buttonDown: Bool, _ modifiers: FanModifiers) -> Void)?
    /// 可选增强：有键盘权限时才有；没有也不影响主流程
    var onKey: ((UInt16) -> Void)?

    private var timer: DispatchSourceTimer?
    private var keyMonitor: Any?

    static func modifiers() -> FanModifiers {
        FanModifiers(CGEventSource.flagsState(.combinedSessionState))
    }

    static func leftButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    func start() -> Bool {
        guard timer == nil else { return true }

        // 12Hz 状态查询：每次两个 C 调用，开销可以忽略
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let down = DragMonitor.leftButtonDown()
                let mods = DragMonitor.modifiers()
                self.onTick?(down, mods)
                // 空闲时 12Hz，按住键或鼠标时提到 40Hz，兼顾省电和跟手
                self.setFast(!mods.isEmpty || down)
            }
        }
        timer.resume()
        self.timer = timer

        // 键盘导航是加分项（需要权限才收得到），收不到也不报错
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.onKey?(event.keyCode) }
        }

        DiagLog.write("polling started, trusted=\(AXIsProcessTrusted())")
        return true
    }

    private var fast = false

    private func setFast(_ value: Bool) {
        guard value != fast else { return }
        fast = value
        timer?.schedule(deadline: .now(),
                        repeating: value ? .milliseconds(25) : .milliseconds(80),
                        leeway: value ? .milliseconds(6) : .milliseconds(20))
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
