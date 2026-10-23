import AppKit
import QuartzCore
import SwiftUI

/// 花瓣拖动帧率基准：`--bench-fan`。
///
/// 两项测量，改前改后用同一份探针各跑一遍对比：
/// 1. 屏上帧率（macOS 14+）：轮盘真实显示在屏幕上，用屏幕的 display link 每帧把“指针”沿花瓣环移动，
///    4 秒转两圈，期间选中项不断切换、弹簧动画持续进行，和快速拖动时一样。
///    主线程每帧要做 SwiftUI 更新和 drawingGroup 光栅化，忙不过来时 display link 回调会被推迟，
///    所以用回调间隔统计帧率、P95/P99 间隔和掉帧数（间隔 > 1.5 个刷新周期）。
/// 2. 单帧渲染耗时：离屏用 ImageRenderer 连续渲染 120 帧（每帧换指针位置和选中项），
///    看一帧光栅化要多少毫秒，和刷新周期预算比较。不含动画插值，只看画一帧的成本。
///
/// 轮盘会在鼠标位置出现几秒钟。
@MainActor
enum FanFrameBench {
    /// 让屏上测量的执行者在回调期间一直存活
    static var keepAlive: AnyObject?

    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // `--bench-fan <视频文件>`：用真实视频才能拿到最多的花瓣（音视频全部格式）；
        // 文件类型按文件头识别，空文件拿不到视频的花瓣。
        let index = CommandLine.arguments.firstIndex(of: "--bench-fan")!
        let given = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
        let sample = URL(fileURLWithPath: given.isEmpty || given.hasPrefix("-")
                         ? NSTemporaryDirectory() + "totori-bench.mp4" : given)
        if !FileManager.default.fileExists(atPath: sample.path) {
            FileManager.default.createFile(atPath: sample.path, contents: Data())
        }
        let rounds = 3
        let maxFPS = NSScreen.main?.maximumFramesPerSecond ?? 60

        DispatchQueue.main.async {
            FanController.shared.showForDebug(mode: .convert, urls: [sample])
            let model = FanController.shared.model
            // `--all`：换成音视频全部 15 个格式的整圈轮盘，测花瓣最多的情况
            if CommandLine.arguments.contains("--all") {
                model.apply(mode: .convert, items: FormatCatalog.formats(for: .media).map { .format($0) },
                            fileCount: 1)
                FanController.shared.debugRelayout()
            }
            model.appeared = true
            model.bloom = 1
            print("== 花瓣拖动帧率 ==")
            print("屏幕最高刷新率 \(maxFPS) Hz，花瓣 \(model.items.count) 片")
            print("[离屏单帧渲染]")
            printRenderCost(model: model, maxFPS: maxFPS)

            guard #available(macOS 14.0, *),
                  let view = NSApp.windows.first(where: { $0 is FanPanel })?.contentView else {
                print("屏上帧率需要 macOS 14+ 和可见的轮盘窗口，跳过")
                exit(0)
            }
            print("[屏上拖动，\(rounds) 轮 × 4 秒]")
            let runner = OnScreenRunner(view: view, model: model, rounds: rounds, maxFPS: maxFPS)
            runner.next()
            keepAlive = runner
        }
        app.run()
        return 0
    }

    /// 离屏渲染 120 帧，报告每帧耗时
    private static func printRenderCost(model: FanModel, maxFPS: Int) {
        // 每帧新建渲染器：同一个 ImageRenderer 不跟踪模型变化，会直接返回缓存的图
        func render() {
            let renderer = ImageRenderer(content: FanView(model: model)
                .frame(width: model.canvas, height: model.canvas))
            renderer.scale = 2
            _ = renderer.cgImage
        }
        // 预热：首帧含字体、着色器等一次性开销
        for _ in 0..<5 { render() }
        var samples: [Double] = []
        let count = model.items.count
        for frame in 0..<120 {
            let angle = Double(frame) / 120 * 4 * Double.pi - Double.pi / 2
            let point = CGPoint(x: model.center.x + CGFloat(cos(angle)) * model.radius,
                                y: model.center.y + CGFloat(sin(angle)) * model.radius)
            model.updatePointer(point)
            model.highlighted = count > 0 ? model.petalIndex(at: point) : nil
            let start = CACurrentMediaTime()
            render()
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        let stats = Stats(samples)
        print(String(format: "  每帧平均 %.2f ms，P95 %.2f ms，最长 %.2f ms（%d Hz 每帧预算 %.2f ms）",
                     stats.mean, stats.p95, stats.max, maxFPS, 1000 / Double(maxFPS)))
    }

    static func summarize(_ results: [OnScreenResult]) {
        guard !results.isEmpty else { return }
        let n = Double(results.count)
        print(String(format: "  汇总：%.1f fps，平均 %.2f ms，P95 %.2f ms，P99 %.2f ms，掉帧共 %d/%d",
                     results.map(\.fps).reduce(0, +) / n,
                     results.map(\.mean).reduce(0, +) / n,
                     results.map(\.p95).reduce(0, +) / n,
                     results.map(\.p99).reduce(0, +) / n,
                     results.map(\.dropped).reduce(0, +),
                     results.map(\.frames).reduce(0, +)))
    }
}

