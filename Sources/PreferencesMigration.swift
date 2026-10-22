import Foundation

/// 把旧版本（bundle id `com.local.xiaoju.convert`，偏好键前缀 `xiaoju.`）的设置带到新名字下。
///
/// 改 bundle id 后系统会换一个偏好域，不迁移的话主题、浮窗位置、常用格式、快捷键等设置都会回到默认。
/// 只复制，不删除旧域；新键已有值时不覆盖，所以重复运行是安全的。
enum PreferencesMigration {
    static let legacyDomain = "com.local.xiaoju.convert"
    static let legacyPrefix = "xiaoju."
    static let currentPrefix = "totori."
    private static let doneKey = "totori.preferencesMigrated"

    /// 应用启动时调用一次。返回迁移的键数（已迁移过或没有旧设置时为 0）。
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            legacy: [String: Any]? = nil) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let source = legacy ?? defaults.persistentDomain(forName: legacyDomain) ?? [:]
        var moved = 0
        for (key, value) in source where key.hasPrefix(legacyPrefix) {
            let target = currentPrefix + key.dropFirst(legacyPrefix.count)
            guard defaults.object(forKey: target) == nil else { continue }
            defaults.set(value, forKey: target)
            moved += 1
        }
        defaults.set(true, forKey: doneKey)
        return moved
    }
}
