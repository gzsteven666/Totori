import AppKit
import SwiftUI

/// 晨雾 · 流转 的色板与材质规范。
/// 数据来自 design-tokens.json：浅/深两套，界面跟随系统外观。
enum Palette {
    // MARK: 动态颜色

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let canvas            = dynamic(light: 0xF0F5EC, dark: 0x142019)
    static let surface           = dynamic(light: 0xFBFCF8, dark: 0x213126)
    static let surfaceSecondary  = dynamic(light: 0xE7EFDF, dark: 0x2B4030)
    static let textPrimary       = dynamic(light: 0x283B2B, dark: 0xEEF7E8)
    static let textSecondary     = dynamic(light: 0x5C735A, dark: 0xB8CDAE)
    static let line              = dynamic(light: 0xC7D7BF, dark: 0x456144)
    static let brand             = dynamic(light: 0x376D47, dark: 0xAFD795)
    static let brandHover        = dynamic(light: 0x2D5A3A, dark: 0xC7E8B0)
    static let brandSoft         = dynamic(light: 0xDFEFD4, dark: 0x304D31)
    static let success           = dynamic(light: 0x2D6A4F, dark: 0x8CCBA3)
    static let danger            = dynamic(light: 0xB53832, dark: 0xFFAAA2)
    static let focus             = dynamic(light: 0x346C43, dark: 0xCCE9B6)
    /// 强调色上的前景：浅色下用白，深色下用深墨绿，避免白字压在 #AFD795 上（对比 1.62 → 7+）
    static let onAccent          = dynamic(light: 0xFFFFFF, dark: 0x152C1D)

    /// 品牌玻璃渐变，仅用于图标与展示材质
    static let glassTop    = dynamic(light: 0xE5F3D8, dark: 0x2F4A33)
    static let glassBottom = dynamic(light: 0xB4D69D, dark: 0x1C2E20)

    // MARK: 尺度

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let window: CGFloat = 16
        static let popover: CGFloat = 14
    }

    enum TypeSize {
        static let title: CGFloat = 20
        static let section: CGFloat = 13
        static let body: CGFloat = 13
        static let caption: CGFloat = 11
    }

    // MARK: 辅助功能

    /// 系统「降低透明度」打开时，材质退化为实色，保证可读性
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// 浮层通用底板：优先系统材质，降低透明度时退回实色
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = Palette.Radius.popover
    var tintOpacity: Double = 0.14
    var strokeOpacity: Double = 0.55

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Palette.reduceTransparency ? AnyShapeStyle(Palette.surface) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Palette.brand.opacity(Palette.reduceTransparency ? 0 : tintOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 0.8)
                )
        )
    }
}

/// 龙猫小手素材（浅灰手背 / 合拢两帧）
enum PawAssets {
    static let open: NSImage? = load("totori-paw-open")
    static let grasp: NSImage? = load("totori-paw-grasp")

    private static func load(_ name: String) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        image.isTemplate = false
        return image
    }
}

/// 主题小样：胶囊 + 图标 + 文字，设置预览与自检共用
struct ThemeSwatch: View {
    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [theme.glassTop, theme.glassBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.8))
            .overlay(
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .medium))
                        .accessibilityHidden(true)
                    Text("示例").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(theme.ink)
            )
            .frame(width: 96, height: 30)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = Palette.Radius.popover,
                      tintOpacity: Double = 0.14,
                      strokeOpacity: Double = 0.55) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius,
                              tintOpacity: tintOpacity,
                              strokeOpacity: strokeOpacity))
    }
}
