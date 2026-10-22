import SwiftUI

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
    var pawWork: [DispatchWorkItem] = []
    var pawTarget: Int?
    var pawScheduled = false

    func petalAngle(_ index: Int) -> Double {
        FavoritePreviewGeometry.angle(index: index, count: items.count)
    }

    func cancelPaw() {
        pawWork.forEach { $0.cancel() }
        pawWork.removeAll()
    }

    func after(_ seconds: Double, _ block: @escaping () -> Void) {
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
    func drivePaw() {
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
    var impactTask: Task<Void, Never>?
    var impactRequest = UUID()

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

    var bloomTimer: Timer?

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

