import AppKit
import SwiftUI

/// 常用花瓣的显式配置窗口；顺序只在用户点击上下移动时改变。
@MainActor
final class FavoriteFormatsWindow {
    static let shared = FavoriteFormatsWindow()
    private var panel: NSPanel?

    func present() {
        panel?.close()
        let panel = PanelKit.make(title: "Totori · 常用格式花瓣", size: NSSize(width: 640, height: 700), content: FavoriteFormatsView())
        panel.identifier = NSUserInterfaceItemIdentifier("totori.favorites")
        self.panel = panel
        PanelKit.present(panel)
    }
}

struct FavoriteFormatsView: View {
    @State private var kind: FileKind = .image
    @State private var formats = FavoriteFormats.formats(for: .image)
    @State private var notice: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Picker("文件类型", selection: $kind) {
                ForEach(FavoriteFormats.configurableKinds, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("favorites.kind")
            Text("固定 4—6 个常用格式，按下面的顺序排列。修改在下次呼出花瓣时生效。")
                .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            HStack(alignment: .top, spacing: 14) {
                FavoritePreviewView(kind: kind, formats: formats)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("常用顺序 · \(formats.count)/6").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("恢复默认") { FavoriteFormats.reset(kind); reload(); notice = "已恢复默认，下一次呼出生效" }
                            .controlSize(.small).accessibilityIdentifier("favorites.reset")
                            .help("只恢复当前文件类型的默认格式")
                    }
                    VStack(spacing: 5) {
                ForEach(Array(formats.enumerated()), id: \.element.id) { index, format in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(Palette.textSecondary).frame(width: 18)
                        Text(format.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("上移 \(format.name)")
                            .accessibilityIdentifier("favorites.up.\(format.ext)")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == formats.count - 1).accessibilityLabel("下移 \(format.name)")
                            .accessibilityIdentifier("favorites.down.\(format.ext)")
                    }.padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Palette.brandSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
                    }
                    Text("从 12 点起，按顺时针排列；“更多”位于末尾。")
                        .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("选择格式").font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(FormatCatalog.formats(for: kind)) { format in
                    let selected = formats.contains { $0.ext == format.ext }
                    Button { toggle(format) } label: {
                        Label(format.name, systemImage: selected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered).tint(selected ? Palette.brand : Palette.textSecondary)
                        .accessibilityValue(selected ? "常用" : "未固定")
                        .accessibilityIdentifier("favorites.toggle.\(format.ext)")
                }
            }
            Text(notice ?? "其余格式可从“更多”或主窗口选择。常用位置不会按使用频率自动重排。")
                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("favorites.notice")
            Spacer(minLength: 0)
        }.padding(20)
        }.frame(width: 640, height: 700).background(Palette.canvas).tint(Palette.brand)
            .onChange(of: kind) { _ in reload(); notice = nil }
    }

    private func reload() { formats = FavoriteFormats.formats(for: kind) }

    private func toggle(_ format: OutputFormat) {
        var order = formats.map(\.ext)
        if let index = order.firstIndex(of: format.ext) {
            guard order.count > 4 else { notice = "至少保留 4 个常用格式；先添加一个，再移除。"; return }
            order.remove(at: index)
        } else {
            guard order.count < 6 else { notice = "最多固定 6 个常用格式；先移除一个，再添加。"; return }
            order.append(format.ext)
        }
        FavoriteFormats.set(order, for: kind)
        reload()
        notice = "已保存，下一次呼出花瓣时生效"
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard formats.indices.contains(target) else { return }
        var order = formats.map(\.ext)
        order.swapAt(index, target)
        FavoriteFormats.set(order, for: kind)
        reload()
        notice = "顺序已保存，下一次呼出花瓣时生效"
    }
}

/// 更多格式在松手后单独选择，拖动中的常用花瓣保持固定，不自动展开换位。
@MainActor
final class MoreFormatsWindow {
    static let shared = MoreFormatsWindow()
    private var panel: NSPanel?
    private(set) var debugRequestCount = 0

    func present(urls: [URL]) {
        guard let first = urls.first else { return }
        let formats = FormatCatalog.formats(for: FormatCatalog.kind(of: first))
        guard !formats.isEmpty else { return }
        panel?.close()
        debugRequestCount += 1
        let view = MoreFormatsView(urls: urls, formats: formats,
                                   onCancel: { [weak self] in self?.panel?.close() },
                                   onConvert: { [weak self] format in
            self?.panel?.close()
            ConversionRunner.run(urls: urls, format: format)
        })
        let panel = PanelKit.make(title: "Totori · 更多格式", size: NSSize(width: 450, height: 280), content: view)
        panel.identifier = NSUserInterfaceItemIdentifier("totori.moreFormats")
        self.panel = panel
        PanelKit.present(panel)
    }
}

private struct MoreFormatsView: View {
    let urls: [URL]
    let formats: [OutputFormat]
    let onCancel: () -> Void
    let onConvert: (OutputFormat) -> Void
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("为 \(urls.count) 个文件选择输出格式").font(.system(size: 15, weight: .semibold))
            Text(urls.first?.lastPathComponent ?? "").lineLimit(1).truncationMode(.middle)
                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            Picker("输出格式", selection: $selectedIndex) {
                ForEach(Array(formats.enumerated()), id: \.element.id) { index, format in Text(format.name).tag(index) }
            }.accessibilityIdentifier("moreFormats.format")
            ConversionImpactLabel(urls: urls, format: formats[selectedIndex])
            Text("保存到原文件所在文件夹，同名自动避让")
                .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("moreFormats.cancel")
                Spacer()
                Button("转换 \(urls.count) 个文件") { onConvert(formats[selectedIndex]) }
                    .buttonStyle(BrandPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("moreFormats.convert")
            }
        }.padding(20).frame(width: 450, height: 280).background(Palette.canvas).tint(Palette.brand)
    }
}
