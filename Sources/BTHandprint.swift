import SwiftUI

/// 冥滩主题的 BT 手印，手指朝上（-y）。
///
/// 形状参考了游戏实机里 BT 出现时地上的手印（细长张开的手指、窄掌根、左右手交替爬行），
/// 外观参考《死亡搁浅 2》封面的美术处理（印痕断续、往下淌的滴痕、细碎飞溅）。
/// 图形是程序生成的原创形状，不描摹任何官方图案。
/// - `mirrored`：右手（默认是拇指在右侧的左手），轨迹里左右交替用；
/// - `gravity`：这个手印在屏幕上会被转多少度。滴痕按它反向计算，所以不管手朝哪边，滴痕都往屏幕下方流。
/// 比例约为宽 0.62 : 高 1。长短、弯曲、断口、滴痕都按种子抖动，同一组参数每次画出来一样。
struct HandprintShape: Shape {
    var seed: UInt64 = 1
    var mirrored = false
    var gravity: Angle = .zero

    func path(in rect: CGRect) -> Path {
        var random = SplitMix64(seed: seed)
        func jitter(_ amount: CGFloat) -> CGFloat { (random.unit() - 0.5) * 2 * amount }
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        var hand = Path()

        // 掌心：指根一线宽、掌根窄，像真实手掌按下去的形状；锚点各自抖动后用曲线连成毛糙的轮廓
        let anchors: [(CGFloat, CGFloat)] = [
            (0.25, 0.48), (0.37, 0.445), (0.50, 0.435), (0.63, 0.445), (0.73, 0.49),
            (0.76, 0.57), (0.71, 0.66), (0.62, 0.73), (0.50, 0.755), (0.39, 0.735),
            (0.31, 0.67), (0.25, 0.58),
        ]
        var outline: [CGPoint] = []
        for (index, (x, y)) in anchors.enumerated() {
            outline.append(point(x + jitter(0.025), y + jitter(0.018)))
            // 相邻锚点之间再插一个抖动更大的点，边缘才有细碎的起伏
            let (nx, ny) = anchors[(index + 1) % anchors.count]
            outline.append(point((x + nx) / 2 + jitter(0.02), (y + ny) / 2 + jitter(0.015)))
        }
        hand.move(to: mid(outline[outline.count - 1], outline[0]))
        for i in outline.indices {
            hand.addQuadCurve(to: mid(outline[i], outline[(i + 1) % outline.count]), control: outline[i])
        }
        hand.closeSubpath()

        // 手指：(根部 x, 根部 y, 长度, 根部粗细, 角度°)，从左到右是小指、无名指、中指、食指、拇指
        let fingers: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.29, 0.50, 0.24, 0.078, -21),
            (0.39, 0.465, 0.31, 0.088, -9),
            (0.51, 0.455, 0.35, 0.092, 1),
            (0.63, 0.47, 0.31, 0.088, 12),
            (0.72, 0.62, 0.23, 0.096, 50),   // 拇指：从掌侧偏下伸出、向外张开
        ]
        for (x, y, length, width, degrees) in fingers {
            let len = h * length * (1 + jitter(0.1))
            let base = w * width * (1 + jitter(0.12))
            let bend = jitter(0.12) * len          // 手指微微弯
            let angle = (degrees + jitter(5)) * .pi / 180
            let transform = CGAffineTransform(translationX: point(x, y).x, y: point(x, y).y).rotated(by: angle)
            // 约三分之一的手指在中段断开一道缝，像没按实
            let gapAt: CGFloat? = random.unit() < 0.35 ? 0.45 + random.unit() * 0.2 : nil
            // 缝要够宽才读得出是“没按实”，太窄会像一道接缝线
            let gap = h * (0.022 + random.unit() * 0.016)
            var pieces: [(CGFloat, CGFloat)] = [(0, 1)]
            if let gapAt { pieces = [(0, gapAt), (gapAt + gap / len, 1)] }
            for (from, to) in pieces where to > from {
                // 沿长度取点：宽度从根部收到指尖的六成，左右边缘各自抖动；走向与掌心一致
                let steps = 7
                var left: [CGPoint] = [], right: [CGPoint] = []
                for i in 0...steps {
                    let t = from + (to - from) * CGFloat(i) / CGFloat(steps)
                    let half = base / 2 * (1 - 0.4 * t) * (1 + jitter(0.1))
                    let cx = bend * t * t
                    left.append(CGPoint(x: cx - half, y: -len * t))
                    right.append(CGPoint(x: cx + half * (1 + jitter(0.08)), y: -len * t))
                }
                var finger = Path()
                finger.move(to: left[0])
                for p in left.dropFirst() { finger.addLine(to: p) }
                if to >= 1 {
                    // 指尖：收成圆钝的尖
                    let tip = CGPoint(x: bend + jitter(base * 0.05), y: -len - base * 0.32)
                    finger.addQuadCurve(to: right[steps], control: tip)
                } else {
                    finger.addLine(to: right[steps])
                }
                for p in right.reversed().dropFirst() { finger.addLine(to: p) }
                finger.closeSubpath()
                hand.addPath(finger, transform: transform)
            }
        }

        // 细碎飞溅：手印周围零星的小点
        for _ in 0..<(10 + Int(random.unit() * 10)) {
            let t = Double(random.unit()) * 2 * .pi
            let distance = 0.30 + random.unit() * 0.2
            let c = point(0.5 + CGFloat(cos(t)) * distance * 0.85, 0.45 + CGFloat(sin(t)) * distance * 0.6)
            let r = w * (0.006 + pow(random.unit(), 2) * 0.018)
            hand.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // 右手：整只手左右翻转。翻转会反转走向，但整只手一起翻，各部分之间仍然一致
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX * 2 + w, ty: 0)
        var path = mirrored ? hand.applying(mirror) : hand
        // 滴痕先在“翻转前”的坐标里画（位置和角度都预先翻转），最后和手一起翻转一次：
        // 这样滴痕的走向和翻转后的手掌一致，重叠处按非零规则合成一体，不会抵消成空洞
        var drops = Path()

        // 滴痕：在最终坐标里画，方向按 gravity 反算，屏幕上始终朝下。
        // 粗细差别大，多数细长，少数粗；有的中段鼓起一截，末端挂一颗水滴
        let fall = CGFloat(mirrored ? gravity.radians : -gravity.radians)
        let drips = 6 + Int(random.unit() * 6)
        for _ in 0..<drips {
            let origin = point(0.32 + random.unit() * 0.38, 0.52 + random.unit() * 0.2)
            // 手印转了方向时，“向下”可能指向画框侧边：滴痕长度限制在画框以内，免得被截出一道斜切口
            let down = CGVector(dx: -sin(fall), dy: cos(fall))
            func room(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat, _ step: CGFloat) -> CGFloat {
                abs(step) < 0.001 ? .infinity : ((step > 0 ? high : low) - value) / step
            }
            let inset = w * 0.04
            let available = min(room(origin.x, rect.minX + inset, rect.maxX - inset, down.dx),
                                room(origin.y, rect.minY + inset, rect.maxY - inset, down.dy))
            let length = min(h * (0.1 + pow(random.unit(), 1.3) * 0.34), max(0, available - w * 0.04))
            guard length > w * 0.04 else { continue }
            let thick = w * (0.008 + pow(random.unit(), 2.2) * 0.04)
            let root = thick * (1.3 + random.unit() * 0.8)
            let bulge = random.unit() < 0.3 ? thick * 0.6 : 0
            var drip = Path()
            // 以 +y 为流向画，右边向下、底边向左、左边向上（与掌心同一走向）
            drip.move(to: CGPoint(x: root / 2, y: -thick))
            drip.addQuadCurve(to: CGPoint(x: thick / 2, y: length * 0.3), control: CGPoint(x: thick / 2, y: 0))
            drip.addQuadCurve(to: CGPoint(x: thick / 2, y: length * 0.75),
                              control: CGPoint(x: thick / 2 + bulge, y: length * 0.55))
            drip.addLine(to: CGPoint(x: thick / 2, y: length))
            drip.addLine(to: CGPoint(x: -thick / 2, y: length))
            drip.addLine(to: CGPoint(x: -thick / 2, y: length * 0.75))
            drip.addQuadCurve(to: CGPoint(x: -thick / 2, y: length * 0.3),
                              control: CGPoint(x: -thick / 2 - bulge, y: length * 0.55))
            drip.addQuadCurve(to: CGPoint(x: -root / 2, y: -thick), control: CGPoint(x: -thick / 2, y: 0))
            drip.closeSubpath()
            let bead = max(thick * 0.75, w * 0.008)
            drip.addEllipse(in: CGRect(x: -bead, y: length - bead * 0.8, width: bead * 2, height: bead * 2.6))
            drops.addPath(drip, transform: CGAffineTransform(translationX: origin.x, y: origin.y).rotated(by: fall))
        }
        path.addPath(mirrored ? drops.applying(mirror) : drops)
        return path
    }
}

