import AppKit
import SwiftUI

/// 独立的轻量结果入口；窗口关闭后，记录仍由本次进程的有界 store 持有。
@MainActor
final class RecentTasksWindow {
    static let shared = RecentTasksWindow()
    private var panel: NSPanel?

    /// 窗口重复打开复用同一批内存记录，不扫描用户目录或恢复上次运行的历史。
    func present() {
        panel?.orderOut(nil)
        let panel = PanelKit.make(title: "Totori · 最近任务", size: NSSize(width: 760, height: 560),
                                  content: RecentTasksView(store: .shared))
        panel.identifier = NSUserInterfaceItemIdentifier("totori.recentTasks")
        self.panel = panel
        PanelKit.present(panel)
    }
}

private struct RecentTasksView: View {
    @ObservedObject var store: RecentTasksStore
    @State private var selectedID: UUID?
    @AppStorage("xiaoju.theme") private var themeRaw = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }
    private var selected: RecentTaskRecord? { store.records.first { $0.id == selectedID } ?? store.records.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近任务", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("本次运行 · 最近 10 批")
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
            }
            Text("保留主窗口、花瓣转换与压缩结果；重试另记一批，退出应用后清空。")
                .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
            if store.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(Palette.brand)
                    Text("还没有最近任务").font(.system(size: 15, weight: .semibold))
                    Text("转换完成、失败或取消后，可以在这里找回结果和失败原因。")
                        .font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("recent.empty")
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.records) { record in
                                Button { selectedID = record.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(record.title).font(.system(size: Palette.TypeSize.label, weight: .semibold))
                                            .lineLimit(1)
                                        Text(record.summary).font(.system(size: Palette.TypeSize.caption)).lineLimit(2)
                                        HStack {
                                            Text(record.origin.rawValue)
                                            Spacer()
                                            Text(record.finishedAt, style: .time).monospacedDigit()
                                        }.font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: Palette.Radius.row)
                                        .fill(selected?.id == record.id ? Palette.brand.opacity(0.13) : Palette.surface))
                                    .contentShape(RoundedRectangle(cornerRadius: Palette.Radius.row))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(record.title)，\(record.summary)，\(record.origin.rawValue)")
                                .accessibilityIdentifier("recent.record.\(record.id.uuidString)")
                            }
                        }
                    }.frame(width: 218)
                    Divider()
                    if let selected { RecentTaskDetail(record: selected).id(selected.id) }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Palette.textPrimary).tint(Palette.brand).background(Palette.canvas)
    }
}

private struct RecentTaskDetail: View {
    let record: RecentTaskRecord
    @State private var available: Set<URL> = []
    @State private var checked = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.system(size: 14, weight: .semibold))
                    Text(record.summary).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if !record.outputs.isEmpty {
                    Button("定位输出") { reveal(record.outputs) }
                        .controlSize(.small).accessibilityIdentifier("recent.revealAll")
                }
            }
            if let notice {
                Text(notice).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.danger)
                    .textSelection(.enabled).accessibilityIdentifier("recent.notice")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(record.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.source.lastPathComponent).font(.system(size: Palette.TypeSize.label, weight: .medium))
                                .textSelection(.enabled).help(item.source.path)
                            if let output = item.output {
                                Text("→ \(output.lastPathComponent)").font(.system(size: Palette.TypeSize.caption))
                                    .textSelection(.enabled).help(output.path)
                                FileSummaryLabel(url: output)
                                HStack(spacing: 10) {
                                    Button("在访达显示") { reveal([output]) }
                                        .accessibilityIdentifier("recent.reveal.\(item.id.uuidString)")
                                    Button("对比结果") { compare(output) }
                                        .disabled(!checked)
                                        .help("点击时重新检查文件；移回原路径后可再次打开对比")
                                        .accessibilityIdentifier("recent.compare.\(item.id.uuidString)")
                                }.controlSize(.small)
                                if checked && !available.contains(output) {
                                    Text("输出文件已移动、删除或无法读取").font(.system(size: Palette.TypeSize.caption))
                                        .foregroundStyle(Palette.danger)
                                } else if checked && !available.contains(item.source) {
                                    Text("原文件不可用，仍可定位输出").font(.system(size: Palette.TypeSize.caption))
                                        .foregroundStyle(Palette.textSecondary)
                                }
                            } else if let error = item.error {
                                Text(error).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.danger)
                                    .textSelection(.enabled)
                            } else if item.cancelled {
                                Text("已取消，未生成输出").font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                            } else if item.keptOriginal {
                                Text("压缩未减小体积，原文件保留").font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    if let detail = record.detail, !detail.isEmpty {
                        Text(detail).font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            let urls = Set(record.items.map(\.source) + record.outputs)
            let task = Task.detached(priority: .userInitiated) {
                Set(urls.filter { !Task.isCancelled && Self.readable($0) })
            }
            let values = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled else { return }
            available = values
            checked = true
        }
    }

    /// 用户可能在窗口打开后移动文件；在动作发生前复核路径，避免发出无反馈的打开请求。
    private func reveal(_ urls: [URL]) {
        let found = urls.filter(Self.readable)
        let missing = urls.count - found.count
        notice = missing == 0 ? nil : "\(missing) 个输出文件已移动、删除或无法读取。"
        if !found.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(found) }
    }

    /// 使用结果快照中的原件对应关系，混合格式由公共对比入口选择图片批次或单对回退。
    private func compare(_ output: URL) {
        guard let pair = record.comparisons.first(where: { $0.output == output }) else { return }
        for url in [pair.source, pair.output] {
            if Self.readable(url) { available.insert(url) } else { available.remove(url) }
        }
        guard available.contains(pair.source), available.contains(pair.output) else {
            notice = "原文件或输出文件已移动、删除或无法读取。"
            return
        }
        notice = nil
        ComparisonWindow.shared.present(pairs: record.comparisons, selectedOutput: output)
    }

    /// 只判断具体结果文件，不枚举目录；目录或不可读路径不能作为有效对比文件。
    nonisolated private static func readable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }
}
