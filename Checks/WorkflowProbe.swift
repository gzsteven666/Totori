import Foundation

/// 主操作的状态回归只构造内存数据，不转换文件、不打开访达、不改偏好。
@MainActor
enum WorkflowProbe {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }

        let base = URL(fileURLWithPath: "/totori-workflow-probe", isDirectory: true)
        func file(_ name: String) -> InputFile {
            InputFile(url: base.appendingPathComponent(name + ".png"), kind: .image, size: 1024)
        }
        func success(_ input: InputFile) -> ConversionResult {
            ConversionResult(source: input.url,
                             output: base.appendingPathComponent(input.name + ".jpg"), error: nil)
        }
        func failure(_ input: InputFile) -> ConversionResult {
            ConversionResult(source: input.url, output: nil, error: "合成失败状态")
        }
        func cancelled(_ input: InputFile) -> ConversionResult {
            ConversionResult(source: input.url, output: nil, error: nil, cancelled: true)
        }

        let first = file("已完成一")
        let second = file("已完成二")
        let broken = file("待重试")
        let stopped = file("待继续")
        let added = file("新增")
        let jpeg = FormatCatalog.images.first { $0.ext == "jpg" }

        let empty = AppModel()
        expect(empty.primaryAction == .start && !empty.primaryActionEnabled,
               "空列表显示开始转换并禁用主操作")
        expect(empty.pendingInputCount == 0 && empty.unfinishedCount == 0,
               "空列表没有待处理或未完成数量")

        let initial = AppModel()
        initial.files = [first, second]
        initial.selectedFormat = jpeg
        expect(initial.primaryAction == .start && initial.primaryActionEnabled,
               "首次导入显示开始转换而非新批次")
        expect(initial.pendingInputCount == 2, "首次导入的全部文件均为待处理输入")
        initial.selectedFormat = nil
        expect(!initial.primaryActionEnabled, "首次转换缺少目标格式时禁用")

        let running = AppModel()
        running.files = [first, second]
        running.results = [success(first)]
        running.jobStates = [first.url: .succeeded, second.url: .running]
        running.selectedFormat = jpeg
        running.isConverting = true
        running.progress = 0.375
        running.statusText = "合成运行状态"
        let runningResultIDs = running.results.map(\.id)
        let runningFileIDs = running.files.map(\.id)
        let runningJobStates = running.jobStates
        expect(running.primaryAction == .working && !running.primaryActionEnabled,
               "处理中主操作禁用")
        running.performPrimaryAction()
        expect(running.isConverting && running.progress == 0.375 &&
               running.statusText == "合成运行状态" && running.results.map(\.id) == runningResultIDs &&
               running.files.map(\.id) == runningFileIDs && running.jobStates == runningJobStates,
               "处理中重复执行主操作不改当前运行状态或结果")
        running.cancelRequested = true
        expect(running.primaryAction == .working && !running.primaryActionEnabled,
               "正在取消期间仍禁用主操作")
        running.performPrimaryAction()
        expect(running.isConverting && running.cancelRequested &&
               running.results.map(\.id) == runningResultIDs && running.progress == 0.375,
               "正在取消时重复主操作不启动新批次")

        let failedBatch = AppModel()
        failedBatch.files = [first, broken]
        failedBatch.results = [success(first), failure(broken)]
        failedBatch.jobStates = [first.url: .succeeded, broken.url: .failed]
        failedBatch.selectedFormat = nil
        expect(failedBatch.primaryAction == .retry && failedBatch.primaryActionEnabled,
               "部分失败优先重试且不依赖当前目标格式")
        expect(failedBatch.failedCount == 1 && failedBatch.unfinishedCount == 1 &&
               failedBatch.pendingInputCount == 0,
               "失败计入未完成而不误算为新增输入")
        expect(failedBatch.primaryActionTitle.contains("重试") &&
               failedBatch.primaryActionTitle.contains("1"),
               "重试主按钮说明动作及失败数量")

        let interrupted = AppModel()
        interrupted.files = [first, broken, stopped]
        interrupted.results = [success(first), failure(broken), cancelled(stopped)]
        interrupted.jobStates = [first.url: .succeeded, broken.url: .failed, stopped.url: .cancelled]
        interrupted.selectedFormat = nil
        expect(interrupted.primaryAction == .resume && interrupted.primaryActionEnabled,
               "失败与取消并存时继续未完成且不依赖当前格式")
        expect(interrupted.failedCount == 1 && interrupted.cancelledCount == 1 &&
               interrupted.unfinishedCount == 2 && interrupted.pendingInputCount == 0,
               "继续数量包含失败和取消且不重复统计")
        expect(interrupted.primaryActionTitle.contains("继续") &&
               interrupted.primaryActionTitle.contains("2"),
               "继续主按钮显示全部未完成数量")

        let completed = AppModel()
        completed.files = [first, second]
        completed.results = [success(first), success(second)]
        completed.jobStates = [first.url: .succeeded, second.url: .succeeded]
        completed.selectedFormat = nil
        expect(completed.primaryAction == .reveal && completed.primaryActionEnabled,
               "全部成功后查看结果且不依赖当前目标格式")
        expect(completed.unfinishedCount == 0 && completed.pendingInputCount == 0,
               "已完成批次没有未完成或新增输入")

        completed.files.append(added)
        completed.selectedFormat = jpeg
        expect(completed.primaryAction == .newBatch && completed.primaryActionEnabled,
               "成功批次新增文件后主按钮转换新批次而非仅看旧结果")
        expect(completed.pendingInputCount == 1 && completed.files.count == 3,
               "新增数量与当前全列表数量分别保留")
        expect(completed.primaryActionTitle.contains("3"),
               "新批次主按钮显示当前列表全部三个文件")
        let newBatchNote = completed.primaryActionNote ?? ""
        expect(newBatchNote.contains("全部") && newBatchNote.contains("3"),
               "新批次说明明确将处理全部当前文件")
        completed.selectedFormat = nil
        expect(!completed.primaryActionEnabled, "新批次缺少当前目标格式时禁用")
        completed.remove(added)
        expect(completed.primaryAction == .reveal && completed.primaryActionEnabled &&
               completed.pendingInputCount == 0,
               "移除新增文件后恢复查看结果")

        interrupted.remove(broken)
        expect(interrupted.primaryAction == .resume && interrupted.unfinishedCount == 1,
               "移除失败项后只保留取消项待继续")
        interrupted.remove(stopped)
        expect(interrupted.primaryAction == .reveal && interrupted.primaryActionEnabled &&
               interrupted.unfinishedCount == 0 && interrupted.failedCount == 0 &&
               interrupted.cancelledCount == 0,
               "移除全部失败和取消项后恢复查看结果")
        interrupted.clear()
        expect(interrupted.files.isEmpty && interrupted.results.isEmpty &&
               interrupted.primaryAction == .start && !interrupted.primaryActionEnabled,
               "清空批次后回到空列表开始状态")

        let remainingNew = AppModel()
        remainingNew.files = [first, added]
        remainingNew.results = [success(first)]
        remainingNew.jobStates = [first.url: .succeeded]
        remainingNew.selectedFormat = jpeg
        remainingNew.remove(first)
        expect(remainingNew.primaryAction == .start && remainingNew.primaryActionEnabled &&
               remainingNew.pendingInputCount == 1 && remainingNew.results.isEmpty,
               "移除旧结果只剩新输入时恢复首次开始语义")

        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
