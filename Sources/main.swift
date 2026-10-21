import AppKit

// 无 GUI 的分发自检：确认工具来自当前 App，而不是开发机路径。
if CommandLine.arguments.contains("--probe-runtime") {
    var failed = false
    for name in ["ffmpeg", "ffprobe", "cwebp", "soffice"] {
        guard let path = Shell.which(name) else {
            print("MISSING \(name)")
            failed = true
            continue
        }
        let bundled = URL(fileURLWithPath: path).path.hasPrefix(Bundle.main.bundleURL.path + "/")
        print("\(name): \(path) [bundled=\(bundled)]")
        if !bundled { failed = true }
        do {
            let result = try Shell.run(path, [name == "soffice" ? "--version" : "-version"],
                                       captureOutput: true, timeout: 30)
            print(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if result.status != 0 || result.timedOut { failed = true }
        } catch {
            print(error.localizedDescription)
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}

if CommandLine.arguments.contains("--probe-comparison-batch") {
    var result: Int32?
    Task { @MainActor in result = await ComparisonBatchProbe.run() }
    while result == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    exit(result!)
}

if CommandLine.arguments.contains("--probe-recent-tasks") {
    exit(MainActor.assumeIsolated { RecentTasksProbe.run() })
}

if CommandLine.arguments.contains("--probe-favorite-preview") {
    exit(MainActor.assumeIsolated { FavoritePreviewProbe.run() })
}

if CommandLine.arguments.contains("--probe-conversion-impact") {
    exit(MainActor.assumeIsolated { ConversionImpactProbe.run() })
}

if CommandLine.arguments.contains("--probe-favorites") {
    exit(MainActor.assumeIsolated { FavoriteFormatsProbe.run() })
}

if CommandLine.arguments.contains("--probe-shelf-enhancements") {
    exit(MainActor.assumeIsolated { ShelfEnhancementProbe.run() })
}

if CommandLine.arguments.contains("--probe-output-summary") {
    exit(MainActor.assumeIsolated { OutputSummaryProbe.run() })
}

if CommandLine.arguments.contains("--probe-task-options") {
    exit(MainActor.assumeIsolated { TaskOptionsProbe.run() })
}

if CommandLine.arguments.contains("--probe-fan-safety") {
    exit(MainActor.assumeIsolated { FanSafetyProbe.run() })
}

if CommandLine.arguments.contains("--probe-interactions") {
    exit(MainActor.assumeIsolated { InteractionProbe.run() })
}

if CommandLine.arguments.contains("--probe-comparison-ui") {
    exit(MainActor.assumeIsolated { ComparisonUIProbe.run() })
}

if CommandLine.arguments.contains("--probe-shelf-ui") {
    exit(MainActor.assumeIsolated { ShelfUIProbe.run() })
}

if CommandLine.arguments.contains("--probe-workflow") {
    exit(MainActor.assumeIsolated { WorkflowProbe.run() })
}

if CommandLine.arguments.contains("--probe-iteration") {
    exit(MainActor.assumeIsolated { IterationProbe.run() })
}

// 无 Xcode 环境下的入口。
// --selftest：跑转换自检后退出，不启动 GUI。
// --show-fan：验证扇形几何与命中测试。
if CommandLine.arguments.contains("--probe-menu-mode") {
    exit(MainActor.assumeIsolated { MenuModeProbe.run() })
}
if let index = CommandLine.arguments.firstIndex(of: "--probe-acceptance") {
    let inputs = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "/Users/mac/Documents/Codex/2026-10-19/zhe/work/acceptance/inputs"
    exit(MainActor.assumeIsolated { AcceptanceProbe.run(inputs: inputs) })
}
if CommandLine.arguments.contains("--probe-paw-tick") {
    exit(MainActor.assumeIsolated { PawTickProbe.run() })
}
if CommandLine.arguments.contains("--probe-fan-level") {
    exit(MainActor.assumeIsolated { FanLevelProbe.run() })
}
if CommandLine.arguments.contains("--probe-paw") {
    exit(MainActor.assumeIsolated { PawProbe.run() })
}
if CommandLine.arguments.contains("--probe-theme") {
    exit(MainActor.assumeIsolated { ThemeProbe.run() })
}
if CommandLine.arguments.contains("--probe-assets") {
    exit(MainActor.assumeIsolated { AssetProbe.run() })
}
if let index = CommandLine.arguments.firstIndex(of: "--dump-main") {
    let path = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : "/tmp/xiaoju-main.png"
    exit(MainActor.assumeIsolated { MainWindowRender.run(outputPath: path) })
}
if CommandLine.arguments.contains("--probe-shelf") {
    exit(MainActor.assumeIsolated { ShelfProbe.run() })
}
if CommandLine.arguments.contains("--probe-anim") {
    exit(MainActor.assumeIsolated { FanAnimProbe.run() })
}
if CommandLine.arguments.contains("--simulate-drag") {
    exit(MainActor.assumeIsolated { FanSimulation.run() })
}
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if let index = CommandLine.arguments.firstIndex(of: "--dump-panel") {
    let path = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "/tmp/xiaoju-panel.png"
    exit(MainActor.assumeIsolated { FanCapture.run(outputPath: path) })
}
if let index = CommandLine.arguments.firstIndex(of: "--render-fan") {
    let path = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "/tmp/xiaoju-fan.png"
    exit(MainActor.assumeIsolated { FanRender.run(outputPath: path) })
}
if CommandLine.arguments.contains("--show-fan") {
    exit(FanDebug.run())
}

TangerineLiteApp.main()
