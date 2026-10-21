import Foundation

/// 主按钮只表达当前最合适的动作；恢复旧批次与重新转换整个列表保持明确区分。
enum MainTaskAction: Equatable {
    case start, newBatch, working, retry, resume, reveal
}

@MainActor
extension AppModel {
    /// 按 URL 判断尚未进入结果集的输入，添加文件后不能继续只展示旧结果。
    var pendingInputCount: Int {
        let completed = Set(results.map(\.source))
        return files.filter { !completed.contains($0.url) }.count
    }

    var unfinishedCount: Int { failedCount + cancelledCount }

    var primaryAction: MainTaskAction {
        if isConverting { return .working }
        if files.isEmpty || results.isEmpty { return .start }
        if cancelledCount > 0 { return .resume }
        if failedCount > 0 { return .retry }
        if pendingInputCount > 0 { return .newBatch }
        return results.contains(where: \.ok) ? .reveal : .start
    }

    var primaryActionTitle: String {
        switch primaryAction {
        case .start: return files.count == 1 ? "转换 1 个" : "转换全部 \(files.count) 个"
        case .newBatch: return "转换全部 \(files.count) 个"
        case .working: return cancelRequested ? "正在取消…" : "转换中…"
        case .retry: return "重试失败项（\(failedCount)）"
        case .resume: return "继续未完成（\(unfinishedCount)）"
        case .reveal: return "查看结果"
        }
    }

    /// 恢复和查看使用已有批次数据，不应被面向下一批的格式选择禁用。
    var primaryActionEnabled: Bool {
        switch primaryAction {
        case .working: return false
        case .start, .newBatch: return !files.isEmpty && selectedFormat != nil
        case .retry: return failedCount > 0
        case .resume: return unfinishedCount > 0
        case .reveal: return results.contains(where: \.ok)
        }
    }

    var primaryActionNote: String? {
        switch primaryAction {
        case .start:
            return nil
        case .newBatch:
            return "将转换列表中全部 \(files.count) 个文件，已完成项也会重新生成"
        case .retry, .resume:
            return "沿用上次的格式、质量和保存位置，保留已完成文件"
        default: return nil
        }
    }

    /// 摘要从当前列表与结果推导，增删文件不会留下旧批次的成功/失败计数。
    var taskSummary: String {
        if isConverting { return statusText }
        if files.isEmpty { return "准备好文件，就可以开始" }
        if results.isEmpty { return "已添加 \(files.count) 个文件" }
        let succeeded = results.filter(\.ok).count
        if cancelledCount > 0 { return "已取消：完成 \(succeeded) · 失败 \(failedCount) · 未完成 \(cancelledCount)" }
        if failedCount > 0 { return "处理结束：完成 \(succeeded) · 失败 \(failedCount)" }
        if pendingInputCount > 0 { return "已完成 \(succeeded) 个 · 待转换 \(pendingInputCount) 个" }
        return "已完成 \(succeeded) 个文件"
    }

    /// 工作中的重复按键没有副作用；完成态默认查看，重新转换需显式选择。
    func performPrimaryAction() {
        guard primaryActionEnabled else { return }
        switch primaryAction {
        case .start, .newBatch: convertAll()
        case .retry: retryFailed()
        case .resume: resumeUnfinished()
        case .reveal: revealLastOutput()
        case .working: break
        }
    }
}
