import SwiftUI

// MARK: - 外观

enum FanTheme: String, CaseIterable, Identifiable {
    case forest // 森林凝胶 · 嫩叶绿（当前默认）
    case haze   // 晨雾蓝 · 30% 天蓝 + 70% 透明
    case aqua   // 玻璃蓝
    case mint   // 玻璃绿

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forest: return "森林绿"
        case .haze: return "晨雾蓝"
        case .aqua: return "玻璃蓝"
        case .mint: return "玻璃绿"
        }
    }

    var tint: Color {
        switch self {
        case .forest: return Palette.brand
        case .haze: return Color(red: 0.38, green: 0.74, blue: 0.95)
        case .aqua: return Color(red: 0.24, green: 0.60, blue: 1.00)
        case .mint: return Color(red: 0.16, green: 0.86, blue: 0.62)
        }
    }

    var tintLight: Color {
        switch self {
        case .forest: return Palette.glassTop
        case .haze: return Color(red: 0.90, green: 0.98, blue: 1.00)
        case .aqua: return Color(red: 0.55, green: 0.86, blue: 1.00)
        case .mint: return Color(red: 0.58, green: 0.98, blue: 0.72)
        }
    }

    /// 玻璃体渐变（品牌玻璃材质），与用于文字/选中的 tint 分开
    var glassTop: Color {
        switch self {
        case .forest: return Palette.glassTop
        case .haze: return Color(red: 0.85, green: 0.96, blue: 1.00)
        case .aqua: return Color(red: 0.55, green: 0.86, blue: 1.00)
        case .mint: return Color(red: 0.58, green: 0.98, blue: 0.72)
        }
    }

    var glassBottom: Color {
        switch self {
        case .forest: return Palette.glassBottom
        case .haze: return Color(red: 0.56, green: 0.80, blue: 0.88)
        case .aqua: return Color(red: 0.24, green: 0.60, blue: 1.00)
        case .mint: return Color(red: 0.16, green: 0.86, blue: 0.62)
        }
    }

    /// 浅色玻璃上用的文字色
    var ink: Color {
        switch self {
        case .forest: return Palette.textPrimary
        case .haze: return Color(red: 0.06, green: 0.26, blue: 0.40)
        case .aqua: return Color(red: 0.05, green: 0.18, blue: 0.34)
        case .mint: return Color(red: 0.04, green: 0.26, blue: 0.20)
        }
    }

    /// 选中花瓣的实心填充（强调色到悬停色）与其上的前景，所有主题共用，和主窗口按钮同一套取色。
    var hotTop: Color { Palette.brand }
    var hotBottom: Color { Palette.brandHover }
    var hotInk: Color { Palette.onAccent }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [tintLight, tint],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 三种滚轮

enum FanMode: String, CaseIterable, Identifiable {
    case convert, tools, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "转换格式"
        case .tools:   return "文件工具"
        case .actions: return "文件动作"
        }
    }

    var keyHint: String {
        KeyMap.effectiveKey(for: self)?.symbol ?? "—"
    }
}

enum ToolKind: String, CaseIterable, Identifiable {
    case cropImage, redactImage, compressImage, rotateRight, resizeSmall, stripMetadata, toPDF, mergePDF, splitPDF, zipArchive, qrText, trimMedia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cropImage:     return "裁剪"
        case .redactImage:   return "标注"
        case .compressImage: return "压缩图片"
        case .rotateRight:   return "右转 90°"
        case .stripMetadata: return "去元数据"
        case .mergePDF:      return "合并 PDF"
        case .splitPDF:      return "拆分 PDF"
        case .toPDF:         return "转成 PDF"
        case .zipArchive:    return "打包 ZIP"
        case .qrText:        return "识别二维码"
        case .trimMedia:     return "修剪"
        case .resizeSmall:   return "缩到一半"
        }
    }

    var hint: String {
        switch self {
        case .cropImage:     return "拖框选取"
        case .redactImage:   return "涂黑 / 画笔"
        case .compressImage: return "画质换体积"
        case .rotateRight:   return "顺时针"
        case .stripMetadata: return "抹掉 EXIF"
        case .mergePDF:      return "多份并一份"
        case .splitPDF:      return "一页一个"
        case .toPDF:         return "单页 PDF"
        case .zipArchive:    return "压缩包"
        case .qrText:        return "读内容并复制"
        case .trimMedia:     return "选区间截取"
        case .resizeSmall:   return "边长 50%"
        }
    }
}

