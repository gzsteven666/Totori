import AppKit
import ImageIO
import PDFKit
import CryptoKit

/// 本轮功能的独立回归：使用合成文件检查结果语义，不向真实用户文件写入测试数据。
enum IterationProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let status = await execute()
            exit(status)
        }
        app.run()
        return 0
    }

    @MainActor
    private static func execute() async -> Int32 {
        var passed = 0, failed = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let root = ProbeFixtures.work
        let originals = ProbeFixtures.inputs
        let folder = root.appendingPathComponent("probe-\(getpid())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = originals.appendingPathComponent("01-森林样本.png")
            let originalHash = try digest(png)
            let image = await FileMetadataReader.read(png)
            expect(image.pixelWidth == 1200 && image.pixelHeight == 800 && image.byteCount == (try? FileManager.default.attributesOfItem(atPath: png.path)[.size] as? NSNumber)?.int64Value, "图片简介包含真实像素与字节")
            let rotated = await FileMetadataReader.read(originals.appendingPathComponent("08-方向6.jpg"))
            expect(rotated.pixelWidth == 800 && rotated.pixelHeight == 1200, "EXIF方向6交换显示宽高")
            let video = await FileMetadataReader.read(originals.appendingPathComponent("07-视频样本.mp4"))
            expect(video.pixelWidth == 640 && video.pixelHeight == 360 && abs((video.duration ?? 0) - 3) < 0.15, "视频简介包含分辨率与时长")
            let webm = await FileMetadataReader.read(originals.appendingPathComponent("11-视频样本.webm"))
            expect(webm.pixelWidth == 640 && webm.pixelHeight == 360 && abs((webm.duration ?? 0) - 3) < 0.15, "WebM简介回退读取")
            let audio = await FileMetadataReader.read(originals.appendingPathComponent("09-音频样本.mp3"))
            expect(audio.duration != nil && audio.pixelWidth == nil && audio.isAudio, "音频显示时长且没有伪分辨率")
            let missing = await FileMetadataReader.read(folder.appendingPathComponent("不存在.png"))
            expect(missing.byteCount == nil && missing.pixelWidth == nil && !missing.isReadable, "缺失文件不编造0字节或分辨率")
            let malformed = await FileMetadataReader.read(originals.appendingPathComponent("04-损坏.png"))
            expect(malformed.pixelWidth == nil && malformed.byteCount == 14, "损坏图片仅显示可核实的体积")
            let archive = await FileMetadataReader.read(originals.appendingPathComponent("06-归档.tar"))
            expect(archive.byteCount != nil && archive.pixelWidth == nil && archive.duration == nil, "压缩包只读格式与体积，不解包")

            let mutable = folder.appendingPathComponent("可覆盖.png")
            try FileManager.default.copyItem(at: png, to: mutable)
            _ = await FileMetadataReader.read(mutable)
            try makePNG(width: 64, height: 32, url: mutable)
            let refreshed = await FileMetadataReader.read(mutable)
            expect(refreshed.pixelWidth == 64 && refreshed.pixelHeight == 32, "原地覆盖后简介缓存刷新")
            let pdf = PDFDocument()
            if let pageImage = NSImage(contentsOf: png) {
                for _ in 0..<2 { if let page = PDFPage(image: pageImage) { pdf.insert(page, at: pdf.pageCount) } }
            }
            let pdfURL = folder.appendingPathComponent("两页.pdf")
            expect(pdf.write(to: pdfURL), "生成合成PDF")
            let pdfMetadata = await FileMetadataReader.read(pdfURL)
            expect(pdfMetadata.pageCount == 2 && pdfMetadata.byteCount != nil, "PDF简介显示页数与大小")

            let input = folder.appendingPathComponent("retry-input", isDirectory: true)
            let output = folder.appendingPathComponent("retry-output", isDirectory: true)
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            let good = input.appendingPathComponent("正常.png"), broken = input.appendingPathComponent("待修复.png")
            try FileManager.default.copyItem(at: png, to: good)
            try Data("invalid".utf8).write(to: broken)
            let model = AppModel()
            model.add(urls: [good, broken])
            model.selectedFormat = FormatCatalog.images.first { $0.ext == "jpg" }
            model.useSourceFolder = false
            model.outputDirectory = output
            model.convertAll()
            try await wait(model)
            expect(model.results.filter(\.ok).count == 1 && model.failedCount == 1, "批次中部分失败仍保留成功结果")
            let firstOutput = model.results.first(where: \.ok)?.output
            let firstHash = try firstOutput.map(digest)
            try Data(contentsOf: png).write(to: broken)
            model.selectedFormat = FormatCatalog.images.first { $0.ext == "png" }
            model.retryFailed()
            try await wait(model)
            expect(model.results.count == 2 && model.results.allSatisfy(\.ok), "修复输入后只重试失败项")
            expect(model.results.allSatisfy { $0.output?.pathExtension == "jpg" }, "重试沿用原批格式，不受当前选择变化影响")
            let generated = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            expect(generated.count == 2 && firstOutput.map { try? digest($0) } == firstHash, "重试不重复生成或改变已成功文件")

            let cancelInput = folder.appendingPathComponent("cancel-input", isDirectory: true)
            let cancelOutput = folder.appendingPathComponent("cancel-output", isDirectory: true)
            try FileManager.default.createDirectory(at: cancelInput, withIntermediateDirectories: true)
            var batch: [URL] = []
            for i in 0..<24 {
                let url = cancelInput.appendingPathComponent("样本\(i).png")
                try FileManager.default.copyItem(at: png, to: url)
                batch.append(url)
            }
            let cancelModel = AppModel()
            cancelModel.add(urls: batch)
            cancelModel.selectedFormat = FormatCatalog.images.first { $0.ext == "png" }
            cancelModel.useSourceFolder = false
            cancelModel.outputDirectory = cancelOutput
            cancelModel.convertAll()
            let limit = Date().addingTimeInterval(8)
            while cancelModel.results.filter(\.ok).isEmpty && cancelModel.isConverting && Date() < limit {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            cancelModel.cancelConversion()
            try await wait(cancelModel)
            let preserved = cancelModel.results.filter(\.ok).compactMap(\.output)
            expect(!preserved.isEmpty && cancelModel.cancelledCount > 0, "取消批次保留已完成项，剩余标记已取消")
            expect(cancelModel.failedCount == 0 && cancelModel.results.count == batch.count, "取消与失败分开统计")
            let preservedHashes = try Dictionary(uniqueKeysWithValues: preserved.map { ($0, try digest($0)) })
            expect((try FileManager.default.contentsOfDirectory(atPath: cancelOutput.path)).allSatisfy { !$0.hasPrefix(".totori-output-") }, "取消没有半成品或暂存目录残留")
            cancelModel.resumeUnfinished()
            try await wait(cancelModel)
            expect(cancelModel.results.count == 24 && cancelModel.results.allSatisfy(\.ok), "取消后继续仅转换未完成项")
            expect((try FileManager.default.contentsOfDirectory(atPath: cancelOutput.path)).count == 24, "继续不会重复生成已完成输出")
            expect(preservedHashes.allSatisfy { (try? digest($0.key)) == $0.value }, "继续后原成功结果保持不变")

            let canvas = ShelfCanvas(frame: NSRect(x: 0, y: 0, width: 268, height: 420))
            canvas.add([good, broken, mutable])
            canvas.selection = [0, 1]
            canvas.finishDrag(urls: [good, broken], operation: .copy, returnedToShelf: false)
            expect(canvas.canUndo && canvas.files == [mutable], "成功拖出记录撤销步骤")
            canvas.add([pdfURL])
            canvas.undo()
            expect(canvas.files == [good, broken, mutable, pdfURL], "撤销恢复顺序并保留后来加入项")
            expect(canvas.selection == [0, 1], "撤销恢复拖出选择")
            canvas.clear()
            expect(canvas.files.isEmpty && canvas.canUndo, "清空暂存支持撤销")
            canvas.undo()
            expect(canvas.files == [good, broken, mutable, pdfURL], "撤销清空恢复条目")
            expect(canvas.selection == [0, 1], "撤销清空只恢复原选择，不全选恢复项")
            canvas.selection = []
            canvas.clear()
            canvas.undo()
            expect(canvas.files == [good, broken, mutable, pdfURL] && canvas.selection.isEmpty,
                   "无选择时清空再撤销仍保持无选择")
            canvas.selection = [0, 2]
            let originalCount = canvas.files.count
            canvas.finishDrag(urls: [good], operation: [], returnedToShelf: false)
            expect(canvas.files.count == originalCount, "取消拖动不移除条目")
            canvas.clear()
            let moved = input.appendingPathComponent("暂存改名.png")
            try FileManager.default.moveItem(at: good, to: moved)
            canvas.undo()
            expect(!canvas.files.contains(good) && canvas.files.count == 3, "撤销过滤已不存在的原路径")
            try FileManager.default.moveItem(at: moved, to: good)
            // 位置验证只操作本探针进程拥有的窗口；测试结束恢复原偏好。
            let defaults = UserDefaults.standard
            let previousOrigin = defaults.object(forKey: "totori.shelfOrigin")
            let previousPin = defaults.object(forKey: "totori.shelfPinned")
            defer {
                FileShelf.shared.hide()
                if let previousOrigin { defaults.set(previousOrigin, forKey: "totori.shelfOrigin") }
                else { defaults.removeObject(forKey: "totori.shelfOrigin") }
                if let previousPin { defaults.set(previousPin, forKey: "totori.shelfPinned") }
                else { defaults.removeObject(forKey: "totori.shelfPinned") }
            }
            defaults.set(false, forKey: "totori.shelfPinned")
            FileShelf.shared.reloadPinFromDefaults()
            FileShelf.shared.show()
            if let panel = FileShelf.shared.debugCanvas?.window, let visible = NSScreen.main?.visibleFrame {
                if let shelf = FileShelf.shared.debugCanvas,
                   let undoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                  characters: "z", charactersIgnoringModifiers: "z",
                                                  isARepeat: false, keyCode: 6) {
                    shelf.add([good, broken])
                    shelf.selection = [0]
                    shelf.clear()
                    panel.makeFirstResponder(nil)
                    if let redoKey = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                      modifierFlags: [.command, .shift], timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil,
                                                      characters: "Z", charactersIgnoringModifiers: "z",
                                                      isARepeat: false, keyCode: 6) {
                        _ = panel.performKeyEquivalent(with: redoKey)
                        expect(shelf.files.isEmpty && shelf.canUndo, "CmdShiftZ不会被当作CmdZ额外撤销")
                    }
                    let handled = panel.performKeyEquivalent(with: undoKey)
                    expect(handled && shelf.files == [good, broken] && shelf.selection == [0],
                           "浮窗焦点离开文件格后窗口仍处理CmdZ且恢复原选择")
                } else { expect(false, "窗口快捷键测试具备文件画布与事件") }
                let target = NSPoint(x: visible.minX + 150, y: visible.midY - 180)
                panel.setFrameOrigin(target)
                FileShelf.shared.rememberOrigin()
                FileShelf.shared.hide()
                FileShelf.shared.show()
                expect(hypot(FileShelf.shared.debugFrame.minX - target.x, FileShelf.shared.debugFrame.minY - target.y) < 1, "浮窗关闭重开保持位置")
                let savedOrigin = defaults.array(forKey: "totori.shelfOrigin") as? [Double]
                FileShelf.shared.collapse(to: .left)
                try await Task.sleep(nanoseconds: 350_000_000)
                expect((defaults.array(forKey: "totori.shelfOrigin") as? [Double]) == savedOrigin, "收起边条不覆盖展开位置")
                FileShelf.shared.expand()
                try await Task.sleep(nanoseconds: 350_000_000)
                defaults.set([9e9, -9e9], forKey: "totori.shelfOrigin")
                FileShelf.shared.debugRestoreOrigin()
                let frame = FileShelf.shared.debugFrame
                expect(NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame) }, "屏幕外位置恢复到可见范围")
            } else { expect(false, "浮窗位置测试具备窗口与屏幕") }
            expect(try digest(png) == originalHash, "合成源图未被修改")
            expect([good, broken, mutable, pdfURL].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "浮窗撤销不会操作磁盘原文件")
        } catch {
            failed += 1
            print("FAIL exception: \(error)")
        }
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    @MainActor
    private static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.isConverting, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if model.isConverting { model.cancelConversion(); throw ConversionError.failed("批次验收超时") }
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makePNG(width: Int, height: Int, url: URL) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.failed("测试PNG创建失败")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("测试PNG写出失败") }
    }
}
