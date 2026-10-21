import Foundation

/// 设置页的纯呈现状态：分类、说明文案。不含任何偏好读写。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case operation, conversion, appearance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .operation: return "操作"
        case .conversion: return "转换"
        case .appearance: return "外观"
        }
    }
}

enum SettingsPresentation {
    static let categories = SettingsCategory.allCases

    static let qualityHint = "用于支持质量设置的图片与视频；普通转换不改变图片尺寸。“不指定”使用各格式默认质量。"
    static let compressHint = "只影响压缩工具。部分图片会缩小尺寸；最终体积以实际输出为准，没有减小体积时保留原文件。"

    /// 按当前选择说明使用场景，复用压缩档位定义，避免与实际参数产生两套解释。
    static func qualityScene(_ raw: String) -> String {
        switch CompressionPreset(rawValue: raw) {
        case .smaller: return "适合分享或快速传输；\(CompressionPreset.smaller.detail)。"
        case .balanced: return "适合日常使用；\(CompressionPreset.balanced.detail)。"
        case .quality: return "适合保留细节；\(CompressionPreset.quality.detail)。"
        case nil: return "适合常规转换；需要控制体积或画质时再选择档位。"
        }
    }
    static let modifierHelp = "⌘ Command、⌥ Option、⌃ Control 在访达里本身有含义（移动、复制、快捷菜单等）。若这些修饰键已被系统占用，换一个或用默认的 ⇧ Shift。"
    static let shortcutHint = "拖动文件时按住任一已启用按键即可呼出对应花瓣；多个按键是替代键，不必同时按。带锁的按键必须先用另一个键替代才能取消。"
    static let favoritesHint = "固定 4—6 个常用格式与排列顺序，其余从“更多”选择；下次呼出生效，拖动期间位置不变。"
}
