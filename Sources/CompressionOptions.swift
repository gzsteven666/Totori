import AppKit
import SwiftUI

/// 压缩档位。原版的三条文案：
///  "Much smaller files with more visible quality loss."
///  "Smaller files with less quality loss."
///  "Better visual quality with moderate file-size savings."
enum CompressionPreset: String, CaseIterable, Identifiable {
    case smaller, balanced, quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smaller:  return "最小体积"
        case .balanced: return "均衡"
        case .quality:  return "最好画质"
        }
    }

    var detail: String {
        switch self {
        case .smaller:  return "更偏向减小体积，结果以实际编码为准"
        case .balanced: return "兼顾画质与体积"
        case .quality:  return "优先保留画质，可能没有体积收益"
        }
    }

    var symbol: String {
        switch self {
        case .smaller:  return "arrow.down.right.and.arrow.up.left"
        case .balanced: return "equal.circle"
        case .quality:  return "sparkles"
        }
    }
}

struct CompressionOptions {
    var jpegQuality: Double = 0.92
    var maxSide: CGFloat? = nil
    var videoCRF: Int = 22
    var preset: CompressionPreset? = nil

    /// 视频码率：只有选了档位才覆盖，未选时保持原有的 6M/8M
    func videoBitrate(fallback: String) -> String {
        guard let preset else { return fallback }
        switch preset {
        case .smaller:  return "2M"
        case .balanced: return "4M"
        case .quality:  return "8M"
        }
    }

    static let none = CompressionOptions()

    /// 普通转换用的默认质量（只影响编码质量，不缩放尺寸）
    static func fromDefaults() -> CompressionOptions {
        let raw = UserDefaults.standard.string(forKey: "xiaoju.convertQuality") ?? ""
        guard let preset = CompressionPreset(rawValue: raw) else { return .none }
        var options = make(preset)
        options.maxSide = nil
        return options
    }

    static func make(_ preset: CompressionPreset) -> CompressionOptions {
        switch preset {
        case .smaller:
            return CompressionOptions(jpegQuality: 0.50, maxSide: 1600, videoCRF: 30, preset: .smaller)
        case .balanced:
            return CompressionOptions(jpegQuality: 0.76, maxSide: 2560, videoCRF: 25, preset: .balanced)
        case .quality:
            return CompressionOptions(jpegQuality: 0.90, maxSide: nil, videoCRF: 19, preset: .quality)
        }
    }
}

// MARK: - 选项面板

@MainActor
final class CompressionPanel {
    static let shared = CompressionPanel()

    private var panel: NSPanel?

    func present(urls: [URL]) {
        guard let first = urls.first else { return }
        let format = FormatCatalog.all.first { $0.ext == first.pathExtension.lowercased() }
        guard let format else {
            let alert = NSAlert()
            alert.messageText = "这种格式不支持压缩"
            alert.runModal()
            return
        }

        let controller = CompressionPanelController(urls: urls, format: format)
        let content = CompressionPanelView(
            controller: controller,
            onStart: { [weak self] preset in
                self?.panel?.orderOut(nil)
                ConversionRunner.run(urls: urls,
                                     format: format,
                                     options: CompressionOptions.make(preset),
                                     isCompression: true)
            },
            onCancel: { [weak self] in self?.panel?.orderOut(nil) }
        )

        let size = NSSize(width: 420, height: 400)
        panel?.orderOut(nil)
        let panel = PanelKit.make(title: "压缩 \(urls.count) 个文件", size: size, content: content)
        self.panel = panel
        PanelKit.present(panel)
    }
}

@MainActor
final class CompressionPanelController: ObservableObject {
    let urls: [URL]
    let format: OutputFormat
    @Published var preset: CompressionPreset
    @Published var guidance: String = ""

    init(urls: [URL], format: OutputFormat) {
        self.urls = urls
        self.format = format
        let saved = UserDefaults.standard.string(forKey: "xiaoju.compressPreset") ?? ""
        self.preset = CompressionPreset(rawValue: saved) ?? .balanced
        updateGuidance()
    }