struct OnScreenResult {
    let fps: Double, mean: Double, p95: Double, p99: Double, max: Double
    let dropped: Int, frames: Int
}

struct Stats {
    let mean: Double, p95: Double, p99: Double, max: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
        }
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
        max = sorted.last ?? 0
    }
}

/// 依次跑几轮屏上测量，跑完汇总并退出。
@available(macOS 14.0, *)
@MainActor
final class OnScreenRunner {
    private let view: NSView
    private let model: FanModel
    private let rounds: Int
    private let maxFPS: Int
    private var results: [OnScreenResult] = []
    private var ticker: DragTicker?

    init(view: NSView, model: FanModel, rounds: Int, maxFPS: Int) {
        self.view = view
        self.model = model
        self.rounds = rounds
        self.maxFPS = maxFPS
    }

    func next() {
        guard results.count < rounds else {
            FanFrameBench.summarize(results)
            FanController.shared.hide()
            exit(0)
        }
        let ticker = DragTicker(model: model, maxFPS: maxFPS) { [weak self] result in
            guard let self else { return }
            self.results.append(result)
            print(String(format: "  第 %d 轮：%.1f fps，平均 %.2f ms，P95 %.2f ms，P99 %.2f ms，最长 %.2f ms，掉帧 %d/%d",
                         self.results.count, result.fps, result.mean, result.p95, result.p99, result.max,
                         result.dropped, result.frames))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.next() }
        }
        self.ticker = ticker
        ticker.start(on: view)
    }
}

/// 每帧沿花瓣环移动指针；先预热 0.5 秒，再记录 4 秒的回调时间戳。
@available(macOS 14.0, *)
@MainActor
final class DragTicker: NSObject {
    private let model: FanModel
    private let maxFPS: Int
    private let done: (OnScreenResult) -> Void
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var stamps: [CFTimeInterval] = []
    private let warmup: CFTimeInterval = 0.5
    private let duration: CFTimeInterval = 4

    init(model: FanModel, maxFPS: Int, done: @escaping (OnScreenResult) -> Void) {
        self.model = model
        self.maxFPS = maxFPS
        self.done = done
    }

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(maxFPS), maximum: Float(maxFPS),
                                                        preferred: Float(maxFPS))
        link.add(to: .main, forMode: .common)
        self.link = link
        startTime = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = now - startTime
        // 4 秒两圈：每片花瓣都会被经过两次，选中项频繁切换
        let angle = elapsed / duration * 4 * Double.pi - Double.pi / 2
        let point = CGPoint(x: model.center.x + CGFloat(cos(angle)) * model.radius,
                            y: model.center.y + CGFloat(sin(angle)) * model.radius)
        model.updatePointer(point)
        let index = model.petalIndex(at: point)
        if index != model.highlighted { model.highlighted = index }

        if elapsed >= warmup { stamps.append(now) }
        if elapsed >= warmup + duration {
            link.invalidate()
            self.link = nil
            done(result())
        }
    }

    private func result() -> OnScreenResult {
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let stats = Stats(intervals)
        let budget = 1000 / Double(maxFPS)
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        return OnScreenResult(fps: span > 0 ? Double(intervals.count) / span : 0,
                              mean: stats.mean, p95: stats.p95, p99: stats.p99, max: stats.max,
                              dropped: intervals.filter { $0 > budget * 1.5 }.count,
                              frames: intervals.count)
    }
}
