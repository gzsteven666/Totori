import SwiftUI

/// 空态中间的凝胶球：一颗半透明的果冻，小爪子“泡”在里面。
///
/// 主窗口底色是不透明的，背后没有可以折射的东西，所以透明感只能靠球体内部的光影来表现：
/// - 中心浅、边缘深：凝胶越靠边越厚，颜色更饱和；
/// - 底部内侧有一道亮弧：光穿过凝胶后在底部汇聚；
/// - 顶部一大片柔光加一个锐利的小高光点，压在爪子上面，爪子才像在球“里面”；
/// - 球下方地面上投一圈带颜色的透光，而不是普通的灰影子。
/// 拖文件进窗口时球会像果冻一样被压一下再弹回；系统开“减少动态效果”时不做形变。
/// 平时保持静止：不做循环“呼吸”动画，避免窗口空闲时也一直重绘、耗电。
struct JellyOrb<Content: View>: View {
    var diameter: CGFloat = 104
    /// 有文件拖到窗口上方时为 true，球体会弹一下并变亮
    var active: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            groundGlow.offset(y: diameter * 0.98)
            orb
        }
        .frame(width: diameter * 1.1, height: diameter * 1.12, alignment: .top)
    }

    private var orb: some View {
        ZStack {
            // 1. 凝胶体：中心浅、边缘深
            Circle().fill(
                RadialGradient(colors: [Palette.glassTop.opacity(0.30),
                                        Palette.brand.opacity(0.07),
                                        Palette.brand.opacity(0.24)],
                               center: UnitPoint(x: 0.5, y: 0.58),
                               startRadius: 0, endRadius: diameter * 0.56)
            )
            // 2. 边缘内侧加厚：一圈模糊的深色，只留在球内
            Circle()
                .strokeBorder(Palette.brand.opacity(0.22), lineWidth: diameter * 0.07)
                .blur(radius: diameter * 0.05)
            // 3. 底部透光：光穿过凝胶后在底部汇聚成亮弧
            Ellipse()
                .fill(LinearGradient(colors: [Palette.glassTop.opacity(0), Color.white.opacity(0.8)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: diameter * 0.78, height: diameter * 0.36)
                .offset(y: diameter * 0.31)
                .blur(radius: diameter * 0.045)
            // 4. 内容“泡”在凝胶里：略透一点，带一层很淡的颜色
            content
                .padding(diameter * 0.2)
                .opacity(0.94)
                .shadow(color: Palette.brand.opacity(0.25), radius: 4, y: 3)
            // 5. 顶部柔光：压在内容上面，才有“隔着一层果冻”的感觉
            Ellipse()
                .fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.95), location: 0),
                                             .init(color: Color.white.opacity(0.40), location: 0.45),
                                             .init(color: Color.white.opacity(0), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: diameter * 0.74, height: diameter * 0.44)
                .offset(y: -diameter * 0.25)
                .blur(radius: 1.2)
            // 6. 锐利小高光点
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: diameter * 0.13, height: diameter * 0.065)
                .rotationEffect(.degrees(-32))
                .offset(x: -diameter * 0.25, y: -diameter * 0.22)
                .blur(radius: 0.4)
        }
        // 球内各层统一按球体裁切。不能逐层 clipShape：偏移过的高光会被裁在自己原来的框里，几乎看不见。
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(
            // 7. 轮廓：上白下透，底部带一点主题色反光
            Circle().strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.15),
                                        Palette.brand.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1.2
            )
        )
        .compositingGroup()
        .shadow(color: Palette.brand.opacity(active ? 0.28 : 0.14), radius: active ? 20 : 14, y: 8)
        // 果冻形变：平时轻微呼吸，拖入时压扁再弹回
        .scaleEffect(x: squishX, y: squishY, anchor: .bottom)
        .brightness(active ? 0.04 : 0)
        .animation(Palette.reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.45), value: active)
    }

    /// 球下方的彩色透光，比灰色影子更像光穿过了凝胶
    private var groundGlow: some View {
        Ellipse()
            .fill(Palette.brand.opacity(active ? 0.22 : 0.12))
            .frame(width: diameter * 0.62, height: diameter * 0.12)
            .blur(radius: diameter * 0.08)
    }

    private var squishX: CGFloat {
        if Palette.reduceMotion { return 1 }
        return active ? 1.08 : 1
    }

    private var squishY: CGFloat {
        if Palette.reduceMotion { return 1 }
        return active ? 0.95 : 1
    }
}