    func select(_ preset: CompressionPreset) {
        self.preset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "xiaoju.compressPreset")
        updateGuidance()
    }

    private func updateGuidance() {
        guidance = Self.guidance(for: format, preset: preset)
    }

    /// 只描述「当前实现里哪些参数真的生效」，不给没有测量依据的体积预估。
    /// 分支依据 Engine.convertImage / convertMedia 的实际实现：
    ///  - JPEG/HEIC/WebP/PNG/TIFF 会走 downscaled(maxSide:)，smaller=1600 / balanced=2560 / quality=不限；PNG/TIFF 另不使用质量参数
    ///  - AVIF/JP2 走 sips 的 quality，不改尺寸
    ///  - WebP 走 cwebp（质量参数；尺寸上限随档位）
    ///  - BMP/GIF 无质量参数
    ///  - MP4/MOV 用档位码率，MKV 用 CRF，其余容器固定参数
    static func guidance(for format: OutputFormat, preset: CompressionPreset) -> String {
        let ext = format.ext.lowercased()
        let options = CompressionOptions.make(preset)
        let quality = Int(options.jpegQuality * 100)
        let side = options.maxSide.map { "长边最多 \(Int($0)) px" } ?? "保持原尺寸"

        switch format.kind {
        case .image:
            switch ext {
            case "jpg", "jpeg", "heic", "webp":
                return "按所选画质重新编码：质量 \(quality)、\(side)。\n实际体积取决于画面内容，完成后显示节省量。"
            case "png":
                return "保持 PNG 格式，\(side)。PNG 不使用有损画质参数；缩小尺寸会减少像素。\n实际体积取决于内容，完成后显示节省量。"
            case "tiff", "tif":
                return "保持 TIFF 格式，\(side)。\n实际体积取决于像素与编码结果，完成后显示节省量。"
            case "avif", "jp2":
                return "按所选画质重新编码：质量 \(quality)，不改尺寸。\n实际体积取决于画面内容，完成后显示节省量。"
            case "bmp":
                return "BMP 是未压缩位图，不使用画质参数，体积基本由尺寸决定；\n想变小请改转 JPEG / WebP / PNG。"
            case "gif":
                return "GIF 使用 256 色调色板，不使用画质参数；\n想变小请改转 WebP。"
            default:
                return "该格式不使用画质参数；体积取决于内容。"
            }
        case .media:
            switch ext {
            case "mp4", "mov":
                return "按所选画质重新编码：视频码率 \(options.videoBitrate(fallback: "6M"))，音频重新编码。\n实际体积取决于时长与画面，完成后显示节省量。"
            case "mkv":
                return "按所选画质重新编码：视频使用画质参数（CRF），音频重新编码。\n实际体积取决于时长与画面，完成后显示节省量。"
            default:
                return "该容器使用固定编码参数，档位不改变码率；\n体积取决于时长与画面内容。"
            }
        case .document:
            return "文档按目标格式重新生成，画质档位不适用；体积取决于内容。"
        case .archive:
            return "归档按外层打包写出，画质档位不适用。"
        case .unknown:
            return "无法识别文件类型。"
        }
    }
}

struct CompressionPanelView: View {
    @ObservedObject var controller: CompressionPanelController
    var onStart: (CompressionPreset) -> Void
    var onCancel: () -> Void

    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(CompressionPreset.allCases) { preset in
                Button {
                    controller.select(preset)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text(preset.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        if controller.preset == preset {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.tint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(controller.preset == preset
                                  ? theme.tint.opacity(0.20)
                                  : Palette.surfaceSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(controller.preset == preset
                                                  ? theme.tint.opacity(0.75)
                                                  : Color.clear, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Text(controller.guidance)
                .font(.system(size: 10))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("开始压缩") { onStart(controller.preset) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 380, height: 320)
        .tint(theme.tint)
        .background(Palette.surface)
    }
}
