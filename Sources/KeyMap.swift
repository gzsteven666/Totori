import AppKit

/// 三个滚轮各自的修饰键。原版是 conversionWheelDragModifierMask /
/// actionsWheelDragModifierMask 这种可配置掩码，这里做成同样的可改项。
enum WheelKey: String, CaseIterable, Identifiable {
    case shift, option, control, command

    var id: String { rawValue }

    var rawBit: Int { WheelKey.allCases.firstIndex(of: self) ?? 0 }

    var symbol: String {
        switch self {
        case .shift:   return "⇧"
        case .option:  return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        }
    }

    var title: String {
        switch self {
        case .shift:   return "Shift"
        case .option:  return "Option"
        case .control: return "Control"
        case .command: return "Command"
        }
    }

    /// 同时显示符号与名称，避免只认识键帽文字的用户猜测符号。
    var displayName: String { "\(symbol) \(title)" }

    /// 按住这个键时，Finder 会做什么？
    var finderNote: String? {
        switch self {
        case .command: return "访达跨磁盘拖动时，Command 会改为移动；同时按 Command + Option 才是制作替身。"
        case .option:  return "访达拖动时，Option 会改为拷贝，光标通常带 +。"
        case .control: return "Control 单击会打开系统快捷菜单；请先开始拖动，再按住快捷键。"
        case .shift:   return nil
        }
    }

    func matches(_ modifiers: FanModifiers) -> Bool {
        switch self {
        case .shift:   return modifiers.shift
        case .option:  return modifiers.option
        case .control: return modifiers.control
        case .command: return modifiers.command
        }
    }
}

enum KeyMap {
    private static let defaults = UserDefaults.standard
    static let didChange = Notification.Name("TotoriKeyBindingsDidChange")
    /// 与运行时保持同一优先级；旧的重复绑定继续工作，设置页会解释结果。
    static let priority: [FanMode] = [.actions, .tools, .convert]

    /// 每个滚轮可以绑多个键（原版就是 modifier mask 语义）
    static func keys(for mode: FanMode) -> Set<WheelKey> {
        guard let raw = defaults.object(forKey: storageKey(mode)) as? Int else {
            return fallback(mode)
        }
        let set = Set(WheelKey.allCases.enumerated()
            .filter { raw & (1 << $0.offset) != 0 }
            .map { $0.element })
        return set.isEmpty ? fallback(mode) : set
    }

    static func setKeys(_ keys: Set<WheelKey>, for mode: FanMode) {
        guard !keys.isEmpty else { return }      // 至少留一个
        let raw = keys.reduce(0) { $0 | (1 << $1.rawBit) }
        defaults.set(raw, forKey: storageKey(mode))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func toggle(_ key: WheelKey, for mode: FanMode) {
        var current = keys(for: mode)
        if current.contains(key) {
            guard current.count > 1 else { return }   // 不允许清空
            current.remove(key)
        } else {
            current.insert(key)
        }
        setKeys(current, for: mode)
    }

    static func matches(_ mode: FanMode, _ modifiers: FanModifiers) -> Bool {
        keys(for: mode).contains { $0.matches(modifiers) }
    }

    /// 主键（菜单里显示、自检用）
    static func primaryKey(for mode: FanMode) -> WheelKey {
        let set = keys(for: mode)
        return WheelKey.allCases.first { set.contains($0) } ?? .shift
    }

    /// 只展示单独按下确实能触发该花瓣的键；不能把被高优先级占用的键当成引导。
    static func effectiveKey(for mode: FanMode) -> WheelKey? {
        WheelKey.allCases.first { key in
            keys(for: mode).contains(key) && priority.first(where: { keys(for: $0).contains(key) }) == mode
        }
    }

    static var conversionDragHint: String {
        if let key = effectiveKey(for: .convert) {
            return "拖动文件时按住 \(key.displayName)，呼出格式花瓣"
        }
        return "转换快捷键被其他花瓣占用，请在设置中调整"
    }

    /// 拖动时按任意一个已绑定键即可；同时满足多类时按旧版优先级处理。
    static func resolvedMode(for modifiers: FanModifiers) -> FanMode? {
        priority.first { matches($0, modifiers) }
    }

    /// 重复绑定只提示，不静默转移按键或清空用户已有配置。
    static var conflicts: [(key: WheelKey, owners: [FanMode])] {
        WheelKey.allCases.compactMap { key in
            let owners = priority.filter { keys(for: $0).contains(key) }
            return owners.count > 1 ? (key, owners) : nil
        }
    }

    /// 只恢复这三类快捷键；主题、质量、浮窗和其他偏好不受影响。
    static func resetToDefaults() {
        for mode in FanMode.allCases { defaults.removeObject(forKey: storageKey(mode)) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var isDefault: Bool {
        FanMode.allCases.allSatisfy { keys(for: $0) == fallback($0) }
    }

    /// 默认：⇧ 转换、⌘ 或 ⌥ 打开工具、⌃ 打开动作。多个键是替代关系。
    private static func fallback(_ mode: FanMode) -> Set<WheelKey> {
        switch mode {
        case .convert: return [.shift]
        case .tools:   return [.command, .option]
        case .actions: return [.control]
        }
    }

    private static func storageKey(_ mode: FanMode) -> String {
        "xiaoju.key.\(mode.rawValue)"
    }
}
