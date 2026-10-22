import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 不打开窗口；使用真实图片与可控制的迟到读取，检查连续对比状态。
@MainActor
enum ComparisonBatchProbe {
    static func run() async -> Int32 {
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)")
        }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("totori-comparison-batch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            func pair(_ stem: String) -> OutputComparison {
                OutputComparison(source: folder.appendingPathComponent("\(stem)-source.png"),
                                 output: folder.appendingPathComponent("\(stem)-output.png"))
            }
            let a = pair("A"), b = pair("B"), c = pair("C"), missing = pair("D")
            try writeImage(a.source, width: 128, height: 96, color: .red)
            try writeImage(a.output, width: 128, height: 96, color: .green)
            try writeImage(b.source, width: 72, height: 48, color: .blue)
            try writeImage(b.output, width: 36, height: 48, color: .yellow)
            try writeImage(c.source, width: 90, height: 60, color: .orange)
            try writeImage(c.output, width: 90, height: 60, color: .purple)
            try writeImage(missing.source, width: 64, height: 64, color: .gray)
            let originalURLs = [a.source, a.output, b.source, b.output, c.source, c.output, missing.source]
            let originals = try originalURLs.map { try Data(contentsOf: $0) }
            let pdf = OutputComparison(source: a.source, output: folder.appendingPathComponent("image.pdf"))
            let video = OutputComparison(source: folder.appendingPathComponent("video.mp4"), output: a.output)
            let normalizedDuplicate = OutputComparison(source: folder.appendingPathComponent("unused/../A-source.png"), output: a.output)
            let filtered = ComparisonBatch.imagePairs([b, pdf, a, b, video, normalizedDuplicate, c, missing])
            expect(filtered.map(\.source) == [b.source, a.source, c.source, missing.source],
                   "混合结果仅保留图片到图片，稳定去重并保持输入顺序")
            expect(!ComparisonBatch.isImagePair(pdf) && !ComparisonBatch.isImagePair(video),
                   "图片转PDF、视频转图片不混入连续图片对比")
            expect(ComparisonBatch.isImage(folder.appendingPathComponent("sample.JPEG")) &&
                   ComparisonBatch.isImage(folder.appendingPathComponent("sample.jp2")),
                   "沿用类型规则，兼容大写扩展名与ImageIO图片类型")
            expect(ComparisonBatch.imagePairs([missing]).count == 1,
                   "文件后来缺失时仍保留该图片项，允许显示原因并继续翻页")

            let pairs = [a, b, c, missing]
            let model = ComparisonModel(pairs: pairs, selectedOutput: b.output)
            expect(model.selectedIndex == 1 && model.source == b.source && model.output == b.output,
                   "根据精确结果URL初选，源与结果对应同一项")
            expect(model.positionText == "第 2 / 4 张" && model.canMovePrevious && model.canMoveNext,
                   "中间项显示位置并允许前后导航")
            let unmatched = ComparisonModel(pairs: pairs, selectedOutput: folder.appendingPathComponent("elsewhere/B-output.png"))
            expect(unmatched.selectedIndex == 0, "同名但不同路径的结果不会被误选")
            unmatched.cancel(clearBatch: true)
            model.load()
            expect(await waitUntil { !model.loading }, "初选图片读取完成")
            expect(model.sourceMetadata?.pixelWidth == 72 && model.outputMetadata?.pixelWidth == 36,
                   "初选使用自身简介与图像")
            model.previous()
            expect(await waitUntil { !model.loading }, "上一张读取完成")
            expect(!model.canMovePrevious && model.canMoveNext && model.selectedIndex == 0,
                   "第一张禁用上一张")
            let atFirst = model.debugRequestToken
            model.previous()
            expect(model.selectedIndex == 0 && model.debugRequestToken == atFirst,
                   "第一张越界操作不发起新读取")
            model.setMode(.divider)
            model.fit = false
            model.zoom = 2.25
            model.anchor = CGPoint(x: 0.63, y: 0.47)
            model.setDivider(0.31)
            model.lockOriginal = true
            model.holdOriginal = true
            let initialToken = model.debugRequestToken
            model.next()
            expect(model.loading && model.sourceBitmap == nil && model.outputBitmap == nil &&
                   model.sourceMetadata == nil && model.outputMetadata == nil,
                   "切换立即清理上一张图片和简介，避免旧内容留在新文件名下")
            expect(model.debugRequestToken != initialToken && !model.holdOriginal && model.lockOriginal,
                   "切换更新令牌，释放临时按住状态，保留锁定原图选择")
            expect(await waitUntil { !model.loading }, "不等尺寸图片读取完成")
            expect(model.mode == .sideBySide && model.preferredMode == .divider && model.dividerUnavailable,
                   "尺寸不同回退并排，保留用户分界偏好并给出说明")
            expect(!model.fit && model.zoom == 2.25 && model.anchor == CGPoint(x: 0.63, y: 0.47) && model.divider == 0.31,
                   "切换保留缩放、fit、归一化位置和分界比例")
            model.next()
            expect(await waitUntil { !model.loading }, "下一组等尺寸图片读取完成")
            expect(model.mode == .divider && !model.dividerUnavailable && model.lockOriginal,
                   "下一张可对齐时恢复分界偏好，锁定原图仍保持")
            model.setMode(.sideBySide)
            model.fit = true
            model.next()
            expect(await waitUntil { !model.loading }, "缺失结果读取能够结束")
            expect(!model.hasImagePair && model.outputMetadata?.isReadable == false && model.outputBitmap == nil,
                   "缺失图片进入可解释的fallback，旧结果不会充当当前预览")
            expect(!model.canMoveNext && model.canMovePrevious && model.positionText == "第 4 / 4 张",
                   "最后一张禁用下一张，并继续允许返回")
            let atLast = model.debugRequestToken
            model.next()
            expect(model.selectedIndex == 3 && model.debugRequestToken == atLast, "最后一张越界操作不重新读取")
            model.previous()
            expect(await waitUntil { !model.loading }, "从缺失项返回后恢复预览")
            expect(model.hasImagePair && model.mode == .sideBySide && model.preferredMode == .sideBySide && model.fit,
                   "明确改为并排与适应后，后续切换保留该选择")
            model.cancel(clearBatch: true)
            expect(model.pairs.isEmpty && model.sourceMetadata == nil && model.outputMetadata == nil &&
                   model.sourceBitmap == nil && model.outputBitmap == nil && !model.loading,
                   "关闭清理整个批次、文件简介和bitmap引用")

            let aPreview = await ComparisonPairPreview.read(a.source, a.output)
            let bPreview = await ComparisonPairPreview.read(b.source, b.output)
            let cPreview = await ComparisonPairPreview.read(c.source, c.output)
            let pending = PendingComparisonReads()
            let rapid = ComparisonModel(pairs: [a, b, c], previewLoader: { source, _ in await pending.read(source) })
            rapid.load()
            expect(await waitUntil { await pending.contains(a.source) }, "旧读取已进入可控制的等待")
            rapid.next()
            expect(await waitUntil { await pending.contains(b.source) }, "第二张读取已排队")
            rapid.next()
            expect(await waitUntil { await pending.contains(c.source) }, "第三张读取已排队")
            await pending.finish(c.source, with: cPreview)
            expect(await waitUntil { !rapid.loading }, "最新请求先完成并显示")
            expect(rapid.sourceMetadata?.url == c.source && rapid.outputMetadata?.url == c.output &&
                   rapid.sourceBitmap === cPreview.sourceImage && rapid.outputBitmap === cPreview.outputImage,
                   "最新文件的简介与两侧图像成对提交")
            await pending.finish(a.source, with: aPreview)
            await pending.finish(b.source, with: bPreview)
            try await Task.sleep(nanoseconds: 30_000_000)
            expect(rapid.selectedIndex == 2 && rapid.sourceMetadata?.url == c.source &&
                   rapid.outputMetadata?.url == c.output && rapid.sourceBitmap === cPreview.sourceImage &&
                   rapid.outputBitmap === cPreview.outputImage,
                   "快速切换时，即使旧读取忽略取消并迟到，也不能串图或串简介")
            rapid.previous()
            expect(await waitUntil { await pending.contains(b.source) }, "关闭前存在未完成读取")
            rapid.holdOriginal = true
            rapid.cancel(clearBatch: true)
            await pending.finish(b.source, with: bPreview)
            try await Task.sleep(nanoseconds: 30_000_000)
            expect(rapid.pairs.isEmpty && !rapid.loading && !rapid.holdOriginal &&
                   rapid.sourceBitmap == nil && rapid.outputBitmap == nil && rapid.sourceMetadata == nil,
                   "窗口关闭后迟到结果不会恢复图片、批次或临时原图状态")

            let large = pair("large")
            try writeImage(large.source, width: 5000, height: 80, color: .cyan)
            try writeImage(large.output, width: 5000, height: 80, color: .magenta)
            let largeModel = ComparisonModel(source: large.source, output: large.output)
            largeModel.load()
            expect(await waitUntil { !largeModel.loading }, "大图预览读取完成")
            expect(largeModel.sourceBitmap?.width == 4096 && largeModel.outputBitmap?.width == 4096 &&
                   largeModel.sourceMetadata?.pixelWidth == 5000 && largeModel.previewIsReduced,
                   "预览保持4096上限，简介和100%定位仍使用原始像素")
            largeModel.cancel(clearBatch: true)
            let text = folder.appendingPathComponent("result.txt")
            try Data("Totori".utf8).write(to: text)
            let fallback = ComparisonModel(source: text, output: text)
            fallback.load()
            expect(await waitUntil { !fallback.loading }, "单对非图片入口读取完成")
            expect(!fallback.hasImageBatch && !fallback.hasImagePair && fallback.sourceMetadata?.isReadable == true,
                   "原有单对非图片fallback保持可用，不伪装成图片批次")
            fallback.cancel(clearBatch: true)
            let after = try originalURLs.map { try Data(contentsOf: $0) }
            expect(after == originals, "全部读取、切换与对比保留原文件字节")
        } catch {
            expect(false, "测试准备或读取失败：\(error.localizedDescription)")
        }
        print("结果：连续图片对比 \(passed) 通过，\(failed) 失败")
        return failed == 0 ? 0 : 1
    }

    private static func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    private static func writeImage(_ url: URL, width: Int, height: Int, color: NSColor) throws {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "ComparisonBatchProbe", code: 1)
        }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ComparisonBatchProbe", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ComparisonBatchProbe", code: 3) }
    }
}

/// 不自动服从取消，用于验证调用端本身能拦截迟到结果。
private actor PendingComparisonReads {
    private var pending: [URL: CheckedContinuation<ComparisonPairPreview, Never>] = [:]
    func read(_ source: URL) async -> ComparisonPairPreview {
        await withCheckedContinuation { pending[source] = $0 }
    }
    func contains(_ source: URL) -> Bool { pending[source] != nil }
    func finish(_ source: URL, with preview: ComparisonPairPreview) {
        pending.removeValue(forKey: source)?.resume(returning: preview)
    }
}
