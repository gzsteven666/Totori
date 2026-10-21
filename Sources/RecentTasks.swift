import Foundation
import Combine

/// 最近任务只保存本次运行的路径和结果文字，不保存图片、重试闭包或磁盘历史。
struct RecentTaskItem: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    var output: URL? = nil
    var error: String? = nil
    var cancelled = false
    var keptOriginal = false

    /// 使用执行完成时的结果快照，清空主列表不会影响历史中的源文件对应关系。
    init(result: ConversionResult) {
        source = result.source
        output = result.output
        error = result.error
        cancelled = result.cancelled
    }

    /// 花瓣工作队列也使用同一种结果表示，保留压缩无收益时的正常结束状态。
    init(source: URL, output: URL? = nil, error: String? = nil,
         cancelled: Bool = false, keptOriginal: Bool = false) {
        self.source = source
        self.output = output
        self.error = error
        self.cancelled = cancelled
        self.keptOriginal = keptOriginal
    }
}

struct RecentTaskRecord: Identifiable, Sendable {
    enum Origin: String, Sendable {
        case mainWindow = "主窗口", petals = "格式花瓣", compression = "压缩工具"
    }

    let id = UUID()
    let finishedAt = Date()
    let title: String
    let origin: Origin
    let items: [RecentTaskItem]
    var detail: String? = nil

    var outputs: [URL] { items.compactMap(\.output) }
    var comparisons: [OutputComparison] {
        items.compactMap { item in item.output.map { OutputComparison(source: item.source, output: $0) } }
    }
    var failedCount: Int { items.filter { $0.error != nil && !$0.cancelled && $0.output == nil }.count }
    var cancelledCount: Int { items.filter(\.cancelled).count }

    /// 无收益压缩与失败分开说明，避免把保留原件显示为失败或生成了新文件。
    var summary: String {
        var parts: [String] = []
        if !outputs.isEmpty { parts.append("成功 \(outputs.count) 个") }
        let retained = items.filter(\.keptOriginal).count
        if retained > 0 { parts.append("保留原文件 \(retained) 个") }
        if failedCount > 0 { parts.append("失败 \(failedCount) 个") }
        if cancelledCount > 0 { parts.append("已取消 \(cancelledCount) 个") }
        return parts.isEmpty ? "已结束" : parts.joined(separator: " · ")
    }
}

/// 主窗口与花瓣在主线程写入同一个有界列表；每次执行（含重试）各占一条。
@MainActor
final class RecentTasksStore: ObservableObject {
    static let shared = RecentTasksStore()
    static let capacity = 10
    @Published private(set) var records: [RecentTaskRecord] = []

    /// 新结果排在最前；重复提交同一快照替换原条目，不占用两次名额。
    func record(_ record: RecentTaskRecord) {
        guard !record.items.isEmpty else { return }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records = Array(records.prefix(Self.capacity))
    }
}
