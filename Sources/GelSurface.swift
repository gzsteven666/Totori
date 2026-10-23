import SwiftUI

/// 凝胶材质：像一块半透明的果冻，里面悬着细小气泡。
///
/// 参考的是发胶、果冻这类实物质感，靠这几层叠出来：
/// 1. 胶体：上浅下深的半透明主题色，越往下越厚；
/// 2. 内芯透光：中间偏上一团柔和的亮光；
/// 3. 边缘加厚：贴着轮廓一圈更浓的颜色，向内模糊；
/// 4. 悬浮气泡：按种子固定生成的小圆点，每个带亮心和暗边，大小深浅不一，有的略虚表示更深；
/// 5. 湿润高光：顶部沿轮廓的一道亮边，加两三个锐利的小反光点；
/// 6. 轮廓：上白下带色的细边。
///
/// 气泡位置由 `seed` 决定，同一片花瓣每次出现都一样，不会闪烁。
struct GelSurface<S: InsettableShape>: View {
    let shape: S
    /// 胶体颜色
    let tint: Color
    /// 边缘与暗部的颜色，通常比 tint 更深更饱和
    let edge: Color
    var seed: UInt64 = 1
    /// 浓度：1 为常态，选中时调高让胶体更饱和
    var density: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // 1. 胶体
                shape.fill(LinearGradient(colors: [tint.opacity(0.74 * density), tint.opacity(0.90 * density)],
                                          startPoint: .top, endPoint: .bottom))
                // 2. 内芯透光
                shape.fill(RadialGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0)],
                                          center: UnitPoint(x: 0.45, y: 0.40),
                                          startRadius: 0, endRadius: max(size.width, size.height) * 0.45))
                // 3. 边缘加厚
                shape.strokeBorder(edge.opacity(0.42 * density), lineWidth: min(size.width, size.height) * 0.16)
                    .blur(radius: min(size.width, size.height) * 0.09)
                // 4. 悬浮气泡
                Canvas { context, canvasSize in
                    GelBubbles.draw(in: &context, size: canvasSize, seed: seed, edge: edge)
                }
                // 5. 湿润高光：顶部亮边 + 小反光点
                shape.inset(by: 1.5)
                    .strokeBorder(LinearGradient(stops: [.init(color: Color.white.opacity(0.85), location: 0),
                                                         .init(color: Color.white.opacity(0), location: 0.38)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 2.2)
                    .blur(radius: 0.7)
                Ellipse()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: size.width * 0.10, height: size.height * 0.07)
                    .rotationEffect(.degrees(-18))
                    .position(x: size.width * 0.20, y: size.height * 0.20)
                    .blur(radius: 0.4)
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 2.6, height: 2.6)
                    .position(x: size.width * 0.80, y: size.height * 0.24)
            }
            .clipShape(shape)
            // 6. 轮廓
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.75), edge.opacity(0.50)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 0.9)
            )
        }
        .compositingGroup()
        .shadow(color: edge.opacity(0.30), radius: 10, y: 5)
    }
}

/// 凝胶里的气泡，用固定种子生成，保证每次绘制一致。
enum GelBubbles {
    static func draw(in context: inout GraphicsContext, size: CGSize, seed: UInt64, edge: Color) {
        var random = SplitMix64(seed: seed)
        // 大约每 90 平方点一个气泡，小花瓣也至少有十几个
        let count = max(14, Int(size.width * size.height / 90))
        for _ in 0..<count {
            let x = random.unit() * size.width
            let y = random.unit() * size.height
            // 多数是细小气泡，少数稍大
            let big = random.unit() < 0.12
            let radius = big ? 1.8 + random.unit() * 1.6 : 0.5 + random.unit() * 1.1
            let depth = random.unit()          // 0 靠前、1 靠后：越靠后越淡越虚
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            var bubble = context
            if depth > 0.6 { bubble.addFilter(.blur(radius: 0.5)) }
            bubble.opacity = 1 - depth * 0.55
            // 气泡本体：亮心
            bubble.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.55)))
            // 暗边：气泡与胶体的界面
            bubble.stroke(Path(ellipseIn: rect), with: .color(edge.opacity(0.35)), lineWidth: radius > 1.5 ? 0.6 : 0.35)
            // 大一点的气泡带一个反光点
            if radius > 1.4 {
                let spot = CGRect(x: x - radius * 0.45, y: y - radius * 0.55,
                                  width: radius * 0.5, height: radius * 0.4)
                bubble.fill(Path(ellipseIn: spot), with: .color(Color.white.opacity(0.95)))
            }
        }
    }
}

/// 简单可复现的伪随机数，只用来摆放气泡。
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 均匀分布
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}
