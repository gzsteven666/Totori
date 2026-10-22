import AppKit

/// 验收探针和开发期渲染入口（`--probe-*`、`--dump-*`、`--render-fan`、`--show-fan`、`--simulate-drag`）。
/// 只在带 `TOTORI_CHECKS` 的构建里编译；正式包里没有这些代码。
/// 构建方式见 README：`TOTORI_CHECKS=1 ./build.sh`。
func runChecksIfRequested() {
    if CommandLine.arguments.contains("--probe-menu-mode") {
        exit(MainActor.assumeIsolated { MenuModeProbe.run() })
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

    if let index = CommandLine.arguments.firstIndex(of: "--probe-acceptance") {
        let inputs = CommandLine.arguments.count > index + 1
            ? CommandLine.arguments[index + 1]
            : ProbeFixtures.inputs.path
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
            ? CommandLine.arguments[index + 1] : "/tmp/totori-main.png"
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

    if let index = CommandLine.arguments.firstIndex(of: "--dump-panel") {
        let path = CommandLine.arguments.count > index + 1
            ? CommandLine.arguments[index + 1]
            : "/tmp/totori-panel.png"
        exit(MainActor.assumeIsolated { FanCapture.run(outputPath: path) })
    }

    if let index = CommandLine.arguments.firstIndex(of: "--render-fan") {
        let path = CommandLine.arguments.count > index + 1
            ? CommandLine.arguments[index + 1]
            : "/tmp/totori-fan.png"
        exit(MainActor.assumeIsolated { FanRender.run(outputPath: path) })
    }

    if CommandLine.arguments.contains("--show-fan") {
        exit(FanDebug.run())
    }
}
