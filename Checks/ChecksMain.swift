import AppKit
import SwiftUI
import ImageIO

/// 验收探针和开发期渲染入口（`--probe-*`、`--dump-*`、`--render-fan`、`--show-fan`、`--simulate-drag`）。
/// 只在带 `TOTORI_CHECKS` 的构建里编译；正式包里没有这些代码。
/// 构建方式见 README：`TOTORI_CHECKS=1 ./build.sh`。
func runChecksIfRequested() {
    // `--render-handprints <输出.png>`：把 6 个不同种子的 BT 手印放大画在深色底上，检查形状
    if let index = CommandLine.arguments.firstIndex(of: "--render-handprints"), CommandLine.arguments.count > index + 1 {
        let path = CommandLine.arguments[index + 1]
        let ok: Bool = MainActor.assumeIsolated {
            let grid = HStack(spacing: 30) {
                // 左右手交替；最后两个转了方向，用来检查滴痕是否仍朝下
                ForEach(1...6, id: \.self) { seed in
                    let angle = Angle.degrees(seed >= 5 ? (seed == 5 ? 60 : -90) : 0)
                    BTHandprint(seed: UInt64(seed) &+ 11, mirrored: seed % 2 == 0, gravity: angle)
                        .frame(width: 124, height: 200)
                        .rotationEffect(angle)
                }
            }
            .padding(30)
            .background(Color(red: 0.25, green: 0.26, blue: 0.28))
            let renderer = ImageRenderer(content: grid)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest)
        }
        exit(ok ? 0 : 1)
    }

    // `--convert <文件> <输出扩展名> <输出目录>`：开发时用真实文件试一次转换，走和主窗口相同的路径
    if let index = CommandLine.arguments.firstIndex(of: "--convert"), CommandLine.arguments.count > index + 3 {
        let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let ext = CommandLine.arguments[index + 2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 3])
        let kind = FormatCatalog.kind(of: source)
        guard let format = FormatCatalog.outputs(for: source).first(where: { $0.ext == ext }) else {
            print("不支持：\(source.lastPathComponent)（\(kind.title)）→ \(ext)；可选 \(FormatCatalog.outputs(for: source).map(\.ext))")
            exit(1)
        }
        let start = Date()
        do {
            let output = try Engine.convert(source: source, format: format, to: directory) { _ in }
            print("完成：\(output.path)（\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒）")
            exit(0)
        } catch {
            print("失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }

    if CommandLine.arguments.contains("--bench-fan") {
        exit(MainActor.assumeIsolated { FanFrameBench.run() })
    }

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
