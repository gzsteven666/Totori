import SwiftUI

/// 更多格式与主窗口使用同一规则。文件变更时丢弃旧简介，格式切换不重复读文件。
struct ConversionImpactLabel: View {
    let urls: [URL]
    let format: OutputFormat
    @State private var sources: [FileMetadataSnapshot] = []

    var body: some View {
        Text(ConversionImpact.text(format: format, sources: sources))
            .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("moreFormats.impact")
            .task(id: urls) {
                sources = []
                let snapshots = await ConversionImpact.read(urls)
                guard !Task.isCancelled else { return }
                sources = snapshots
            }
    }
}
