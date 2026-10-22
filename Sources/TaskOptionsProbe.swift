import AppKit
import ImageIO

/// 用合成副本验证真实写出范围、任务质量快照和取消/重试，不操作用户原文件或全局偏好。
@MainActor
enum TaskOptionsProbe {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in exit(await execute()) }
        app.run()
        return 0
    }

    private static func execute() async -> Int32 {
        var passed = 0, failed = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let fm = FileManager.default
        let root = ProbeFixtures.work.appendingPathComponent("task-probe-\(getpid())", isDirectory: true)
        let fixture = ProbeFixtures.inputs.appendingPathComponent("01-旅行照片-家庭合影-精选修订版.png")
        let previous = UserDefaults.standard.string(forKey: "xiaoju.convertQuality")
        do {
            let bytes = try Data(contentsOf: fixture)
            let input = root.appendingPathComponent("input")
            try fm.createDirectory(at: input, withIntermediateDirectories: true)
            let urls = try (1...4).map { number -> URL in
                let url = input.appendingPathComponent("范围\(number).png")
                try bytes.write(to: url)
                return url
            }
            let jpeg = FormatCatalog.images.first { $0.ext == "jpg" }!
            func model(_ directory: String) -> AppModel {
                let value = AppModel()
                value.add(urls: urls)
                value.selectedFormat = jpeg
                value.useSourceFolder = false
                value.outputDirectory = root.appendingPathComponent(directory)
                return value
            }
            let selected = model("selected")
            selected.convertSelected(ids: [])
            expect(!selected.isConverting && selected.results.isEmpty, "空选择不回退为转换全部")
            selected.convertSelected(ids: [UUID()])
            expect(!selected.isConverting, "失效选择ID不触发转换")
            selected.taskQuality = .smaller
            let chosen = selected.files[1]
            selected.convertSelected(ids: [chosen.id])
            selected.taskQuality = .quality
            try await wait(selected)
            expect(selected.results.count == 1 && selected.results.first?.source == chosen.url && selected.results.first?.ok == true,
                   "选择四个中的一个时只处理这个文件")
            expect(selected.pendingInputCount == 3 && selected.primaryAction == .newBatch,
                   "所选转换后其他文件保留待转换状态")
            let actual = selected.results[0].output!
            expect((try fm.contentsOfDirectory(atPath: selected.outputDirectory.path)).count == 1,
                   "所选转换仅写出一个文件")
            let expected = try Engine.convert(source: chosen.url, format: jpeg, to: root.appendingPathComponent("expected"), options: TaskConversionQuality.smaller.options) { _ in }
            expect(try Data(contentsOf: actual) == Data(contentsOf: expected),
                   "开始后改变质量不会更改已经固定的批次参数")
            let size = Int64(try actual.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
            let summary = ConversionOutputSummary(sourceExtension: "png", outputExtension: "jpg", sourceBytes: Int64(bytes.count), outputBytes: size)
            expect(selected.results[0].outputSummary?.text == summary.text,
                   "结果摘要使用实际写出的字节数")
            let image = CGImageSourceCreateWithURL(actual as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
            expect(properties[kCGImagePropertyPixelWidth] as? Int == 2400 && properties[kCGImagePropertyPixelHeight] as? Int == 1600,
                   "最小体积质量不缩小普通转换图片尺寸")
            selected.convertAll()
            try await wait(selected)
            expect(selected.results.count == 4 && selected.results.allSatisfy(\.ok), "显式转换全部处理四个文件")
            expect((try fm.contentsOfDirectory(atPath: selected.outputDirectory.path)).count == 5,
                   "再次全部转换避让已有输出，不覆盖所选结果")

            let broken = urls[0]
            try Data("broken".utf8).write(to: broken)
            let retry = model("retry")
            retry.taskQuality = .smaller
            retry.convertSelected(ids: [retry.files[0].id, retry.files[1].id])
            try await wait(retry)
            expect(retry.failedCount == 1 && retry.primaryAction == .retry && retry.pendingInputCount == 2,
                   "部分选择有失败时优先重试，不被未选文件抢占主操作")
            let goodOutput = retry.results.first(where: \.ok)!.output!
            let goodBytes = try Data(contentsOf: goodOutput)
            try bytes.write(to: broken)
            retry.selectedFormat = FormatCatalog.images.first { $0.ext == "png" }
            retry.taskQuality = .quality
            retry.outputDirectory = root.appendingPathComponent("should-not-be-used")
            retry.retryFailed()
            try await wait(retry)
            let recovered = retry.results.first { $0.source == broken }!.output!
            let expectedRetry = try Engine.convert(source: broken, format: jpeg, to: root.appendingPathComponent("expected-retry"), options: TaskConversionQuality.smaller.options) { _ in }
            expect(retry.results.count == 2 && retry.results.allSatisfy(\.ok) && recovered.pathExtension == "jpg" && recovered.deletingLastPathComponent().lastPathComponent == "retry",
                   "重试保持原选择范围、格式和目录")
            expect(try Data(contentsOf: recovered) == Data(contentsOf: expectedRetry), "重试沿用最初质量而非当前质量")
            expect(retry.results.first { $0.source == broken }?.outputSummary?.sourceBytes == Int64(bytes.count),
                   "失败文件修复后摘要刷新为实际源大小")
            expect(try Data(contentsOf: goodOutput) == goodBytes && fm.contentsOfDirectory(atPath: root.appendingPathComponent("retry").path).count == 2,
                   "重试保留成功输出且不重复生成")

            let cancelled = model("cancel")
            let ids = Set(cancelled.files.prefix(3).map(\.id))
            cancelled.convertSelected(ids: ids)
            cancelled.cancelConversion()
            try await wait(cancelled)
            expect(cancelled.cancelledCount > 0 && cancelled.failedCount == 0 && cancelled.primaryAction == .resume,
                   "所选转换取消后优先继续未完成")
            cancelled.resumeUnfinished()
            try await wait(cancelled)
            expect(cancelled.results.count == 3 && cancelled.results.allSatisfy(\.ok) && cancelled.pendingInputCount == 1,
                   "取消后继续仍只处理原选择，不扩大到未选文件")
            expect(TaskConversionQuality.allCases.allSatisfy { $0.options.maxSide == nil }, "所有本次质量档位都不缩图")
            expect(jpeg.supportsTaskQuality && !FormatCatalog.images[0].supportsTaskQuality && !FormatCatalog.medias.first { $0.ext == "wav" }!.supportsTaskQuality,
                   "质量入口仅出现在后端支持的格式")
            cancelled.taskQuality = .smaller
            cancelled.clear()
            expect(cancelled.taskQuality == .defaults, "清空批次恢复跟随默认质量")
            expect(UserDefaults.standard.string(forKey: "xiaoju.convertQuality") == previous, "本次质量没有改写全局默认")
            expect(try urls.allSatisfy { try Data(contentsOf: $0) == bytes }, "所有测试原件内容保留")
        } catch {
            failed += 1
            print("FAIL exception: \(error)")
        }
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    /// 运行真实异步模型并限制等待时间；超时取消，避免留下持续任务。
    private static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.isConverting && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        if model.isConverting { model.cancelConversion(); throw ConversionError.failed("任务参数验收超时") }
    }
}
