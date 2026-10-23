import SwiftUI

/// 冥滩主题的 BT 手印：一只张开的手按下后往下淌的痕迹，手指朝上（-y）。
///
/// 风格参考《死亡搁浅 2》封面上的银色手印，但形状是程序生成的原创图形，不描摹官方图案：
/// - 掌心是边缘不规则的团块；
/// - 四指和拇指都断成两三截，截与截之间留缝，指尖圆；
/// - 掌缘和指根垂下一串细长滴痕，末端鼓成水滴；旁边偶尔甩出一小块分离的残迹。
/// 比例约为宽 0.62 : 高 1（滴痕占下半部分）。长短、断口、滴痕按种子抖动，同一种子每次一样。
struct HandprintShape: Shape {
    var seed: UInt64 = 1

    func path(in rect: CGRect) -> Path {
        var random = SplitMix64(seed: seed)
        func jitter(_ amount: CGFloat) -> CGFloat { (random.unit() - 0.5) * 2 * amount }
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }

        var path = Path()

        // 掌心：沿椭圆取 22 个点各自抖动半径，再用二次曲线连起来，边缘就毛糙不规则
        let palmCenter = point(0.50, 0.53)
        let rx = w * 0.27, ry = h * 0.12
        let corners = 40
        var outline: [CGPoint] = []
        for i in 0..<corners {
            let t = Double(i) / Double(corners) * 2 * .pi
            // 低频起伏决定大轮廓，再叠一点高频抖动，边缘像真实的印痕一样毛糙
            let k = 1 + jitter(0.18) + CGFloat(sin(t * 7 + Double(seed % 13))) * 0.04
            outline.append(CGPoint(x: palmCenter.x + CGFloat(cos(t)) * rx * k,
                                   y: palmCenter.y + CGFloat(sin(t)) * ry * k))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(outline[corners - 1], outline[0]))
        for i in 0..<corners {
            path.addQuadCurve(to: mid(outline[i], outline[(i + 1) % corners]), control: outline[i])
        }
        path.closeSubpath()
        // 掌缘再溅几块小斑，打破整齐的轮廓
        for _ in 0..<6 {
            let t = Double(random.unit()) * 2 * .pi
            let center = CGPoint(x: palmCenter.x + CGFloat(cos(t)) * rx * 1.02, y: palmCenter.y + CGFloat(sin(t)) * ry * 1.02)
            let r = w * (0.02 + random.unit() * 0.035)
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r * 0.8, width: r * 2, height: r * 1.6))
        }

        // 手指：(根部 x, 根部 y, 长度, 粗细, 角度°)；每根断成 2–3 截
        let fingers: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.31, 0.49, 0.29, 0.085, -7),
            (0.44, 0.46, 0.38, 0.095, -2),
            (0.57, 0.46, 0.37, 0.095, 3),
            (0.69, 0.49, 0.30, 0.085, 9),
            (0.73, 0.58, 0.22, 0.09, 30),    // 拇指，向外张开
        ]
        for (index, (x, y, length, width, degrees)) in fingers.enumerated() {
            let total = h * length * (1 + jitter(0.12))
            let thick = w * width * (1 + jitter(0.15))
            let angle = (degrees + jitter(5)) * .pi / 180
            let base = point(x + jitter(0.012), y)
            let transform = CGAffineTransform(translationX: base.x, y: base.y).rotated(by: angle)
            // 一半的手指是完整一条，其余断成两三截
            let pieces = random.unit() < 0.45 ? 1 : 2 + Int(random.unit() * 2)
            var cursor: CGFloat = 0
            for piece in 0..<pieces {
                // 越靠指尖的一截越细、越短；截与截之间留一道缝
                let share = piece == pieces - 1 ? total - cursor : total / CGFloat(pieces) * (0.8 + random.unit() * 0.4)
                let segment = max(thick * 0.9, share)
                let taper = thick * (1 - 0.12 * CGFloat(piece)) * (1 + jitter(0.1))
                // 不用圆头药丸：沿长度取几个点，左右边缘各自抖动，指尖用一段曲线收口，
                // 看起来是按出来的不规则痕迹。走向与掌心一致（左边向上、右边向下）
                let steps = 6
                let shift = jitter(thick * 0.08)
                var segmentPath = Path()
                var right: [CGPoint] = []
                for i in 0...steps {
                    let y = -cursor - segment * CGFloat(i) / CGFloat(steps)
                    let half = taper / 2 * (1 + jitter(0.2)) * (1 - 0.12 * CGFloat(i) / CGFloat(steps))
                    let left = CGPoint(x: shift - half, y: y)
                    right.append(CGPoint(x: shift + half * (1 + jitter(0.15)), y: y))
                    if i == 0 { segmentPath.move(to: left) } else { segmentPath.addLine(to: left) }
                }
                let tip = CGPoint(x: shift + jitter(taper * 0.1), y: -cursor - segment - taper * 0.35)
                segmentPath.addQuadCurve(to: right[steps], control: tip)
                for point in right.reversed().dropFirst() { segmentPath.addLine(to: point) }
                segmentPath.closeSubpath()
                path.addPath(segmentPath, transform: transform)
                cursor += segment + h * (0.008 + random.unit() * 0.012)
                if cursor >= total { break }
            }
            // 拇指尖往里卷一个小圆点
            if index == 4 {
                let tip = CGPoint(x: -thick * 0.6, y: -cursor - thick * 0.2).applying(transform)
                let r = thick * 0.42
                path.addEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
            }
        }

        // 滴痕：从掌缘和指根往下淌，细长、末端鼓成水滴
        let drips = 8 + Int(random.unit() * 5)
        for _ in 0..<drips {
            let x = 0.27 + random.unit() * 0.48
            let top = 0.52 + random.unit() * 0.10
            let length = 0.08 + pow(random.unit(), 1.4) * 0.40
            let thick = w * (0.008 + random.unit() * 0.02)
            let start = point(x, top)
            let bottom = min(rect.maxY - thick, start.y + h * length)
            path.addRoundedRect(in: CGRect(x: start.x - thick / 2, y: start.y, width: thick, height: bottom - start.y),
                                cornerSize: CGSize(width: thick / 2, height: thick / 2))
            let drop = thick * 0.6
            path.addEllipse(in: CGRect(x: start.x - drop, y: bottom - drop * 1.2, width: drop * 2, height: drop * 2.4))
        }

        // 细碎飞溅：手印周围零星的小点，按下时溅出来的
        for _ in 0..<(10 + Int(random.unit() * 10)) {
            let angle = Double(random.unit()) * 2 * .pi
            let distance = 0.30 + random.unit() * 0.22
            let center = point(0.5 + CGFloat(cos(angle)) * distance * 0.9, 0.42 + CGFloat(sin(angle)) * distance * 0.7)
            let r = w * (0.006 + pow(random.unit(), 2) * 0.02)
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }

        // 偶尔甩出一小块分离的残迹
        if random.unit() < 0.7 {
            let side: CGFloat = random.unit() < 0.5 ? 0.08 : 0.92
            let blob = point(side, 0.48 + random.unit() * 0.1)
            let bw = w * 0.06, bh = h * (0.06 + random.unit() * 0.05)
            path.addRoundedRect(in: CGRect(x: blob.x - bw / 2, y: blob.y, width: bw, height: bh),
                                cornerSize: CGSize(width: bw / 2, height: bw / 2))
        }
        return path
    }
}

/// 一个 BT 手印：哑光的灰白色，像干在地面上的一层薄薄的物质。
/// 不用渐变和金属反光（太像矢量插画），而是平涂加颗粒噪点，边缘带一点点虚，周围有细碎飞溅。
/// 画一次就缓存成位图：轮盘每帧都会重画，几十条路径加噪点逐帧算太浪费。
struct BTHandprint: View {
    var seed: UInt64 = 1

    var body: some View {
        GeometryReader { geometry in
            if let image = HandprintCache.image(seed: seed, size: geometry.size) {
                Image(decorative: image, scale: HandprintCache.scale).resizable()
            }
        }
    }

    /// 实际的绘制内容，交给缓存渲染
    struct Artwork: View {
        var seed: UInt64

        var body: some View {
            let shape = HandprintShape(seed: seed)
            ZStack {
                shape.fill(Color(red: 0.80, green: 0.81, blue: 0.82))
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

    static func image(seed: UInt64, size: CGSize) -> CGImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let key = "\(seed)|\(Int(size.width))x\(Int(size.height))"
        if let cached = images[key] { return cached }
        let renderer = ImageRenderer(content: BTHandprint.Artwork(seed: seed)
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
        BTHandprint(seed: UInt64(index) &+ 101)
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
