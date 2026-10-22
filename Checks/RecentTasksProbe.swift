import AppKit
import ImageIO

/// 使用隔离临时文件验证真实转换、重试和取消的记录，不读取或改动用户文件。
@MainActor
enum RecentTasksProbe {
    static func run() -> Int32 {
        _ = NSApplication.shared
        var failures = 0
        var passed = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        /// 主线程让出运行循环，直到后台任务收尾；超时视为失败，不无限等待。
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("totori-recent-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let data = bitmap.representation(using: .png, properties: [:]),
                  let jpeg = FormatCatalog.images.first(where: { $0.ext == "jpg" }) else {
                expect(false, "创建图片夹具"); return 1
            }
            let good = directory.appendingPathComponent("成功.png")
            let bad = directory.appendingPathComponent("待修复.png")
            try data.write(to: good)
            try Data("invalid png fixture".utf8).write(to: bad)

            // 容量、顺序、值快照：覆盖失败、取消、无收益压缩三种非普通成功状态。
            let store = RecentTasksStore()
            for index in 0..<12 {
                store.record(RecentTaskRecord(title: "批次\(index)", origin: .mainWindow,
                                              items: [RecentTaskItem(source: good, cancelled: true)]))
            }
            expect(store.records.count == 10 && store.records.first?.title == "批次11"
                   && store.records.last?.title == "批次2", "只保留最近10批并按结束顺序排列")
            if let first = store.records.first {
                store.record(first)
                expect(store.records.count == 10 && store.records.filter { $0.id == first.id }.count == 1,
                       "相同快照不会重复占位")
            }
            store.record(RecentTaskRecord(title: "空批次", origin: .petals, items: []))
            expect(store.records.first?.title != "空批次", "空请求不产生任务记录")
            expect(RecentTasksStore().records.isEmpty, "新会话store不读取磁盘历史")
            let retained = RecentTaskRecord(title: "压缩", origin: .compression,
                                            items: [RecentTaskItem(source: good, keptOriginal: true)])
            expect(retained.outputs.isEmpty && retained.failedCount == 0
                   && retained.summary.contains("保留原文件 1"), "无收益压缩说明原件保留而非失败")

            // 真实主窗口转换：同一批中一成功一失败，错误与源输出对应关系完整保留。
            let model = AppModel()
            model.add(urls: [good, bad]); model.selectedFormat = jpeg
            let beforeCount = RecentTasksStore.shared.records.count
            model.convertAll()
            expect(wait { !model.isConverting }, "主窗口真实转换结束")
            guard let mixed = RecentTasksStore.shared.records.first else {
                expect(false, "主窗口写入最近任务"); return 1
            }
            expect(RecentTasksStore.shared.records.count == beforeCount + 1,
                   "一次执行产生一条记录")
            expect(mixed.origin == .mainWindow && mixed.items.map(\.source) == [good, bad]
                   && mixed.outputs.count == 1 && mixed.failedCount == 1,
                   "部分失败保留输入顺序、成功输出和失败数量")
            expect(mixed.items.last?.error?.isEmpty == false && mixed.comparisons.first?.source == good,
                   "失败原因和原件输出关系可追溯")
            if let output = mixed.outputs.first {
                let decoded = CGImageSourceCreateWithURL(output as CFURL, nil)
                expect(decoded != nil, "历史输出是真实可解码JPEG")
            } else { expect(false, "存在成功输出") }

            // 修复输入再重试，前一批仍保留当时的失败快照，不重复转换成功原件。
            try data.write(to: bad)
            model.retryFailed()
            expect(wait { !model.isConverting }, "失败重试结束")
            let retry = RecentTasksStore.shared.records.first
            expect(retry?.items.count == 1 && retry?.items.first?.source == bad
                   && retry?.outputs.count == 1 && retry?.failedCount == 0,
                   "重试另记一批且只包含本次执行的失败项")
            expect(RecentTasksStore.shared.records.contains { $0.id == mixed.id && $0.failedCount == 1 },
                   "重试成功不改写前一次失败快照")
            model.clear()
            expect(model.results.isEmpty && RecentTasksStore.shared.records.contains { $0.id == mixed.id },
                   "清空主列表仍能找回旧输出")
            expect(mixed.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                   "主列表清空不会删除历史输出文件")

            // 在工作开始前取消，仍产生可说明原因的结束记录，不把取消算作失败。
            model.add(urls: [good, bad]); model.selectedFormat = jpeg
            model.convertAll(); model.cancelConversion()
            expect(wait { !model.isConverting }, "取消批次结束")
            let stopped = RecentTasksStore.shared.records.first
            expect(stopped?.items.count == 2 && stopped?.cancelledCount == 2
                   && stopped?.failedCount == 0 && stopped?.outputs.isEmpty == true,
                   "取消批次保留全部未完成项且不误报失败或输出")
            expect(try Data(contentsOf: good) == data && Data(contentsOf: bad) == data,
                   "转换、重试和取消不改写源图片")

            // 花瓣入口确实写入公共store，关闭完成窗口之后仍可从同一快照恢复。
            let wheelGood = directory.appendingPathComponent("花瓣成功.png")
            let wheelBad = directory.appendingPathComponent("花瓣失败.png")
            try data.write(to: wheelGood); try Data("broken".utf8).write(to: wheelBad)
            let previousID = RecentTasksStore.shared.records.first?.id
            ConversionRunner.run(urls: [wheelGood, wheelBad], format: jpeg)
            expect(wait { RecentTasksStore.shared.records.first?.id != previousID }, "花瓣队列写入最近任务")
            let wheel = RecentTasksStore.shared.records.first
            expect(wheel?.origin == .petals && wheel?.outputs.count == 1 && wheel?.failedCount == 1
                   && wheel?.items.map(\.source) == [wheelGood, wheelBad],
                   "花瓣成功输出与失败原因完整写入同一记录")
            for window in NSApp.windows where window.identifier?.rawValue == "totori.completion" { window.close() }
            expect(RecentTasksStore.shared.records.first?.id == wheel?.id && wheel?.comparisons.count == 1,
                   "完成窗口关闭后仍保留批次与对比对应关系")
        } catch {
            expect(false, "夹具或转换错误：\(error.localizedDescription)")
        }
        print("RESULT \(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
