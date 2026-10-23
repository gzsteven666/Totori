import SwiftUI

// MARK: - 视图

struct FanView: View {
    @ObservedObject var model: FanModel
    @AppStorage("totori.theme") private var themeRaw: String = FanTheme.forest.rawValue

    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        ZStack {
            backdrop
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
                if PawAssets.open != nil { pawView(at: point) }
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

    /// 底盘直径，与 `FanGlassBackdrop.discDiameter` 一致
    private var discDiameter: CGFloat { model.radius * 2 + 26 }

    /// 凝胶底盘的光影层，叠在系统玻璃上面。
    /// 系统玻璃负责“透”；这里补上凝胶的“厚”：边缘一圈更浓的主题色、左上弧形高光、
    /// 底部内侧汇聚的透光。中心保持干净，不再铺一层雾，背后的桌面才看得清。
    private var backdrop: some View {
        let d = discDiameter
        return ZStack {
            // 边缘加厚：越靠边越浓，中间几乎无色
            Circle()
                .fill(RadialGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .clear, location: 0.70),
                                             .init(color: theme.tint.opacity(0.10), location: 0.90),
                                             .init(color: theme.tint.opacity(0.22), location: 1)],
                                     center: .center, startRadius: 0, endRadius: d / 2))
            // 底部内侧透光：光穿过凝胶在下沿汇聚
            Circle()
                .trim(from: 0.12, to: 0.38)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .blur(radius: 7)
                .padding(9)
            // 左上弧形高光：像窗户在球面上的反光
            Circle()
                .trim(from: 0.56, to: 0.80)
                .stroke(LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.85),
                                                Color.white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .blur(radius: 1.2)
                .padding(7)
            // 外轮廓：上亮下带主题色
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.80), Color.white.opacity(0.20),
                                                      theme.tint.opacity(0.45)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 1.2)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .position(model.center)
        .allowsHitTesting(false)
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hot ? theme.hotInk : Palette.brand)
                    .frame(width: 13)
            }
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                // 未选中用深森林字；选中后底色换成实心强调色，字色跟着换成强调色上的前景
                .foregroundStyle(hot ? theme.hotInk : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(width: model.petalWidth, height: model.petalHeight)
        .background(
            // 凝胶花瓣：半透明胶体里悬着细小气泡；选中时胶体换成更浓的强调色
            GelSurface(shape: Capsule(),
                       tint: hot ? theme.hotTop : theme.glassBottom,
                       edge: hot ? theme.hotBottom : theme.tint,
                       seed: Self.gelSeed(item.title),
                       density: hot ? 1.25 : 1)
        )
    }
}
