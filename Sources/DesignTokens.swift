import AppKit
import SwiftUI

/// 一个主题在浅 / 深外观下各取一个十六进制色。
typealias ThemeColor = (light: UInt32, dark: UInt32)

/// 一套完整的界面色板。四个主题各一份，主窗口、浮窗、设置等界面都从这里取色，
/// 这样切换主题时强调色和底色整体一起变，不会出现花瓣是蓝、按钮仍是绿的割裂。
struct ThemeColors {
    let canvas: ThemeColor
    let surface: ThemeColor
    let surfaceSecondary: ThemeColor
    let textPrimary: ThemeColor
    let textSecondary: ThemeColor
    let line: ThemeColor
    let brand: ThemeColor
    let brandHover: ThemeColor
    let brandSoft: ThemeColor
    let focus: ThemeColor
    /// 强调色上的前景：浅色下用白，深色下用深墨色，避免白字压在浅色强调色上
    let onAccent: ThemeColor
    let glassTop: ThemeColor
    let glassBottom: ThemeColor
}

extension FanTheme {
    /// 各主题的文字、强调色与底色对比度都按浅色下 ≥ 4.4、深色下 ≥ 6.6 校验过，与森林绿持平。
    var colors: ThemeColors {
        switch self {
        case .forest:
            return ThemeColors(
                canvas: (0xF0F5EC, 0x142019), surface: (0xFBFCF8, 0x213126),
                surfaceSecondary: (0xE7EFDF, 0x2B4030),
                textPrimary: (0x283B2B, 0xEEF7E8), textSecondary: (0x5C735A, 0xB8CDAE),
                line: (0xC7D7BF, 0x456144),
                brand: (0x376D47, 0xAFD795), brandHover: (0x2D5A3A, 0xC7E8B0),
                brandSoft: (0xDFEFD4, 0x304D31), focus: (0x346C43, 0xCCE9B6),
                onAccent: (0xFFFFFF, 0x152C1D),
                glassTop: (0xE5F3D8, 0x2F4A33), glassBottom: (0xB4D69D, 0x1C2E20))
        case .haze:
            return ThemeColors(
                canvas: (0xF0F5F9, 0x131C24), surface: (0xFAFCFD, 0x1E2B36),
                surfaceSecondary: (0xE4EDF4, 0x293A48),
                textPrimary: (0x1F3445, 0xE9F3FA), textSecondary: (0x566F82, 0xB3C8D8),
                line: (0xC3D3E0, 0x3F5A70),
                brand: (0x2F6F94, 0x9FD3F0), brandHover: (0x255A78, 0xBFE3F7),
                brandSoft: (0xDCEEF8, 0x27465E), focus: (0x2F6F94, 0xBFE3F7),
                onAccent: (0xFFFFFF, 0x0F2A3D),
                glassTop: (0xE1F1FA, 0x2B4558), glassBottom: (0xA9CDE3, 0x1B2D3B))
        case .aqua:
            return ThemeColors(
                canvas: (0xEFF3FA, 0x121A28), surface: (0xFAFBFE, 0x1C2638),
                surfaceSecondary: (0xE2EAF6, 0x283650),
                textPrimary: (0x1B2A45, 0xE8EFFB), textSecondary: (0x52668A, 0xB1C4E6),
                line: (0xC2CFE6, 0x3C5280),
                brand: (0x1F5FBF, 0x8CBBFF), brandHover: (0x174C9A, 0xB3D2FF),
                brandSoft: (0xDAE6FA, 0x233B63), focus: (0x1F5FBF, 0xB3D2FF),
                onAccent: (0xFFFFFF, 0x0E2447),
                glassTop: (0xDCEBFF, 0x2A4268), glassBottom: (0xA3C4F2, 0x192640))
        case .mint:
            return ThemeColors(
                canvas: (0xEEF7F3, 0x12211C), surface: (0xF9FDFB, 0x1C3029),
                surfaceSecondary: (0xDDEFE7, 0x27443A),
                textPrimary: (0x17372D, 0xE6F7F0), textSecondary: (0x4F7367, 0xAFD3C5),
                line: (0xBCD9CD, 0x3A6455),
                brand: (0x0D7A5A, 0x7FE3BE), brandHover: (0x0A6148, 0xA6EFD2),
                brandSoft: (0xD4F2E5, 0x1F4D3E), focus: (0x0D7A5A, 0xA6EFD2),
                onAccent: (0xFFFFFF, 0x0B2A20),
                glassTop: (0xD3F5E5, 0x285243), glassBottom: (0x9ADBBF, 0x173629))
        }
    }