enum ActionKind: String, CaseIterable, Identifiable {
    case airDrop, copy, move, copyPath, terminal, reveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDrop:  return "隔空投送"
        case .copy:     return "拷贝"
        case .move:     return "移动"
        case .copyPath: return "拷贝路径"
        case .terminal: return "终端"
        case .reveal:   return "在访达"
        }
    }

    var hint: String {
        switch self {
        case .airDrop:  return "发到附近设备"
        case .copy:     return "到剪贴板"
        case .move:     return "到下载文件夹"
        case .copyPath: return "POSIX 路径"
        case .terminal: return "打开所在目录"
        case .reveal:   return "显示位置"
        }
    }
}

/// 滚轮上的一项
enum FanItem: Identifiable, Hashable {
    case format(OutputFormat)
    case tool(ToolKind)
    case action(ActionKind)
    case moreFormats(FileKind)

    var id: String {
        switch self {
        case .format(let f): return "f.\(f.id)"
        case .tool(let t):   return "t.\(t.id)"
        case .action(let a): return "a.\(a.id)"
        case .moreFormats(let kind): return "more.\(kind.rawValue)"
        }
    }

    static func symbol(for format: OutputFormat) -> String {
        switch format.ext {
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v":
            return "film"
        case "gif":
            return "rectangle.stack.badge.play"
        case "mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "wma":
            return "music.note"
        case "png", "jpg", "heic", "tiff", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "html":
            return "globe"
        case "txt", "rtf", "docx", "odt":
            return "doc.text"
        case "zip":
            return "archivebox"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    var title: String {
        switch self {
        case .format(let f): return f.name
        case .tool(let t):   return t.title
        case .action(let a): return a.title
        case .moreFormats: return "更多"
        }
    }

    var hint: String {
        switch self {
        case .format(let f): return f.hint
        case .tool(let t):   return t.hint
        case .action(let a): return a.hint
        case .moreFormats: return "松手后选择其他格式"
        }
    }

    var symbol: String {
        switch self {
        case .format(let f):     return FanItem.symbol(for: f)
        case .moreFormats:      return "ellipsis.circle"
        case .tool(let t):
            switch t {
            case .cropImage:     return "crop"
            case .redactImage:   return "rectangle.fill"
            case .compressImage: return "arrow.down.right.and.arrow.up.left"
            case .rotateRight:   return "rotate.right"
            case .stripMetadata: return "eye.slash"
            case .toPDF:         return "doc.richtext"
            case .mergePDF:      return "doc.on.doc.fill"
            case .splitPDF:      return "scissors"
            case .zipArchive:    return "archivebox"
            case .qrText:        return "qrcode.viewfinder"
            case .trimMedia:     return "scissors"
            case .resizeSmall:   return "arrow.down.left.and.arrow.up.right"
            }
        case .action(let a):
            switch a {
            case .airDrop:  return "antenna.radiowaves.left.and.right"
            case .copy:     return "doc.on.doc"
            case .move:     return "folder"
            case .copyPath: return "link"
            case .terminal: return "terminal"
            case .reveal:   return "magnifyingglass"
            }
        }
    }
}

// MARK: - 状态

@MainActor
final class FanModel: ObservableObject {
    @Published private(set) var mode: FanMode = .convert
    @Published private(set) var items: [FanItem] = []
    @Published var highlighted: Int? = nil {
        didSet {
            drivePaw()
            // 换到另一片花瓣时给触控板一下轻触，手在拖拽时不看屏幕也知道已经选中。
            if highlighted != nil, highlighted != oldValue {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    // 龙猫小手：静止 → 探出 → 合拢 → 轻带
    enum PawPhase: Equatable { case idle, reach, grasp, pull }
    /// 爪子指向：拖动中才存在；nil = 收回到环里不可见
    @Published var pointerAngle: Double?
    /// 指针位置（view 坐标），用来放我们自己的小卡片
    @Published var pointerPoint: CGPoint?
    /// 被拖文件的图标（来自控制器）
    @Published var fileIcon: NSImage?
    @Published var fileLabel: String = ""
    @Published var pawPhase: PawPhase = .idle
    private var pawWork: [DispatchWorkItem] = []
    private var pawTarget: Int?
    private var pawScheduled = false

    func petalAngle(_ index: Int) -> Double {
        FavoritePreviewGeometry.angle(index: index, count: items.count)
    }

    private func cancelPaw() {
        pawWork.forEach { $0.cancel() }
        pawWork.removeAll()
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        pawWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 拖动位置驱动：只有一只爪子，跟着指针绕环绕
    func updatePointer(_ point: CGPoint) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        // 回到中心死区 = 取消，爪子收回
        if distance < petalHeight * 0.75 {
            if pointerAngle != nil {
                pointerAngle = nil
                pointerPoint = nil
                drivePaw()          // 进死区也要收爪子，不能停在 reach
            }
            return
        }
        pointerAngle = atan2(dy, dx)
        pointerPoint = point
        drivePaw()                  // 内部幂等：同目标的序列不会被重排
    }

    /// 只在视觉层：无目标时张开跟随，有目标时合拢再轻带；从不触发真实转换
    private func drivePaw() {
        guard pointerAngle != nil else {
            cancelPaw()
            pawScheduled = false
            pawTarget = nil
            pawPhase = .idle
            return
        }
        guard let target = highlighted else {
            if pawTarget != nil || pawScheduled || pawPhase != .reach {
                cancelPaw()
                pawScheduled = false
                pawTarget = nil
                pawPhase = .reach      // 拖动中但还没对上花瓣：张开跟随
            }
            return
        }

        // 25ms 一次的轮询会反复进来；同一目标已经在跑或已停在 pull，就不要再重排计时器，
        // 否则 60ms 的 grasp 永远等不到。（真实拖动时的稳定复现点）
        if pawTarget == target {
            if pawScheduled || pawPhase == .pull { return }
        }

        cancelPaw()
        pawTarget = target
        pawScheduled = true
        pawPhase = .reach
        after(0.06) { [weak self] in
            guard let self, self.highlighted == target else { return }
            self.pawPhase = .grasp
        }
        after(0.20) { [weak self] in
            guard let self, self.highlighted == target else { return }
            self.pawPhase = .pull
            self.pawScheduled = false
        }
    }

    func resetPaw() {
        cancelPaw()
        pawScheduled = false
        pawTarget = nil
        pawPhase = .idle
        pointerAngle = nil
        pointerPoint = nil
    }
    @Published var fileCount: Int = 0
    @Published private(set) var impactSources: [FileMetadataSnapshot] = []
    private var impactTask: Task<Void, Never>?
    private var impactRequest = UUID()

    func loadImpactSources(_ urls: [URL]) {
        clearImpactSources()
        let request = impactRequest
        impactTask = Task { [weak self] in
            let values = await ConversionImpact.read(urls)
            guard !Task.isCancelled, let self, self.impactRequest == request else { return }
            self.impactSources = values
            self.impactTask = nil
        }
    }

    func clearImpactSources() {
        impactTask?.cancel()
        impactTask = nil
        impactRequest = UUID()
        impactSources = []
    }

    func hint(for item: FanItem) -> String {
        if case .format(let format) = item {
            return ConversionImpact.text(format: format, sources: impactSources)
        }
        return item.hint
    }
    @Published var appeared = false
    /// 花瓣依次张开的进度（0→1），由定时器驱动，不依赖 SwiftUI 隐式动画
    @Published var bloom: Double = 1

    /// 面板固定尺寸；内容按花瓣数量自适应
    static let panelSize: CGFloat = 680

    var petalWidth: CGFloat {
        switch items.count {
        case 0...8:  return 110
        case 9...11: return 100
        default:     return 88
        }
    }

    var petalHeight: CGFloat { max(52, petalWidth * 0.60) }

    var radius: CGFloat { FanModel.radiusFor(items: items.count) }

    /// 选中放大倍数。花瓣多时环本来就挤，放大幅度收小，避免整个环被撑大。
    static func hoverScale(forCount count: Int) -> CGFloat {
        if Palette.reduceMotion { return 1 }
        return count >= 12 ? 1.12 : 1.16
    }

    /// 未选中花瓣在有选中项时稍微退后，让被选中的那片自然“浮”出来。
    static let dimmedScale: CGFloat = 0.97

    static func radiusFor(items count: Int) -> CGFloat {
        guard count > 1 else { return 140 }
        let width: CGFloat = count <= 8 ? 110 : (count <= 11 ? 100 : 88)
        let height = max(52, width * 0.60)
        let scale = hoverScale(forCount: count)
        let horizontal = width * (1 + scale) / 2 + 8
        let vertical = height * (1 + scale) / 2 + 8
        var radius: CGFloat = 140
        // 花瓣保持水平；按实际矩形间距留出一瓣选中放大的空间。
        for a in 0..<count {
            for b in (a + 1)..<count {
                let angleA = -Double.pi / 2 + Double(a) * 2 * Double.pi / Double(count)
                let angleB = -Double.pi / 2 + Double(b) * 2 * Double.pi / Double(count)
                let dx = CGFloat(abs(cos(angleA) - cos(angleB)))
                let dy = CGFloat(abs(sin(angleA) - sin(angleB)))
                let xRadius = dx > 0.0001 ? horizontal / dx : CGFloat.infinity
                let yRadius = dy > 0.0001 ? vertical / dy : CGFloat.infinity
                radius = max(radius, min(xRadius, yRadius))
            }
        }
        return ceil(radius)
    }

    var canvas: CGFloat { (radius + petalWidth * 0.74) * 2 }
    var center: CGPoint { CGPoint(x: canvas / 2, y: canvas / 2) }

    /// 只换内容；入场动画交给 Core Animation（与原版一致）
    func configure(mode: FanMode, items: [FanItem], fileCount: Int) {
        self.mode = mode
        self.items = items
        self.fileCount = fileCount
        self.highlighted = nil
        self.appeared = true
        resetPaw()
    }

    private var bloomTimer: Timer?

    /// 内容恒定可见；入场由 CA 层 + 花瓣时间轴共同负责
    func playEntrance() {
        appeared = true
        runBloom()
    }

    /// 0 → 1 的时间轴，60Hz，约 0.45 秒；每片花瓣按 index 错开
    func runBloom() {
        bloomTimer?.invalidate()
        bloom = 0
        let started = Date()
        let duration = 0.45
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = Date().timeIntervalSince(started)
                let progress = min(1, elapsed / duration)
                self.bloom = progress
                if progress >= 1 {
                    timer.invalidate()
                    self.bloomTimer = nil
                }
            }
        }
        // 兜底：若 150ms 内一帧都没走（定时器被系统节流），直接显示终态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.bloomTimer != nil, self.bloom < 0.12 else { return }
            self.bloomTimer?.invalidate()
            self.bloomTimer = nil
            self.bloom = 1
            DiagLog.write("bloom 被节流，直接置终态")
        }
        RunLoop.main.add(timer, forMode: .common)
        bloomTimer = timer
    }

    /// 兼容旧调用
    func apply(mode: FanMode, items: [FanItem], fileCount: Int) {
        configure(mode: mode, items: items, fileCount: fileCount)
        playEntrance()
    }

    func petalCenter(_ index: Int) -> CGPoint {
        FavoritePreviewGeometry.point(index: index, count: items.count, radius: radius, center: center)
    }

    func petalIndex(at point: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        // 中心死区：回中就是「什么都不选」，不是保持上一次的选择
        if distance < petalHeight * 0.75 { return nil }
        // 超出环也照样按方向选中：环固定不动，手可以拖很远


        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        let step = 2 * Double.pi / Double(items.count)
        return Int((angle / step).rounded()) % items.count
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = highlighted ?? -1
        var next = current + delta
        if next < 0 { next = items.count - 1 }
        if next >= items.count { next = 0 }
        highlighted = next
    }
}

// MARK: - 视图

struct FanView: View {
    @ObservedObject var model: FanModel
    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue

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

    // 森林凝胶底盘：薄雾 + 一圈细边
    private var backdrop: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            theme.tint.opacity(0.13),
                            theme.tint.opacity(0.045),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: model.canvas / 2
                    )
                )

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            theme.tint.opacity(0.18),
                            Color.white.opacity(0.28),
                            theme.tint.opacity(0.10),
                            Color.white.opacity(0.55),
                        ],
                        center: .center
                    ),
                    lineWidth: 0.8
                )
                .frame(width: model.radius * 2 + 26, height: model.radius * 2 + 26)
                .blur(radius: 0.3)
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
            ZStack {
                // 毛玻璃底
                Capsule().fill(.ultraThinMaterial).opacity(0.32)
                // 颜料：天蓝打底，再叠一层上白下蓝，做出透亮感
                Capsule().fill(
                    LinearGradient(
                        colors: [
                            theme.glassTop.opacity(hot ? 0.88 : 0.72),
                            theme.glassBottom.opacity(hot ? 0.82 : 0.52),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                Capsule().fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hot ? 0.48 : 0.38),
                            theme.glassTop.opacity(hot ? 0.20 : 0.10),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // 顶面高光，做出水感
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(hot ? 0.85 : 0.70),
                                Color.white.opacity(0.10),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .blur(radius: 1.6)
                // 选中：实心强调色盖在玻璃上，一眼就能和其余花瓣区分开
                Capsule().fill(
                    LinearGradient(colors: [theme.hotTop, theme.hotBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
                .opacity(hot ? 1 : 0)
                // 软边：白在上、蓝在下，不像药丸
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hot ? 0.90 : 0.72),
                            theme.tint.opacity(hot ? 0.65 : 0.38),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
            .compositingGroup()
            .shadow(color: theme.tint.opacity(hot ? 0.40 : 0.22),
                    radius: hot ? 18 : 13, y: hot ? 4 : 3)
        )
    }
}
