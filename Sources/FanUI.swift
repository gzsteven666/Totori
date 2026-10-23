import SwiftUI

// MARK: - 视图

struct FanView: View {
    @ObservedObject var model: FanModel
    @AppStorage("totori.theme") private var themeRaw: String = FanTheme.forest.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }
    /// 冥滩主题：本次轮盘出现的时刻，手印按它推算逼近的进度
    @State private var printsStart = Date()
    /// 冥滩主题：当前花瓣被选中的时刻，涟漪从这一刻荡开
    @State private var hotSince = Date()

    var body: some View {
        ZStack {
            if theme.isBeach { approachingPrints }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let isHot = model.highlighted == index
                let hasHot = model.highlighted != nil
                let bloom = petalBloom(index)
                let restScale = (hasHot && !isHot && !Palette.reduceMotion) ? FanModel.dimmedScale : 1.0
                petal(item: item, hot: isHot)
                    .frame(width: model.petalWidth, height: model.petalHeight)
                    .scaleEffect((isHot ? FanModel.hoverScale(forCount: model.items.count) : restScale) * bloom.scale)
                    .opacity(bloom.opacity)
                    // 用降饱和而不是降透明度：半透明会让后面的环线透出来穿过花瓣
                    .saturation(hasHot && !isHot ? 0.7 : 1)
                    // 选中的那片压在邻居上面，放大后不被相邻花瓣遮住
                    .zIndex(isHot ? 1 : 0)
                    .offset(y: bloom.rise)
                    .position(model.petalCenter(index))
                    .animation(Palette.reduceMotion ? .easeOut(duration: 0.10)
                                                    : .spring(response: 0.20, dampingFraction: 0.66),
                               value: isHot)
                    .animation(.easeOut(duration: 0.12), value: hasHot)
            }
            if let point = model.pointerPoint, model.pointerAngle != nil {
                draggedChip(at: point)
                if theme.isBeach { btHand(at: point) } else if PawAssets.open != nil { pawView(at: point) }
            }
            if let index = model.highlighted, model.items.indices.contains(index) {
                selectionCaption(model.items[index])
            } else {
                centerBadge
            }
            if model.items.isEmpty { readingPill }
        }
        .frame(width: model.canvas, height: model.canvas)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.mode)
        .onChange(of: model.highlighted) { _ in hotSince = Date() }
        .drawingGroup()          // 合成到一层，减少每帧重绘（跟手的关键）
    }

    /// 每片花瓣的入场形变：错峰 + easeOutBack 回弹
    private func petalBloom(_ index: Int) -> (scale: CGFloat, opacity: Double, rise: CGFloat) {
        let delay = Double(index) * 0.035
        let local = min(1, max(0, (model.bloom - delay) / max(0.35, 1 - delay)))
        guard local > 0 else { return (0.55, 0, 10) }
        // easeOutBack：末尾轻微过冲，就是"弹出来"的手感
        let c1 = 1.70158
        let c3 = c1 + 1
        let eased = 1 + c3 * pow(local - 1, 3) + c1 * pow(local - 1, 2)
        return (CGFloat(0.55 + 0.45 * eased), min(1, local * 2.2), CGFloat((1 - local) * 10))
    }

    /// 我们自己画的小卡片：56×56，跟着指针走
    private func draggedChip(at point: CGPoint) -> some View {
        ZStack {
            // 先在卡片下方压一层柔光，遮住系统那张大拖影
            RadialGradient(colors: [Palette.canvas.opacity(0.92), Palette.canvas.opacity(0)],
                           center: .center, startRadius: 18, endRadius: 74)
                .frame(width: 148, height: 148)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: Palette.Radius.card, style: .continuous)
                .fill(Palette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: Palette.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 0.9)
                )
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .overlay {
                    if let icon = model.fileIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Palette.brand)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !model.fileLabel.isEmpty {
                        Text(model.fileLabel)
                            .font(.system(size: Palette.TypeSize.micro, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Palette.surface.opacity(0.9))
                            )
                            .offset(y: 8)
                    }
                }
        }
        .position(point)
        .allowsHitTesting(false)
    }

    // MARK: 冥滩：BT 手印

    /// 轮盘出现后，两串 BT 手印从外围朝中心“爬”过来：每串左右手交替、手指朝前进方向，
    /// 就像游戏里 BT 靠近时地上一步步出现的手印。爬到内圈后不再前进，更早的手印慢慢消散。
    /// 纯按时间推算，不保存状态；两串的起点按这次轮盘出现的时刻取，每次不一样。
    private var approachingPrints: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Palette.reduceMotion || !model.appeared)) { context in
            let interval = 0.3
            let elapsed = model.debugPrintsElapsed
                ?? (Palette.reduceMotion ? interval * 8 : max(0, context.date.timeIntervalSince(printsStart)))
            // 每串最多爬 9 步；两串交替出手，所以总数是 18
            let newest = min(Int(elapsed / interval), 17)
            ZStack {
                ForEach(0...newest, id: \.self) { index in
                    approachingPrint(index, age: elapsed - Double(index) * interval, newest: newest)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: model.appeared) { appeared in if appeared { printsStart = Date() } }
    }

    private func approachingPrint(_ index: Int, age: Double, newest: Int) -> some View {
        let trail = index % 2, step = index / 2
        // 两串的来向错开约 140°，起点随本次出现时刻变化
        // 两串共用一个随机起点、再固定错开 140°，保证从两个方向过来，不会挤在同一侧
        var session = SplitMix64(seed: UInt64(printsStart.timeIntervalSince1970 * 10))
        let heading = Double(session.unit()) * 2 * .pi + Double(trail) * 2.45
        var random = SplitMix64(seed: UInt64(index) &* 0x9E37_79B9 &+ 3)
        let outer = model.canvas / 2 - 30
        let inner = model.radius * 0.45
        let radius = outer - CGFloat(step) * (outer - inner) / 8
        let size: CGFloat = 50 + random.unit() * 10
        // 左右手分列在前进路线两侧，再加一点摆动，像四肢交替着地
        let side: CGFloat = step % 2 == 0 ? -1 : 1
        let lateral = side * size * 0.34 + (random.unit() - 0.5) * 8
        let position = CGPoint(
            x: model.center.x + CGFloat(cos(heading)) * radius - CGFloat(sin(heading)) * lateral,
            y: model.center.y + CGFloat(sin(heading)) * radius + CGFloat(cos(heading)) * lateral)
        // 手指指向中心（前进方向）
        let rotation = Angle.radians(heading + 3 * .pi / 2 + Double(random.unit() - 0.5) * 0.35)
        let fadeIn = min(1, max(0, age / 0.22))
        let rank = newest - index
        let fadeOld = rank > 9 ? max(0, 1 - Double(rank - 9) / 4) : 1
        return BTHandprint(seed: UInt64(index) &+ 11, mirrored: step % 2 == 1, gravity: rotation)
            .frame(width: size * 0.62, height: size)
            .rotationEffect(rotation)
            .scaleEffect(0.9 + 0.1 * fadeIn)
            .opacity(0.85 * fadeIn * fadeOld)
            .position(position)
    }

    /// 替换龙猫小手：一只 BT 手印跟着指针，选中花瓣时“按”下去
    private func btHand(at point: CGPoint) -> some View {
        let angle = model.pointerAngle ?? -Double.pi / 2
        let dir = CGVector(dx: cos(angle), dy: sin(angle))
        let base = CGPoint(x: point.x - dir.dx * 34, y: point.y - dir.dy * 34)
        let phase = model.pawPhase
        let press: CGFloat = Palette.reduceMotion ? 0 : (phase == .grasp ? 6 : (phase == .pull ? 4 : -3))
        return BTHandprint(seed: 7, gravity: .radians(angle + .pi / 2))
            .frame(width: 38, height: 60)
            .rotationEffect(.radians(angle + .pi / 2))
            .scaleEffect(phase == .grasp ? 0.86 : (phase == .pull ? 0.92 : 1))
            .offset(x: dir.dx * press, y: dir.dy * press)
            .position(base)
            .opacity(phase == .idle ? 0 : 0.95)
            .allowsHitTesting(false)
            .animation(Palette.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.6),
                       value: phase)
    }

    /// 唯一一只轻量小手：从环内伸向卡片，爪尖压在卡片边缘
    @ViewBuilder
    private func pawView(at point: CGPoint) -> some View {
        let angle = model.pointerAngle ?? -Double.pi / 2
        let dir = CGVector(dx: cos(angle), dy: sin(angle))
        // 爪子挂在卡片内侧（靠圆心那侧），爪尖朝卡片
        let base = CGPoint(x: point.x - dir.dx * 36, y: point.y - dir.dy * 36)

        let phase = model.pawPhase
        // 合拢时朝卡片再凑近一点，爪尖压住卡片边缘
        let moving: CGFloat = {
            guard !Palette.reduceMotion else { return 0 }
            switch phase {
            case .reach: return -4
            case .grasp: return 5
            case .pull:  return 3
            default:     return 0
            }
        }()
        let image = (phase == .grasp || phase == .pull) ? PawAssets.grasp : PawAssets.open

        let scale: CGFloat = 1.0
        let idleOpacity: Double = 0.9

        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 44 * scale, height: 56 * scale)
                .rotationEffect(.radians(angle + .pi / 2))
                .scaleEffect(phase == .grasp ? 1.14 : (phase == .pull ? 1.08 : 1))
                .offset(x: dir.dx * moving, y: dir.dy * moving)
                .position(base)
                .opacity(phase == .idle ? 0 : idleOpacity)
                .scaleEffect(phase == .idle ? 0.55 : 1)
                .shadow(color: .black.opacity(phase == .idle ? 0.10 : 0.16), radius: 2, y: 1)
                .allowsHitTesting(false)          // 不接收输入，避免和 Finder 拖放抢事件
                .animation(Palette.reduceMotion
                           ? .easeOut(duration: 0.12)
                           : .spring(response: 0.24, dampingFraction: 0.72),
                           value: phase)
        }
    }

    private var readingPill: some View {
        Text("读取文件…")
            .font(.system(size: Palette.TypeSize.caption, weight: .medium))
            .foregroundStyle(theme.ink.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(theme.tint.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.8))
            )
            .position(model.center)
    }

    /// 固定位置的选中说明：不挤压花瓣，也不参与命中
    private func selectionCaption(_ item: FanItem) -> some View {
        VStack(spacing: 2) {
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(model.hint(for: item))
                .font(.system(size: Palette.TypeSize.caption))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(width: 148)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Palette.Radius.card, style: .continuous)
                .fill(Palette.surface.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: Palette.Radius.card, style: .continuous)
                        .strokeBorder(Palette.line.opacity(0.55), lineWidth: 0.8)
                )
        )
        .position(model.center)
        .allowsHitTesting(false)
        .accessibilityIdentifier("fan.selectionCaption")
        .animation(Palette.reduceMotion ? nil : .easeOut(duration: 0.12), value: item.title)
    }

    private var centerBadge: some View {
        VStack(spacing: 1) {
            Text(model.mode.keyHint)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.tint)
            Text(model.highlighted == nil ? "松手取消" : model.mode.title)
                .font(.system(size: Palette.TypeSize.micro, weight: .medium))
                .foregroundStyle(model.highlighted == nil ? theme.tint.opacity(0.85) : .secondary)
            if model.fileCount > 1 {
                Text("\(model.fileCount) 个")
                    .font(.system(size: Palette.TypeSize.micro))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 84, height: 68)
        .background(
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(0.85)
                .overlay(
                    Circle().fill(theme.tint.opacity(0.10))
                )
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.75), theme.tint.opacity(0.30)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
                )
                .shadow(color: theme.tint.opacity(0.20), radius: 10, y: 1)
        )
        .position(model.center)
    }

    /// 水滴凝胶：高透明 + 顶部反光 + 白边
    /// 按标题算一个稳定的种子（`hashValue` 每次启动都不同），同一片花瓣的气泡位置保持不变。
    private static func gelSeed(_ title: String) -> UInt64 {
        title.unicodeScalars.reduce(5381) { ($0 &* 33) &+ UInt64($1.value) }
    }

    private func petal(item: FanItem, hot: Bool) -> some View {
        HStack(spacing: 6) {
            // 拷贝路径只显示文字，避免本地化文字图标被误认为路径内容。
            if item != .action(.copyPath) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11.5, weight: theme.isBeach ? .light : .medium))
                    // 冥滩：图标用灰白细线，不再用金色；金色只留给少数强调
                    .foregroundStyle(theme.isBeach ? Color.white.opacity(hot ? 0.9 : 0.5)
                                     : (hot ? theme.hotInk : Palette.brand))
                    .frame(width: 13)
            }
            Text(item.title)
                // 冥滩：细一点、字距拉开，接近游戏界面里克制的排版
                .font(.system(size: 14, weight: theme.isBeach ? .regular : .semibold))
                .tracking(theme.isBeach ? 0.8 : 0)
                // 未选中用深森林字；选中后底色换成实心强调色，字色跟着换成强调色上的前景
                .foregroundStyle(theme.isBeach ? Color.white.opacity(hot ? 0.97 : 0.72)
                                 : (hot ? theme.hotInk : Palette.textPrimary))
                .lineLimit(1)
                // “封面JPG”这类较长的名字在小花瓣里缩一点字号，不截断
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(width: model.petalWidth, height: model.petalHeight)
        .background(
            // 材质在拖动中不变，预先画成位图缓存，否则 drawingGroup 每帧都要重画几十个气泡或曲线
            Group {
                if theme.isBeach {
                    // 冥滩：一坨不规则的焦油，底部往下滴；滴痕画在花瓣下方，不占文字位置
                    let drip = model.petalHeight * 0.62
                    let ratio = model.petalHeight / (model.petalHeight + drip)
                    ZStack {
                        GelPetalCache.view(theme: theme, title: item.title, hot: hot, dark: colorScheme == .dark,
                                           size: CGSize(width: model.petalWidth, height: model.petalHeight + drip)) {
                            TarPetal(seed: Self.gelSeed(item.title), hot: hot, bodyRatio: ratio)
                        }
                        // 选中：焦油表面荡开涟漪、偶尔冒泡（只在被选中的这片上动，其余保持静止的缓存图）
                        if hot {
                            TarStirring(seed: Self.gelSeed(item.title), bodyRatio: ratio, since: hotSince,
                                        fixedTime: model.debugStirringTime)
                                .frame(width: model.petalWidth, height: model.petalHeight + drip)
                        }
                    }
                    .offset(y: drip / 2)
                } else {
                    // 凝胶花瓣：半透明胶体里悬着细小气泡；选中时胶体换成更浓的强调色
                    GelPetalCache.view(theme: theme, title: item.title, hot: hot, dark: colorScheme == .dark,
                                       size: CGSize(width: model.petalWidth, height: model.petalHeight)) {
                        GelSurface(shape: Capsule(),
                                   tint: hot ? theme.hotTop : theme.glassBottom,
                                   edge: hot ? theme.hotBottom : theme.tint,
                                   seed: Self.gelSeed(item.title),
                                   density: hot ? 1.25 : 1)
                    }
                }
            }
        )
    }
}

