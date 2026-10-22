import AppKit
import SwiftUI

/// 保留源文件与输出的一一对应，避免批量结果打开错误的对比对象。
struct OutputComparison: Sendable {
    let source: URL
    let output: URL
}

@MainActor
final class CompletionPanel {
    static let shared = CompletionPanel()

    struct Record {
        let message: String
        let outputs: [URL]
        let detail: String?
        let comparisons: [OutputComparison]
        let retry: (() -> Void)?
        let symbol: String
    }

    private var panel: NSPanel?
    private(set) var latest: Record?

    func present(message: String, outputs: [URL], detail: String?, comparisons: [OutputComparison] = [], retry: (() -> Void)? = nil,
                 symbol: String = "checkmark.circle.fill") {
        let record = Record(message: message, outputs: outputs, detail: detail, comparisons: comparisons, retry: retry, symbol: symbol)
        latest = record
        let content = CompletionView(record: record) { [weak self] in self?.panel?.orderOut(nil) }
        panel?.orderOut(nil)
        let panel = PanelKit.make(title: "Totori · 操作结果", size: NSSize(width: 520, height: 360), content: content)
        panel.identifier = NSUserInterfaceItemIdentifier("totori.completion")
        self.panel = panel
        PanelKit.present(panel)
    }
}

private struct CompletionView: View {
    let record: CompletionPanel.Record
    var close: () -> Void
    @AppStorage("totori.theme") private var themeRaw = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(record.message, systemImage: record.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let detail = record.detail {
                        Text(detail).font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                    ForEach(record.outputs, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent).font(.system(size: Palette.TypeSize.label, weight: .medium))
                            FileSummaryLabel(url: url)
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                                .lineLimit(2).textSelection(.enabled)
                            if let pair = record.comparisons.first(where: { $0.output == url }) {
                                Button("对比结果") {
                                    ComparisonWindow.shared.present(pairs: record.comparisons, selectedOutput: pair.output)
                                }
                                    .controlSize(.small)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if !record.outputs.isEmpty {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting(record.outputs)
                    }
                    .accessibilityIdentifier("completion.reveal")
                }
                Spacer()
                if let retry = record.retry {
                    Button("重试失败项") { close(); retry() }
                        .help("只重试失败项，沿用本次任务设置")
                }
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .tint(Palette.brand)
        .foregroundStyle(Palette.textPrimary)
        .background(Palette.surface)
    }
}