/// 一个 BT 手印：哑光灰白，带深浅斑驳和一圈很淡的内阴影，看起来是按进去的印痕，而不是贴上去的贴纸。
/// 画一次就缓存成位图：轮盘每帧都会重画，几十条路径加噪点逐帧算太浪费。
struct BTHandprint: View {
    var seed: UInt64 = 1
    var mirrored = false
    /// 这个手印在屏幕上会被旋转的角度（调用方 rotationEffect 用的同一个值），用来让滴痕朝下
    var gravity: Angle = .zero

    var body: some View {
        GeometryReader { geometry in
            if let image = HandprintCache.image(seed: seed, mirrored: mirrored, gravity: gravity, size: geometry.size) {
                Image(decorative: image, scale: HandprintCache.scale).resizable()
            }
        }
    }

    /// 实际的绘制内容，交给缓存渲染
    struct Artwork: View {
        var seed: UInt64
        var mirrored: Bool
        var gravity: Angle

        var body: some View {
            let shape = HandprintShape(seed: seed, mirrored: mirrored, gravity: gravity)
            ZStack {
                // 压痕：用整体外轮廓做内阴影（逐段描边会把内部接缝也描出来）
                shape.fill(Color(red: 0.80, green: 0.81, blue: 0.82)
                    .shadow(.inner(color: .black.opacity(0.4), radius: 1.6))
                    .shadow(.inner(color: .white.opacity(0.25), radius: 0.6, x: 0.6, y: 0.8)))
                // 质感：放大的噪点做成大块的深浅斑驳，再叠极淡的细颗粒，像干涸的颜料，而不是砂纸
                Grain.layer(opacity: 0.35, scale: 0.18, smooth: true).blendMode(.multiply).mask(shape)
                Grain.layer(opacity: 0.12, offset: 37).blendMode(.multiply).mask(shape)
            }
            .opacity(0.9)
            .blur(radius: 0.25)
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
        }
    }
}

