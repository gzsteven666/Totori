import Foundation

/// 本次转换的质量覆盖值，只保存在模型内；“默认”在开始批次时读取全局偏好。
enum TaskConversionQuality: String, CaseIterable, Identifiable {
    case defaults, smaller, balanced, quality
    var id: String { rawValue }

    var title: String {
        if let preset = CompressionPreset(rawValue: rawValue) { return preset.title }
        return "默认"
    }

    /// 普通转换只改变编码质量，保留源图片尺寸；批次创建后由 BatchPlan 固定这些值。
    var options: CompressionOptions {
        guard let preset = CompressionPreset(rawValue: rawValue) else { return .fromDefaults() }
        var options = CompressionOptions.make(preset)
        options.maxSide = nil
        return options
    }
}

extension OutputFormat {
    /// 仅对现有后端确实使用质量参数的格式显示入口，避免提供不起作用的选项。
    var supportsTaskQuality: Bool {
        switch kind {
        case .image: return ["jpg", "jpeg", "heic", "webp", "avif", "jp2"].contains(ext.lowercased())
        case .media: return ["mp4", "mov", "mkv"].contains(ext.lowercased())
        default: return false
        }
    }
}