    /// 当前主题。直接读用户偏好：Palette 的动态颜色每次解析时都会取最新值。
    static var current: FanTheme {
        FanTheme(rawValue: UserDefaults.standard.string(forKey: "xiaoju.theme") ?? "") ?? .forest
    }
}

/// 晨雾 · 流转 的色板与材质规范。
/// 浅/深两套，界面跟随系统外观；底色与强调色跟随用户选的主题。
enum Palette {
    // MARK: 动态颜色

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// 跟随主题的动态颜色：每次解析时按当前主题和外观取值。
    private static func themed(_ pick: @escaping (ThemeColors) -> ThemeColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color = pick(FanTheme.current.colors)
            return NSColor(hex: isDark ? color.dark : color.light)
        })
    }

    static let canvas            = themed { $0.canvas }
    static let surface           = themed { $0.surface }
    static let surfaceSecondary  = themed { $0.surfaceSecondary }
    static let textPrimary       = themed { $0.textPrimary }
    static let textSecondary     = themed { $0.textSecondary }
    static let line              = themed { $0.line }
    static let brand             = themed { $0.brand }
    static let brandHover        = themed { $0.brandHover }
    static let brandSoft         = themed { $0.brandSoft }
    static let focus             = themed { $0.focus }
    /// 强调色上的前景：浅色下用白，深色下用深墨色（森林绿：对比 1.62 → 7+）
    static let onAccent          = themed { $0.onAccent }

    /// 语义色不随主题变：成功、危险在任何主题下含义一致
    static let success           = dynamic(light: 0x2D6A4F, dark: 0x8CCBA3)
    static let danger            = dynamic(light: 0xB53832, dark: 0xFFAAA2)
    /// 部分成功、需要留意但不是失败的提示（如有文件没能导入）
    static let warning           = dynamic(light: 0x8A5A00, dark: 0xF2C66D)

    /// 品牌玻璃渐变，仅用于图标与展示材质
    static let glassTop    = themed { $0.glassTop }
    static let glassBottom = themed { $0.glassBottom }

    // MARK: 尺度

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let window: CGFloat = 16
        static let popover: CGFloat = 14
        /// 按钮、预览缩略图、小块内容
        static let small: CGFloat = 7
        /// 列表行、较大的控件
        static let row: CGFloat = 10
        /// 空态拖放区这类大面板
        static let panel: CGFloat = 18
    }

    /// 字号只用这几档；最小 10pt，再小的文字在 Retina 屏上也很难读。
    enum TypeSize {
        static let title: CGFloat = 20
        static let section: CGFloat = 13
        static let body: CGFloat = 13
        static let label: CGFloat = 12
        static let caption: CGFloat = 11
        static let micro: CGFloat = 10
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
                    Text("示例").font(.system(size: Palette.TypeSize.micro, weight: .medium))
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


/// 主题改变时让整棵视图树重建，Palette 里的动态颜色才会重新解析。
/// 代价是该窗口里的临时 @State（如列表选择）会被重置；换主题是低频操作，可以接受。
struct FollowsTheme: ViewModifier {
    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue

    func body(content: Content) -> some View {
        content.id(themeRaw)
    }
}

extension View {
    func followsTheme() -> some View { modifier(FollowsTheme()) }
}