/// 凝胶花瓣的位图缓存：按主题、标题（决定气泡位置）、尺寸、是否选中和深浅外观区分。
/// 四周留出阴影的空间一起画进去，显示时再把这圈边距抵消掉。
@MainActor
enum GelPetalCache {
    static let scale: CGFloat = 2
    private static let margin: CGFloat = 16
    private static var images: [String: CGImage] = [:]

    @ViewBuilder
    static func view<Content: View>(theme: FanTheme, title: String, hot: Bool, dark: Bool, size: CGSize,
                                    @ViewBuilder content: () -> Content) -> some View {
        let key = "\(theme.rawValue)|\(title)|\(Int(size.width))x\(Int(size.height))|\(hot)|\(dark)"
        if let image = images[key] ?? render(key: key, dark: dark, size: size, content: content()) {
            Image(decorative: image, scale: scale)
                .resizable()
                .frame(width: size.width + margin * 2, height: size.height + margin * 2)
                .padding(-margin)
        } else {
            content()
        }
    }

    private static func render<Content: View>(key: String, dark: Bool, size: CGSize, content: Content) -> CGImage? {
        let renderer = ImageRenderer(content: content
            .frame(width: size.width, height: size.height)
            .padding(margin)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        var image: CGImage?
        // 主题色是动态颜色，按对应的深浅外观取值
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        if let image { images[key] = image }
        return image
    }
}