/// 手印位图缓存：按种子和尺寸（取整）区分。
@MainActor
enum HandprintCache {
    static let scale: CGFloat = 2
    private static var images: [String: CGImage] = [:]

    /// 方向按 10° 取整：轨迹里的手印朝向各不相同，取整后缓存仍然能复用，滴痕偏差肉眼看不出
    static func image(seed: UInt64, mirrored: Bool, gravity: Angle, size: CGSize) -> CGImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let degrees = Int((gravity.degrees / 10).rounded()) * 10
        let key = "\(seed)|\(mirrored)|\(degrees)|\(Int(size.width))x\(Int(size.height))"
        if let cached = images[key] { return cached }
        let renderer = ImageRenderer(content: BTHandprint.Artwork(seed: seed, mirrored: mirrored,
                                                                  gravity: .degrees(Double(degrees)))
            .frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        images[key] = image
        return image
    }
}

/// 颗粒噪点纹理：一张随机灰度的小图平铺使用，固定种子生成，只生成一次。
enum Grain {
    static let image: CGImage? = {
        let size = 160
        var random = SplitMix64(seed: 0x6A1A)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in pixels.indices {
            // 两次取平均让分布更集中在中灰，颗粒不那么刺眼
            pixels[i] = UInt8((random.unit() + random.unit()) / 2 * 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /// 平铺的噪点层；`offset` 让两层噪点错开，避免看出重复
    /// - Parameters:
    ///   - scale: 小于 2 时每个噪点被放大，配合 `smooth` 插值就成了柔和的斑驳
    @ViewBuilder
    static func layer(opacity: Double, offset: CGFloat = 0, scale: CGFloat = 2, smooth: Bool = false) -> some View {
        if let image {
            Image(decorative: image, scale: scale)
                .resizable(resizingMode: .tile)
                .interpolation(smooth ? .high : .none)
                .offset(x: offset, y: offset * 0.6)
                .padding(-offset)
                .opacity(opacity)
        }
    }
}

/// 在一块区域里陆续浮现、停留再消散的手印。纯粹由时间推算，不保存状态：
/// 第 k 个手印在 k × `interval` 秒出现，位置和朝向由种子决定，`life` 秒后淡出。
/// `active` 为 false 时暂停并隐藏；系统开“减少动态效果”时只显示几只静止的手印。
struct HandprintField: View {
    var active: Bool
    var interval: Double = 0.55
    var life: Double = 3.2
    var size: CGFloat = 34
    var maxOpacity: Double = 0.55
    @State private var start = Date()

    var body: some View {
        GeometryReader { geometry in
            if active {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Palette.reduceMotion)) { context in
                    let elapsed = Palette.reduceMotion ? life * 0.5 : context.date.timeIntervalSince(start)
                    let newest = Int(elapsed / interval)
                    let oldest = max(0, newest - Int(life / interval))
                    ZStack {
                        ForEach(oldest...max(oldest, newest), id: \.self) { index in
                            let age = elapsed - Double(index) * interval
                            handprint(index: index, age: age, in: geometry.size)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: active) { isActive in if isActive { start = Date() } }
        .onAppear { start = Date() }
    }

    @ViewBuilder
    private func handprint(index: Int, age: Double, in area: CGSize) -> some View {
        var random = SplitMix64(seed: UInt64(index) &* 2654435761 &+ 17)
        let x = size / 2 + random.unit() * max(1, area.width - size)
        let y = size / 2 + random.unit() * max(1, area.height - size)
        let rotation = (random.unit() - 0.5) * 70
        let scale = 0.85 + random.unit() * 0.3
        // 0.25 秒浮现，最后 0.8 秒消散
        let fadeIn = min(1, max(0, age / 0.25))
        let fadeOut = min(1, max(0, (life - age) / 0.8))
        BTHandprint(seed: UInt64(index) &+ 101, mirrored: index % 2 == 1, gravity: .degrees(rotation))
            .frame(width: size * scale * 0.62, height: size * scale)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(0.9 + 0.1 * fadeIn)
            .opacity(maxOpacity * fadeIn * fadeOut)
            .position(x: x, y: y)
    }
}

/// 冥滩主题的花瓣：一坨不规则的焦油，底部有几处正往下拉丝、滴落。
///
/// 轮廓用低频起伏（大致形状）叠高频抖动（毛糙边缘），每片花瓣都不一样（按种子固定）；
/// 滴痕根部宽、很快收成细丝，末端挂一颗拉长的水滴，有的水滴已经和丝断开、正在下落。
/// `body` 是主体在整个矩形里所占的高度比例，剩下的空间留给滴痕。
struct TarBlobShape: Shape {
    var seed: UInt64 = 1
    var body: CGFloat = 0.62
    /// 只要主体轮廓（描边用）：滴痕不描边
    var outlineOnly = false

    func path(in rect: CGRect) -> Path {
        var random = SplitMix64(seed: seed &+ 0x5EED)
        func jitter(_ amount: CGFloat) -> CGFloat { (random.unit() - 0.5) * 2 * amount }
        let bodyHeight = rect.height * body
        let center = CGPoint(x: rect.midX, y: rect.minY + bodyHeight / 2)
        let rx = rect.width / 2 * 0.95, ry = bodyHeight / 2 * 0.92
        let phase = Double(random.unit()) * 6

        var path = Path()
        let corners = 56
        var outline: [CGPoint] = []
        for i in 0..<corners {
            let t = Double(i) / Double(corners) * 2 * .pi
            let wobble = CGFloat(sin(t * 3 + phase)) * 0.07 + CGFloat(sin(t * 5 + phase * 2)) * 0.04
            let k = 1 + wobble + jitter(0.025)
            outline.append(CGPoint(x: center.x + CGFloat(cos(t)) * rx * (1 + (k - 1) * 0.5),
                                   y: center.y + CGFloat(sin(t)) * ry * k))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(outline[corners - 1], outline[0]))
        for i in 0..<corners {
            path.addQuadCurve(to: mid(outline[i], outline[(i + 1) % corners]), control: outline[i])
        }
        path.closeSubpath()
        if outlineOnly { return path }

        let drips = 2 + Int(random.unit() * 3)
        for index in 0..<drips {
            let slot = (CGFloat(index) + 0.5) / CGFloat(drips)
            let x = rect.minX + rect.width * (0.2 + slot * 0.6 + jitter(0.06))
            let dx = (x - center.x) / rx
            let edgeY = center.y + ry * CGFloat(sqrt(max(0, 1 - Double(dx * dx)))) * 0.9
            let thick = rect.width * (0.03 + random.unit() * 0.03)
            let reach = (rect.maxY - edgeY) * (0.3 + random.unit() * 0.62)
            guard reach > thick * 2 else { continue }
            // 根部宽、迅速收细成丝；整条略微往一侧偏，不是笔直的柱子
            let rootHalf = thick * (1.0 + random.unit() * 0.5), stringHalf = max(0.6, thick * 0.24)
            let top = edgeY - thick * 1.5
            let sway = jitter(thick * 0.6)
            let bottom = edgeY + reach
            // 走向和主体轮廓一致（右侧向下、底边向左、左侧向上），按非零规则和主体合成一体
            path.move(to: CGPoint(x: x + rootHalf, y: top))
            path.addQuadCurve(to: CGPoint(x: x + sway + stringHalf, y: edgeY + reach * 0.45),
                              control: CGPoint(x: x + stringHalf * 2, y: edgeY + thick * 0.4))
            path.addLine(to: CGPoint(x: x + sway + stringHalf, y: bottom))
            path.addLine(to: CGPoint(x: x + sway - stringHalf, y: bottom))
            path.addLine(to: CGPoint(x: x + sway - stringHalf, y: edgeY + reach * 0.45))
            path.addQuadCurve(to: CGPoint(x: x - rootHalf, y: top),
                              control: CGPoint(x: x - stringHalf * 2, y: edgeY + thick * 0.4))
            path.closeSubpath()
            // 末端一颗拉长的水滴；约三成已经断开、在丝下方一点正往下掉
            let bead = thick * (0.6 + random.unit() * 0.3)
            let falling = random.unit() < 0.3
            let beadTop = falling ? min(rect.maxY - bead * 3, bottom + thick * 1.2) : bottom - bead * 0.8
            path.addEllipse(in: CGRect(x: x + sway - bead, y: beadTop, width: bead * 2, height: bead * 2.8))
        }
        return path
    }
}

/// 焦油花瓣的外观：哑光近黑，表面只有一层很淡的油膜（偏紫、偏青、偏金的细微色移），
/// 加颗粒噪点；没有卡通式的白色高光点。选中时只亮起一圈细细的暖白描边，不发光。
struct TarPetal: View {
    var seed: UInt64
    var hot: Bool
    var bodyRatio: CGFloat = 0.62

    var body: some View {
        let shape = TarBlobShape(seed: seed, body: bodyRatio)
        let outline = TarBlobShape(seed: seed, body: bodyRatio, outlineOnly: true)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(red: 0.085, green: 0.085, blue: 0.09),
                                               Color(red: 0.025, green: 0.025, blue: 0.028)],
                                      startPoint: .top, endPoint: .bottom))
            // 油膜：贴着上缘一道很淡的彩色反光，像焦油表面的油光
            outline
                .stroke(LinearGradient(colors: [Color(red: 0.55, green: 0.45, blue: 0.75).opacity(0.55),
                                                Color(red: 0.35, green: 0.65, blue: 0.70).opacity(0.45),
                                                Color(red: 0.80, green: 0.66, blue: 0.40).opacity(0.45)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 5)
                .blur(radius: 3)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                .mask(shape)
            // 极淡的斑驳，只打破纯黑的平面感，不能多，否则焦油会变成灰色的毡子
            Grain.layer(opacity: 0.07, scale: 0.25, smooth: true).blendMode(.screen).mask(shape)
            outline.stroke(hot ? Color(red: 0.93, green: 0.88, blue: 0.76) : Color.white.opacity(0.07),
                           lineWidth: hot ? 1 : 0.5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
    }
}

/// 冥滩：被选中的焦油花瓣表面的动静。
///
/// - 涟漪：选中那一刻从焦油中心荡开一圈，之后每 2.4 秒再轻轻荡一圈；画成扁椭圆，像从斜上方看液面；
/// - 冒泡：每隔一会儿有一个小气泡从焦油底部浮上来，到表面后破开成一圈小环再消失，像底下有东西在动。
/// 全部裁在焦油主体轮廓里，不碰滴痕。按时间推算，不保存状态；系统开“减少动态效果”时只留一圈静止的淡涟漪。
struct TarStirring: View {
    var seed: UInt64
    var bodyRatio: CGFloat
    var since: Date
    /// 自检渲染用：固定已逝时间（离屏渲染没有时间流逝）
    var fixedTime: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let bodyHeight = size.height * bodyRatio
            let center = CGPoint(x: size.width / 2, y: bodyHeight * 0.55)
            Group {
                if Palette.reduceMotion {
                    ripple(progress: 0.5, strength: 0.5, center: center, size: size, bodyHeight: bodyHeight)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let t = fixedTime ?? max(0, context.date.timeIntervalSince(since))
                        ZStack {
                            // 第一圈最明显，之后的较淡
                            let period = 2.4
                            let cycle = Int(t / period)
                            let local = t - Double(cycle) * period
                            ripple(progress: local / 1.6, strength: cycle == 0 ? 1 : 0.55,
                                   center: center, size: size, bodyHeight: bodyHeight)
                            ripple(progress: (local - 0.28) / 1.6, strength: cycle == 0 ? 0.6 : 0.3,
                                   center: center, size: size, bodyHeight: bodyHeight)
                            bubbles(time: t, size: size, bodyHeight: bodyHeight)
                        }
                    }
                }
            }
            // clipShape 比 mask 便宜（不需要额外的离屏图层）；轮廓缓存起来，不每帧重算
            .clipShape(FixedPath(path: TarOutlineCache.outline(seed: seed, body: bodyRatio, size: size)))
        }
        .allowsHitTesting(false)
    }

    /// 一圈涟漪：progress 从 0 到 1 由中心扩到边缘并淡出
    @ViewBuilder
    private func ripple(progress: Double, strength: Double, center: CGPoint, size: CGSize, bodyHeight: CGFloat) -> some View {
        if progress > 0, progress < 1 {
            let eased = 1 - pow(1 - progress, 2.2)
            let width = size.width * 0.95 * CGFloat(eased)
            Ellipse()
                // 不加模糊（每帧模糊开销大），靠线宽变细和透明度衰减表现扩散变淡
                .stroke(Color.white.opacity(0.26 * strength * (1 - progress)), lineWidth: 1.2 - CGFloat(progress) * 0.6)
                .frame(width: width, height: width * bodyHeight / size.width * 0.75)
                .position(center)
        }
    }

    /// 气泡：每 0.9 秒一个，各自用 0.9 秒浮到表面，再用 0.3 秒破开
    private func bubbles(time: Double, size: CGSize, bodyHeight: CGFloat) -> some View {
        let interval = 0.9, rise = 0.9, pop = 0.3
        let newest = Int(time / interval)
        return ZStack {
            ForEach(max(0, newest - 2)...newest, id: \.self) { index in
                let age = time - Double(index) * interval
                // 刚选中的前 0.4 秒不冒泡，让第一圈涟漪先出现
                if index > 0 || time > 0.4 {
                    bubble(index: index, age: age, rise: rise, pop: pop, size: size, bodyHeight: bodyHeight)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(index: Int, age: Double, rise: Double, pop: Double, size: CGSize, bodyHeight: CGFloat) -> some View {
        var random = SplitMix64(seed: seed &+ UInt64(index) &* 0x2545F491)
        // 约一半的时段不冒泡，显得是“偶尔”
        let shows = random.unit() < 0.55
        let x = size.width * (0.22 + random.unit() * 0.56)
        let radius = 1.6 + random.unit() * 1.6
        let startY = bodyHeight * 0.86, surfaceY = bodyHeight * (0.3 + random.unit() * 0.15)
        if shows && age >= 0 && age < rise + pop {
            if age < rise {
                let p = CGFloat(age / rise)
                let y = startY + (surfaceY - startY) * (1 - pow(1 - p, 2))
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .overlay(Circle().stroke(Color.white.opacity(0.38), lineWidth: 0.6))
                    .overlay(Circle().fill(Color.white.opacity(0.5)).frame(width: radius * 0.6, height: radius * 0.6)
                        .offset(x: -radius * 0.3, y: -radius * 0.3))
                    .frame(width: radius * 2 * (0.7 + 0.3 * p), height: radius * 2 * (0.7 + 0.3 * p))
                    .position(x: x + CGFloat(sin(age * 9 + Double(index))) * 0.8, y: y)
                    .opacity(Double(min(1, p * 4)))
            } else {
                // 破开：一圈小环扩开后消失
                let p = (age - rise) / pop
                Ellipse()
                    .stroke(Color.white.opacity(0.4 * (1 - p)), lineWidth: 0.7)
                    .frame(width: radius * 2 * (1 + 2.2 * CGFloat(p)), height: radius * (1 + 2.2 * CGFloat(p)))
                    .position(x: x, y: surfaceY)
            }
        }
    }
}

/// 已经算好的路径，直接当形状用
struct FixedPath: Shape {
    var path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// 焦油花瓣主体轮廓的缓存：选中花瓣每帧都要用它裁切涟漪和气泡，轮廓本身不会变
@MainActor
enum TarOutlineCache {
    private static var paths: [String: Path] = [:]

    static func outline(seed: UInt64, body: CGFloat, size: CGSize) -> Path {
        let key = "\(seed)|\(Int(body * 1000))|\(Int(size.width))x\(Int(size.height))"
        if let cached = paths[key] { return cached }
        let path = TarBlobShape(seed: seed, body: body, outlineOnly: true).path(in: CGRect(origin: .zero, size: size))
        paths[key] = path
        return path
    }
}
