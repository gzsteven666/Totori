import SwiftUI

/// App 图标：小爪子按住一张正在转换的文件。
///
/// 按 macOS 图标网格绘制：1024 画布里 824 的圆角方块（四周留白、带投影），这样在访达和启动台里
/// 和其他 App 一样大小。方块是主题色的凝胶；文件卡片上半是原来的内容（几行文字），
/// 下半已经“变成”主题色，分界是一道波浪；爪子从右下按住卡片一角。
/// 冥滩主题换成焦油黑方块、骨白卡片、低饱和金色和一只 BT 手印。
/// `simplified` 用于 16/32 像素：去掉文字线条、折角和气泡，只留卡片和爪子，小尺寸不糊。
struct AppIconArt: View {
    var theme: FanTheme
    var simplified = false

    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height) / 1024
            ZStack {
                tile(s)
                card(s)
                    .rotationEffect(.degrees(-8))
                    .position(x: 470 * s, y: 478 * s)
                presser(s)
            }
            .frame(width: 1024 * s, height: 1024 * s)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: 方块

    private var colors: ThemeColors { theme.colors }
    private func color(_ value: ThemeColor) -> Color { Color(nsColor: NSColor(hex: value.light)) }

    private func tile(_ s: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
        let top = theme.isBeach ? Color(nsColor: NSColor(hex: 0x24262A)) : color(colors.glassTop)
        let bottom = theme.isBeach ? Color(nsColor: NSColor(hex: 0x0B0B0C)) : color(colors.glassBottom)
        return ZStack {
            shape.fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            // 凝胶的厚度：边缘一圈更浓的主题色（冥滩是一层淡淡的油膜色）
            shape.strokeBorder(theme.isBeach
                               ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.45, blue: 0.75).opacity(0.35),
                                                                       Color(red: 0.80, green: 0.66, blue: 0.40).opacity(0.25)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                               : AnyShapeStyle(color(colors.brand).opacity(0.28)),
                               lineWidth: 46 * s)
                .blur(radius: 26 * s)
                .clipShape(shape)
            // 顶部柔光
            Ellipse()
                .fill(LinearGradient(colors: [Color.white.opacity(theme.isBeach ? 0.10 : 0.45), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 640 * s, height: 300 * s)
                .offset(y: -250 * s)
                .clipShape(shape)
            if !simplified && !theme.isBeach { bubbles(s).clipShape(shape) }
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(theme.isBeach ? 0.18 : 0.75),
                                                       Color.white.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: 5 * s)
        }
        .frame(width: 824 * s, height: 824 * s)
        .position(x: 512 * s, y: 512 * s)
        .shadow(color: .black.opacity(0.28), radius: 18 * s, y: 12 * s)
    }

    /// 凝胶里零星的气泡，和花瓣同一套语言
    private func bubbles(_ s: CGFloat) -> some View {
        Canvas { context, size in
            var random = SplitMix64(seed: 0x1C0)
            for _ in 0..<22 {
                let r = (5 + random.unit() * 12) * s
                let x = random.unit() * size.width, y = random.unit() * size.height
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)))
                context.stroke(Path(ellipseIn: rect), with: .color(color(colors.brand).opacity(0.25)), lineWidth: 1.2 * s)
            }
        }
    }

    // MARK: 文件卡片

    private func card(_ s: CGFloat) -> some View {
        let w = 430 * s, h = 540 * s, fold = simplified ? 0 : 108 * s
        let paper = theme.isBeach ? Color(nsColor: NSColor(hex: 0xE6E2D9)) : Color.white
        let converted = theme.isBeach ? Color(nsColor: NSColor(hex: 0xC2A066)) : color(colors.brand)
        let outline = FoldedCard(fold: fold, radius: 40 * s)
        return ZStack(alignment: .topLeading) {
            outline.fill(paper)
            // 下半已经转换成主题色，上缘是一道波浪：表示“正在变”
            ConvertedPart(level: 0.5)
                .fill(LinearGradient(colors: [converted.opacity(0.92), converted],
                                     startPoint: .top, endPoint: .bottom))
                .clipShape(outline)
            if !simplified {
                // 上半是原内容：几行文字
                VStack(alignment: .leading, spacing: 34 * s) {
                    ForEach([0.62, 0.78, 0.55], id: \.self) { fraction in
                        Capsule().fill(Color.black.opacity(0.16))
                            .frame(width: (w - 120 * s) * fraction, height: 26 * s)
                    }
                }
                .padding(.leading, 60 * s).padding(.top, 92 * s)
                // 折角
                FoldTriangle(size: fold)
                    .fill(LinearGradient(colors: [Color.black.opacity(0.10), Color.black.opacity(0.22)],
                                         startPoint: .topTrailing, endPoint: .bottomLeading))
                    .frame(width: w, height: h)
            }
        }
        .frame(width: w, height: h)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 16 * s, y: 10 * s)
    }

    // MARK: 按住卡片的手

    @ViewBuilder
    private func presser(_ s: CGFloat) -> some View {
        if theme.isBeach {
            BTHandprint.Artwork(seed: 23, mirrored: false, gravity: .degrees(-18))
                .frame(width: 270 * s, height: 430 * s)
                .rotationEffect(.degrees(-18))
                .position(x: 640 * s, y: 640 * s)
        } else if let paw = PawAssets.open {
            Image(nsImage: paw)
                .resizable()
                .interpolation(.high)
                .frame(width: (simplified ? 450 : 390) * s, height: (simplified ? 450 : 390) * s)
                .rotationEffect(.degrees(-24))
                .shadow(color: .black.opacity(0.28), radius: 14 * s, y: 8 * s)
                // 收在方块以内，不伸出圆角边缘
                .position(x: (simplified ? 665 : 670) * s, y: (simplified ? 665 : 670) * s)
        }
    }
}

/// 右上角折起一角的卡片轮廓
private struct FoldedCard: Shape {
    var fold: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// 折角本身的小三角
private struct FoldTriangle: Shape {
    var size: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - size, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - size, y: rect.minY + size))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + size))
        path.closeSubpath()
        return path
    }
}

/// 卡片下半已转换的部分，上缘是一道波浪
private struct ConvertedPart: Shape {
    var level: CGFloat

    func path(in rect: CGRect) -> Path {
        let y = rect.minY + rect.height * level
        let amplitude = rect.height * 0.04
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addCurve(to: CGPoint(x: rect.maxX, y: y),
                      control1: CGPoint(x: rect.minX + rect.width * 0.33, y: y - amplitude * 2),
                      control2: CGPoint(x: rect.minX + rect.width * 0.66, y: y + amplitude * 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 运行时图标跟随主题：系统弹窗、关于窗口里显示的 App 图标。
/// 森林绿就是 App 包里的图标，交还给系统；其他主题渲染一张对应配色的图。
/// （Totori 是菜单栏 App，不在程序坞里；访达里的图标来自 App 包，不随主题变。）
@MainActor
enum ThemedAppIcon {
    private static var cache: [FanTheme: NSImage] = [:]

    static func apply(_ theme: FanTheme) {
        guard theme != .forest else {
            NSApp.applicationIconImage = nil
            return
        }
        if let cached = cache[theme] {
            NSApp.applicationIconImage = cached
            return
        }
        let renderer = ImageRenderer(content: AppIconArt(theme: theme).frame(width: 512, height: 512))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        cache[theme] = image
        NSApp.applicationIconImage = image
    }
}
