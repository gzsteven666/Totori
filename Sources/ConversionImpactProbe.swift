import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 用真实文件验证简介、提示与输出相符，同时检查迟到请求不会污染下一批。
@MainActor
enum ConversionImpactProbe {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in exit(await execute()) }
        app.run()
        return 0
    }

    private static func execute() async -> Int32 {
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)")
        }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: "/Users/mac/Documents/Codex/2026-10-19/zhe/work/iteration10/impact-probe-\(getpid())")
        func format(_ ext: String, _ kind: FileKind) -> OutputFormat {
            FormatCatalog.formats(for: kind).first { $0.ext == ext }!
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let alpha = folder.appendingPathComponent("透明图层.png")
            let opaque = folder.appendingPathComponent("不透明图片.png")
            try writeFixture(alpha, transparent: true)
            try writeFixture(opaque, transparent: false)
            let original = try Data(contentsOf: alpha)
            let snapshots = await ConversionImpact.read([alpha, opaque])
            expect(snapshots.count == 2 && snapshots[0].url == alpha && snapshots[1].url == opaque,
                   "批量读取保持输入顺序")
            expect(snapshots[0].hasAlpha == true && snapshots[1].hasAlpha != true && snapshots[1].pixelWidth == 240,
                   "真实PNG中透明通道有标记，不透明图无标记时不编造结论")
            let jpeg = format("jpg", .image)
            expect(ConversionImpact.text(format: jpeg, sources: snapshots).contains("不保留透明背景"),
                   "混合批次中有透明通道即提示JPEG变化")
            expect(!ConversionImpact.text(format: jpeg, sources: [snapshots[1]]).contains("透明"),
                   "不透明图不显示透明背景提示")
            expect(!ConversionImpact.text(format: format("png", .image), sources: snapshots).contains("透明"),
                   "透明PNG转PNG没有错误的透明丢失提示")
            let missing = await FileMetadataReader.read(folder.appendingPathComponent("缺失.png"))
            expect(missing.hasAlpha == nil && !ConversionImpact.text(format: jpeg, sources: [missing]).contains("透明"),
                   "读不到通道不编造透明结论")
            let output = try Engine.convert(source: alpha, format: jpeg, to: folder.appendingPathComponent("output")) { _ in }
            let jpg = await FileMetadataReader.read(output)
            expect(jpg.hasAlpha != true && jpg.pixelWidth == 240 && jpg.pixelHeight == 160,
                   "实际JPEG没有透明通道且保留像素尺寸")
            expect(try Data(contentsOf: alpha) == original, "读取提示与转换保留原图")

            let fixtureRoot = URL(fileURLWithPath: "/Users/mac/Documents/Codex/2026-10-19/zhe/work/acceptance-round2/inputs")
            let videoURL = fixtureRoot.appendingPathComponent("07-视频样本.mp4")
            let video = await FileMetadataReader.read(videoURL)
            expect(video.isVideo, "真实视频被识别为含画面")
            expect(ConversionImpact.text(format: format("mp3", .media), sources: [video]).contains("仅保留声音"),
                   "视频转音频提示移除画面")
            expect(ConversionImpact.text(format: format("gif", .media), sources: [video]).contains("不保留声音"),
                   "视频转GIF提示移除声音")
            let mp3URL = try Engine.convert(source: videoURL, format: format("mp3", .media),
                                            to: folder.appendingPathComponent("audio-output")) { _ in }
            let mp3 = await FileMetadataReader.read(mp3URL)
            expect(mp3.isAudio && !mp3.isVideo && mp3.pixelWidth == nil && mp3.duration != nil,
                   "实际MP3输出只有音频，与变化提示一致")
            let gifURL = try Engine.convert(source: videoURL, format: format("gif", .media),
                                            to: folder.appendingPathComponent("gif-output")) { _ in }
            let gif = await FileMetadataReader.read(gifURL)
            expect(gif.isImage && (gif.frameCount ?? 0) > 1 && !gif.isAudio,
                   "实际GIF输出是多帧动图，与无声提示一致")
            expect(!ConversionImpact.text(format: format("mp4", .media), sources: [video]).contains("仅保留声音"),
                   "视频转视频不误报丢失画面")
            let audio = await FileMetadataReader.read(fixtureRoot.appendingPathComponent("09-音频样本.mp3"))
            expect(audio.isAudio && !ConversionImpact.text(format: format("wav", .media), sources: [audio]).contains("画面"),
                   "纯音频转码不显示画面丢失提示")
            expect(ConversionImpact.text(format: format("txt", .document), sources: []).contains("排版"),
                   "纯文本目标解释内容变化")
            expect(ConversionImpact.text(format: format("pdf", .image), sources: snapshots).contains("每张图片"),
                   "图片批量转PDF明确单独输出而非合并")

            let model = FanModel()
            model.loadImpactSources([alpha])
            for _ in 0..<100 where model.impactSources.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            expect(model.hint(for: .format(jpeg)) == ConversionImpact.text(format: jpeg, sources: snapshots),
                   "花瓣与主窗口共用透明背景提示")
            model.loadImpactSources([alpha]); model.loadImpactSources([opaque])
            for _ in 0..<100 where model.impactSources.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            expect(model.impactSources.first?.url == opaque && !model.hint(for: .format(jpeg)).contains("透明"),
                   "切换文件后旧异步请求不能污染新提示")
            model.loadImpactSources([alpha]); model.clearImpactSources()
            try await Task.sleep(nanoseconds: 100_000_000)
            expect(model.impactSources.isEmpty, "关闭花瓣后不接受迟到简介")
            expect(model.hint(for: .moreFormats(.image)) == "松手后选择其他格式", "更多花瓣保留松手语义")
            let thumbnail = await ShelfThumbnailStore.shared.load(opaque, maxPixel: 220)
            expect(thumbnail?.image != nil && thumbnail!.image!.width == 220, "主列表复用浮窗缩略图尺寸，避免缓存变糊")
            let videoThumbnail = await ShelfThumbnailStore.shared.load(videoURL, maxPixel: 220)
            expect(videoThumbnail?.image != nil, "实际视频生成首帧封面")

            let cancelStore = ShelfThumbnailStore()
            let queuedURLs = try (0..<24).map { index -> URL in
                let url = folder.appendingPathComponent("取消封面-\(index).mp4")
                try fm.copyItem(at: videoURL, to: url)
                return url
            }
            let pending = queuedURLs.map { url in Task { await cancelStore.load(url, maxPixel: 220) } }
            await Task.yield()
            pending.forEach { $0.cancel() }
            for task in pending { _ = await task.value }
            expect(queuedURLs.filter { cancelStore.cached($0) != nil }.count < queuedURLs.count,
                   "取消一批排队视频封面后不继续解码并缓存全部过期任务")
            let fresh = await cancelStore.load(queuedURLs.last!, maxPixel: 220)
            expect(fresh?.image != nil, "取消后清理占位和生成名额，新封面仍可加载")

            let single = AppModel(); single.add(urls: [alpha])
            expect(single.primaryActionTitle == "转换 1 个" && single.primaryActionNote == nil,
                   "单文件按钮精简且无范围长说明")
            single.add(urls: [opaque])
            expect(single.primaryActionTitle == "转换全部 2 个", "多文件主按钮继续明确全部范围")
        } catch { failed += 1; print("FAIL \(error)") }
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    private static func writeFixture(_ url: URL, transparent: Bool) throws {
        let alpha = transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: alpha.rawValue) else { throw ConversionError.failed("无法创建样图") }
        if !transparent { context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 240, height: 160)) }
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fillEllipse(in: CGRect(x: 40, y: 20, width: 160, height: 120))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ConversionError.failed("无法写入样图") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("样图写入失败") }
    }
}
