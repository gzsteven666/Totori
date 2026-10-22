import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AVFoundation

/// 无 GUI 的转换自检：`Totori --selftest`
enum SelfTest {

    struct Case {
        let label: String
        let source: String        // fixture key
        let formatKey: String     // OutputFormat.ext
        let expectedExt: String
    }

    static func run() -> Int32 {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xiaoju-selftest-\(getpid())")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let outDir = root.appendingPathComponent("out")
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        print("== Totori 自检 ==")
        print("工作目录：\(root.path)")
        print("")

        var fixtures: [String: URL] = [:]
        var setupFailures: [String] = []

        // 1. 造样本
        let png = root.appendingPathComponent("sample.png")
        if makePNG(at: png) { fixtures["png"] = png } else { setupFailures.append("生成 sample.png") }

        for (key, fmt) in [("jpg", "jpeg"), ("heic", "heic"), ("tiff", "tiff")] {
            let target = root.appendingPathComponent("sample.\(key)")
            if let sips = Shell.which("sips"),
               let png = fixtures["png"],
               let r = try? Shell.run(sips, ["-s", "format", fmt, png.path, "--out", target.path]),
               r.status == 0, fm.fileExists(atPath: target.path) {
                fixtures[key] = target
            } else {
                setupFailures.append("生成 sample.\(key)（sips）")
            }
        }

        let txt = root.appendingPathComponent("sample.txt")
        try? "Totori自检\n第二行文本。\n".write(to: txt, atomically: true, encoding: .utf8)
        fixtures["txt"] = txt

        let svg = outDir.appendingPathComponent("sample.svg")
        try? """
        <svg xmlns="http://www.w3.org/2000/svg" width="160" height="100">
          <rect width="160" height="100" fill="#6fc3f2"/>
          <circle cx="80" cy="50" r="30" fill="#ffffff"/>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        fixtures["svg"] = svg

        let docx = root.appendingPathComponent("sample.docx")
        if let textutil = Shell.which("textutil"),
           let r = try? Shell.run(textutil, ["-convert", "docx", "-output", docx.path, txt.path]),
           r.status == 0, fm.fileExists(atPath: docx.path) {
            fixtures["docx"] = docx
        } else {
            setupFailures.append("生成 sample.docx（textutil）")
        }

        let mp4 = root.appendingPathComponent("sample.mp4")
        if let ffmpeg = Shell.which("ffmpeg"),
           let r = try? Shell.run(ffmpeg, [
               "-hide_banner", "-y",
               "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15",
               "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
               "-t", "1", "-pix_fmt", "yuv420p", "-c:v", "h264_videotoolbox",
               "-c:a", "aac", "-shortest", mp4.path,
           ]), r.status == 0, fm.fileExists(atPath: mp4.path) {
            fixtures["mp4"] = mp4
        } else {
            setupFailures.append("生成 sample.mp4（ffmpeg）")
        }

        let zip = root.appendingPathComponent("sample.zip")
        if let ditto = Shell.which("ditto"),
           let png = fixtures["png"],
           let r = try? Shell.run(ditto, ["-c", "-k", "--keepParent", png.path, zip.path]),
           r.status == 0 {
            fixtures["zip"] = zip
        } else {
            setupFailures.append("生成 sample.zip（ditto）")
        }

        if !setupFailures.isEmpty {
            print("✕ 样本准备失败：")
            setupFailures.forEach { print("   - \($0)") }
            print("")
        }

        // 2. 用例
        let cases: [Case] = [
            .init(label: "PNG → WebP",   source: "png",  formatKey: "webp", expectedExt: "webp"),
            .init(label: "JPG → HEIC",   source: "jpg",  formatKey: "heic", expectedExt: "heic"),
            .init(label: "HEIC → JPG",   source: "heic", formatKey: "jpg",  expectedExt: "jpg"),
            .init(label: "JPG → PDF",    source: "jpg",  formatKey: "pdf",  expectedExt: "pdf"),
            .init(label: "TXT → PDF",    source: "txt",  formatKey: "pdf",  expectedExt: "pdf"),
            .init(label: "DOCX → PDF",   source: "docx", formatKey: "pdf",  expectedExt: "pdf"),
            .init(label: "MP4 → WebM",   source: "mp4",  formatKey: "webm", expectedExt: "webm"),
            .init(label: "MP4 → MP3",    source: "mp4",  formatKey: "mp3",  expectedExt: "mp3"),
            .init(label: "ZIP → ZIP",    source: "zip",  formatKey: "zip",  expectedExt: "zip"),
            .init(label: "SVG → PNG",    source: "svg",  formatKey: "png",  expectedExt: "png"),
            .init(label: "SVG → PDF",    source: "svg",  formatKey: "pdf",  expectedExt: "pdf"),
            .init(label: "TXT → MD",     source: "txt",  formatKey: "md",   expectedExt: "md"),
            .init(label: "JPG → AVIF",   source: "jpg",  formatKey: "avif", expectedExt: "avif"),
            .init(label: "JPG → BMP",    source: "jpg",  formatKey: "bmp",  expectedExt: "bmp"),
            .init(label: "MP4 → MKV",    source: "mp4",  formatKey: "mkv",  expectedExt: "mkv"),
            .init(label: "MP4 → WMV",    source: "mp4",  formatKey: "wmv",  expectedExt: "wmv"),
            .init(label: "MP4 → FLAC",   source: "mp4",  formatKey: "flac", expectedExt: "flac"),
            .init(label: "MP4 → AIFF",   source: "mp4",  formatKey: "aiff", expectedExt: "aiff"),
        ]

        var pass = 0
        var fail = 0
        var failures: [String] = []

        print("用例                            结果    输出")
        print("-------------------------------------------------------------")

        for item in cases {
            guard let source = fixtures[item.source] else {
                print("\(pad(item.label)) 跳过    缺少样本")
                continue
            }
            guard let format = FormatCatalog.all.first(where: { $0.ext == item.formatKey }) else {
                print("\(pad(item.label)) 跳过    未知格式")
                continue
            }

            let start = Date()
            do {
                let output = try Engine.convert(source: source, format: format, to: outDir) { _ in }
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let ok = output.pathExtension.lowercased() == item.expectedExt && size > 0
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if ok {
                    pass += 1
                    print("\(pad(item.label)) ✓        \(output.lastPathComponent) (\(size) B, \(ms) ms)")
                } else {
                    fail += 1
                    failures.append("\(item.label)：输出不合预期（\(output.lastPathComponent), \(size) B）")
                    print("\(pad(item.label)) ✕        \(output.lastPathComponent) (\(size) B)")
                }
            } catch {
                fail += 1
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                failures.append("\(item.label)：\(message)")
                print("\(pad(item.label)) ✕        \(message)")
            }
        }

        // 3. 同名避让
        if let png = fixtures["png"],
           let webp = FormatCatalog.images.first(where: { $0.ext == "webp" }) {
            do {
                let first = try Engine.convert(source: png, format: webp, to: outDir) { _ in }
                let second = try Engine.convert(source: png, format: webp, to: outDir) { _ in }
                if first.lastPathComponent != second.lastPathComponent,
                   FileManager.default.fileExists(atPath: second.path) {
                    pass += 1
                    print("\(pad("同名避让")) ✓        \(second.lastPathComponent)")
                } else {
                    fail += 1
                    failures.append("同名避让：第二次输出覆盖了第一次")
                    print("\(pad("同名避让")) ✕        同名文件被覆盖")
                }
            } catch {
                fail += 1
                failures.append("同名避让：\(error)")
                print("\(pad("同名避让")) ✕        \(error)")
            }
        }

        // 4. 批量
        let batch = ["png", "jpg", "tiff"].compactMap { fixtures[$0] }
        if batch.count >= 2, let pngFmt = FormatCatalog.images.first(where: { $0.ext == "png" }) {
            var okCount = 0
            for source in batch {
                if let _ = try? Engine.convert(source: source, format: pngFmt, to: outDir, progress: { _ in }) {
                    okCount += 1
                }
            }
            if okCount == batch.count {
                pass += 1
                print("\(pad("批量转换")) ✓        \(okCount) 个文件")
            } else {
                fail += 1
                failures.append("批量转换：\(okCount)/\(batch.count) 成功")
                print("\(pad("批量转换")) ✕        \(okCount)/\(batch.count)")
            }
        }

        // 标注：涂黑 + 画笔都要能落盘
        if let png = fixtures["png"], let image = NSImage(contentsOf: png) {
            let ok: Bool = MainActor.assumeIsolated {
                let model = RedactModel(url: png, image: image)
                model.rects = [CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)]
                model.strokes = [[CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.7, y: 0.55)]]
                guard let out = try? model.render() else { return false }
                return TrimExport.size(out) > 0
            }
            if ok { pass += 1 } else { fail += 1; failures.append("标注渲染失败") }
            print("\(pad("标注（涂黑+画笔）")) \(ok ? "✓" : "✕")")
        }

        // 修剪：截 0.3 秒，确认产物时长变短
        if let mp4 = fixtures["mp4"] {
            do {
                let original = TrimExport.duration(mp4)
                let trimmed = try TrimExport.run(url: mp4, start: 0.1, end: 0.4, isAudioOnly: false)
                let after = TrimExport.duration(trimmed)
                let ok = after > 0 && after < original
                if ok { pass += 1 } else { fail += 1; failures.append("修剪后时长没有变短") }
                print("\(pad("视频修剪")) \(ok ? "✓" : "✕")        \(String(format: "%.2f", original))s → \(String(format: "%.2f", after))s")
            } catch {
                fail += 1; failures.append("修剪失败：\(error)")
                print("\(pad("视频修剪")) ✕        \(error)")
            }
        }

        // 压缩预设：同一张图，最小体积档必须比原图小
        if let jpg = fixtures["jpg"] {
            let original = (try? FileManager.default.attributesOfItem(atPath: jpg.path)[.size] as? Int64) ?? 0
            let jpgFormat = FormatCatalog.all.first { $0.ext == "jpg" }
            if let jpgFormat {
                do {
                    let output = try Engine.convert(source: jpg, format: jpgFormat, to: outDir,
                                                    options: CompressionOptions.make(.smaller)) { _ in }
                    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
                    let ok = size > 0 && size < original
                    if ok { pass += 1 } else { fail += 1; failures.append("压缩没有变小") }
                    print("\(pad("压缩（最小体积）")) \(ok ? "✓" : "✕")        \(original) → \(size) B")
                } catch {
                    fail += 1; failures.append("压缩失败：\(error)")
                }
            }
        }

        // 二维码：生成 → 识别 → 比对
        if let code = QRReader.makeCode("https://example.com/xiaoju"), !code.size.equalTo(.zero) {
            let url = outDir.appendingPathComponent("qr-fixture.png")
            if let tiff = code.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                do {
                    let codes = try QRReader.read(url)
                    let ok = codes.first == "https://example.com/xiaoju"
                    if ok { pass += 1 } else { fail += 1; failures.append("二维码识别结果不对：\(codes)") }
                    print("\(pad("二维码识别")) \(ok ? "✓" : "✕")        读到 \(codes.first ?? "-")")
                } catch {
                    fail += 1
                    failures.append("二维码识别失败：\(error)")
                }
            }
        }

        // PDF 合并 / 拆分
        if let txt = fixtures["txt"],
           let pdfFormat = FormatCatalog.all.first(where: { $0.ext == "pdf" }) {
            do {
                let a = try Engine.convert(source: txt, format: pdfFormat, to: outDir) { _ in }
                let b = try Engine.convert(source: txt, format: pdfFormat, to: outDir) { _ in }
                let merged = try ToolRunner.mergePDF(urls: [a, b])
                let mergedDoc = PDFDocument(url: merged)
                let mergedOK = (mergedDoc?.pageCount ?? 0) == 2
                if mergedOK { pass += 1 } else { fail += 1; failures.append("PDF 合并：页数不对") }
                print("\(pad("PDF 合并")) \(mergedOK ? "✓" : "✕")        共 \(mergedDoc?.pageCount ?? 0) 页")

                try ToolRunner.splitPDF(merged)
                let folder = merged.deletingLastPathComponent()
                    .appendingPathComponent("\(merged.deletingPathExtension().lastPathComponent)-拆页")
                let parts = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.count ?? 0
                let splitOK = parts == 2
                if splitOK { pass += 1 } else { fail += 1; failures.append("PDF 拆分：得到 \(parts) 份") }
                print("\(pad("PDF 拆分")) \(splitOK ? "✓" : "✕")        拆出 \(parts) 份")
            } catch {
                fail += 1
                failures.append("PDF 合并/拆分：\(error)")
                print("\(pad("PDF 合并/拆分")) ✕        \(error)")
            }
        }

        // 竖拍照片（EXIF 方向 6）转 WebP：输出必须是转正后的竖图
        if let sips = Shell.which("sips"),
           let webp = FormatCatalog.images.first(where: { $0.ext == "webp" }) {
            let rotated = root.appendingPathComponent("rotated.jpg")
            var detail = "无法生成方向样本"
            var ok = false
            if makeRotatedJPEG(at: rotated) {
                do {
                    let out = try Engine.convert(source: rotated, format: webp, to: outDir) { _ in }
                    let r = try Shell.run(sips, ["-g", "pixelWidth", "-g", "pixelHeight", out.path],
                                          captureOutput: true)
                    func value(_ key: String) -> Int? {
                        r.stdout.split(separator: "\n").first { $0.contains(key) }
                            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
                    }
                    let w = value("pixelWidth") ?? 0, h = value("pixelHeight") ?? 0
                    ok = w == 100 && h == 200
                    detail = "\(w)×\(h)（期望 100×200）"
                } catch { detail = "\(error)" }
            }
            if ok { pass += 1 } else { fail += 1; failures.append("WebP 方向：\(detail)") }
            print("\(pad("竖图 → WebP 方向")) \(ok ? "✓" : "✕")        \(detail)")
        }

        // AVIF/BMP/GIF/JP2 与 PNG/JPEG 走同一条管线：竖图方向正确、遵守清元数据与缩边、JP2 能写出
        do {
            let rotated = root.appendingPathComponent("rotated.jpg")
            var problems: [String] = []
            func displayed(_ url: URL) -> (Int, Int)? {
                guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let t = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary) else { return nil }
                return (t.width, t.height)
            }
            if makeRotatedJPEG(at: rotated) {
                for ext in ["avif", "bmp", "gif", "jp2"] {
                    guard let format = FormatCatalog.images.first(where: { $0.ext == ext }) else { continue }
                    do {
                        let plain = try Engine.convert(source: rotated, format: format, to: outDir) { _ in }
                        if let size = displayed(plain), size != (100, 200) { problems.append("\(ext) 方向 \(size)") }
                        let stripped = try Engine.convert(source: rotated, format: format, to: outDir,
                                                          stripMetadata: true) { _ in }
                        if let size = displayed(stripped), size != (100, 200) { problems.append("\(ext) 清元数据后方向 \(size)") }
                        var small = CompressionOptions.none
                        small.maxSide = 50
                        let scaled = try Engine.convert(source: rotated, format: format, to: outDir,
                                                        options: small) { _ in }
                        if let size = displayed(scaled), max(size.0, size.1) > 50 { problems.append("\(ext) 未缩边 \(size)") }
                    } catch { problems.append("\(ext)：\((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
                }
            } else { problems.append("无法生成方向样本") }
            if problems.isEmpty { pass += 1 } else { fail += 1; failures.append("AVIF/BMP/GIF/JP2 选项：\(problems.joined(separator: "；"))") }
            print("\(pad("AVIF/BMP/GIF/JP2 选项")) \(problems.isEmpty ? "✓" : "✕")        \(problems.isEmpty ? "方向、清元数据、缩边均生效" : problems.joined(separator: "；"))")
        }

        // 视频码率按分辨率自适应：1080p30 与旧固定值（6M）接近，4K 更高、小分辨率更低，且不超过源码率
        do {
            let hd = Engine.adaptiveVideoBitrate(width: 1920, height: 1080, fps: 30, sourceBitsPerSecond: nil, bitsPerPixel: 0.1)
            let uhd = Engine.adaptiveVideoBitrate(width: 3840, height: 2160, fps: 30, sourceBitsPerSecond: nil, bitsPerPixel: 0.1)
            let sd = Engine.adaptiveVideoBitrate(width: 640, height: 480, fps: 30, sourceBitsPerSecond: nil, bitsPerPixel: 0.1)
            let capped = Engine.adaptiveVideoBitrate(width: 1920, height: 1080, fps: 30, sourceBitsPerSecond: 2_000_000, bitsPerPixel: 0.1)
            let floor = Engine.adaptiveVideoBitrate(width: 160, height: 120, fps: 15, sourceBitsPerSecond: nil, bitsPerPixel: 0.1)
            let parsed = Engine.parseProbe(json: """
                {"streams":[{"width":1280,"height":720,"r_frame_rate":"30000/1001","bit_rate":"3500000"}],
                 "format":{"duration":"12.5"}}
                """)
            let ok = (5_500_000...6_900_000).contains(hd) && uhd > 20_000_000 && sd < 1_500_000
                && capped == 2_000_000 && floor == 500_000
                && parsed.width == 1280 && parsed.height == 720 && parsed.duration == 12.5
                && parsed.videoBitsPerSecond == 3_500_000 && abs((parsed.fps ?? 0) - 29.97) < 0.01
            let detail = "1080p=\(hd / 1000)k 4K=\(uhd / 1000)k 480p=\(sd / 1000)k"
            if ok { pass += 1 } else { fail += 1; failures.append("视频码率自适应：\(detail) 封顶=\(capped) 下限=\(floor) 解析=\(parsed)") }
            print("\(pad("视频码率自适应")) \(ok ? "✓" : "✕")        \(detail)")
        }

        // 多音轨：mp4/mkv 输出保留全部音轨；无音轨的源也能转成视频
        if let ffmpeg = Shell.which("ffmpeg"), let ffprobe = Shell.which("ffprobe") {
            let twoAudio = root.appendingPathComponent("two-audio.mp4")
            let silent = root.appendingPathComponent("silent.mp4")
            func audioStreams(_ url: URL) -> Int {
                let r = try? Shell.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries",
                                                 "stream=index", "-of", "csv=p=0", url.path], captureOutput: true)
                return r?.stdout.split(separator: "\n").count ?? -1
            }
            var problems: [String] = []
            let made = (try? Shell.run(ffmpeg, [
                "-hide_banner", "-y",
                "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=1",
                "-map", "0:v", "-map", "1:a", "-map", "2:a", "-t", "1", "-pix_fmt", "yuv420p",
                "-c:v", "h264_videotoolbox", "-c:a", "aac", twoAudio.path,
            ]).status == 0) ?? false
            let madeSilent = (try? Shell.run(ffmpeg, [
                "-hide_banner", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15", "-t", "1",
                "-pix_fmt", "yuv420p", "-c:v", "h264_videotoolbox", silent.path,
            ]).status == 0) ?? false
            if made && madeSilent && audioStreams(twoAudio) == 2 {
                for ext in ["mp4", "mov", "mkv", "webm"] {
                    guard let format = FormatCatalog.medias.first(where: { $0.ext == ext }) else { continue }
                    do {
                        let out = try Engine.convert(source: twoAudio, format: format, to: outDir) { _ in }
                        let count = audioStreams(out)
                        if count != 2 { problems.append("\(ext) 音轨 \(count)/2") }
                    } catch { problems.append("\(ext)：\((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
                }
                if let mp4 = FormatCatalog.medias.first(where: { $0.ext == "mp4" }) {
                    do { _ = try Engine.convert(source: silent, format: mp4, to: outDir) { _ in } }
                    catch { problems.append("无音轨源转 mp4：\((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
                }
            } else { problems.append("无法生成多音轨样本") }
            if problems.isEmpty { pass += 1 } else { fail += 1; failures.append("多音轨：\(problems.joined(separator: "；"))") }
            print("\(pad("多音轨保留")) \(problems.isEmpty ? "✓" : "✕")        \(problems.isEmpty ? "mp4/mov/mkv/webm 均保留 2 条音轨" : problems.joined(separator: "；"))")
        }

        // 复用的文档引擎配置被写坏（例如转换中途被取消）时，应自动改用干净配置并恢复
        if FileManager.default.isExecutableFile(atPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice") || Shell.which("soffice") != nil, let docx = fixtures["docx"],
           let pdf = FormatCatalog.documents.first(where: { $0.ext == "pdf" }) {
            var detail = ""
            var ok = false
            do {
                _ = try Engine.convert(source: docx, format: pdf, to: outDir) { _ in }   // 确保配置已存在
                let settings = Engine.sharedProfile.appendingPathComponent("user/registrymodifications.xcu")
                try "damaged <<<".write(to: settings, atomically: true, encoding: .utf8)
                let recovered = try Engine.convert(source: docx, format: pdf, to: outDir) { _ in }
                let healed = try Engine.convert(source: docx, format: pdf, to: outDir) { _ in }
                ok = FileManager.default.fileExists(atPath: recovered.path)
                    && FileManager.default.fileExists(atPath: healed.path)
                detail = ok ? "损坏后转换成功，配置已重建" : "输出缺失"
            } catch { detail = "\((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
            if ok { pass += 1 } else { fail += 1; failures.append("文档引擎配置损坏恢复：\(detail)") }
            print("\(pad("文档引擎配置损坏恢复")) \(ok ? "✓" : "✕")        \(detail)")
        }

        // 同批文档一次启动转换：命中暂存的文件不再单独启动；同名文件与被改动的文件走单独流程
        if FileManager.default.isExecutableFile(atPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
            || Shell.which("soffice") != nil,
           let textutil = Shell.which("textutil"),
           let pdf = FormatCatalog.documents.first(where: { $0.ext == "pdf" }) {
            let batchRoot = root.appendingPathComponent("doc-batch")
            var detail = ""
            var ok = false
            do {
                var sources: [URL] = []
                for (folder, name) in [("a", "one"), ("a", "two"), ("a", "three"), ("b", "dup"), ("c", "dup")] {
                    let dir = batchRoot.appendingPathComponent(folder)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let text = dir.appendingPathComponent("\(name).txt")
                    try "批量文档 \(folder)/\(name)\n".write(to: text, atomically: true, encoding: .utf8)
                    let docx = dir.appendingPathComponent("\(name).docx")
                    _ = try Shell.run(textutil, ["-convert", "docx", "-output", docx.path, text.path])
                    sources.append(docx)
                }
                let target = batchRoot.appendingPathComponent("out")
                let before = DocumentPrefetch.hits
                ConversionService.prefetchDocuments(sources: sources, format: pdf, options: .none)
                var outputs: [URL] = []
                for source in sources {
                    outputs.append(try ConversionService.convert(source: source, format: pdf, to: target) { _ in })
                }
                let batchHits = DocumentPrefetch.hits - before
                ConversionService.clearPrefetchedDocuments()

                // 预转换之后源文件被改动：该文件的暂存结果必须作废
                let pair = Array(sources.prefix(2))
                let beforeStale = DocumentPrefetch.hits
                ConversionService.prefetchDocuments(sources: pair, format: pdf, options: .none)
                let text = pair[0].deletingPathExtension().appendingPathExtension("txt")
                try "改过的内容，长度也不同\n".write(to: text, atomically: true, encoding: .utf8)
                try fm.removeItem(at: pair[0])
                _ = try Shell.run(textutil, ["-convert", "docx", "-output", pair[0].path, text.path])
                for source in pair { _ = try ConversionService.convert(source: source, format: pdf, to: target) { _ in } }
                let staleHits = DocumentPrefetch.hits - beforeStale
                ConversionService.clearPrefetchedDocuments()

                let allExist = outputs.allSatisfy { Engine.fileSize($0) > 100 }
                ok = batchHits == 3 && allExist && staleHits == 1
                detail = "命中 \(batchHits)/3（同名 2 个单独转换），改动后命中 \(staleHits)/1，输出 \(outputs.count) 个"
            } catch { detail = "\((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
            if ok { pass += 1 } else { fail += 1; failures.append("文档批量预转换：\(detail)") }
            print("\(pad("文档批量一次启动")) \(ok ? "✓" : "✕")        \(detail)")
        }

        // 清除元数据时重绘像素，必须沿用原图色彩空间（如 Display P3），不能压成 DeviceRGB
        do {
            let p3 = root.appendingPathComponent("p3.png")
            var detail = "无法生成 P3 样本"
            var ok = false
            if makeP3PNG(at: p3), let png = FormatCatalog.images.first(where: { $0.ext == "png" }) {
                do {
                    let out = try Engine.convert(source: p3, format: png, to: outDir, stripMetadata: true) { _ in }
                    let space = CGImageSourceCreateWithURL(out as CFURL, nil)
                        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.colorSpace
                    let name = (space?.name as String?) ?? "无"
                    ok = name == (CGColorSpace.displayP3 as String)
                    detail = "输出色彩空间：\(name)"
                } catch { detail = "\(error)" }
            }
            if ok { pass += 1 } else { fail += 1; failures.append("清元数据后色彩空间：\(detail)") }
            print("\(pad("清元数据保留色域")) \(ok ? "✓" : "✕")        \(detail)")
        }

        // 长任务超时：无进展会被中止，持续有进展则不受总时长限制
        do {
            let began = Date()
            let stalled = try Shell.run("/bin/sleep", ["30"], idleTimeout: 1)
            let stalledElapsed = Date().timeIntervalSince(began)
            let ok = stalled.timedOut && stalledElapsed < 10
            if ok { pass += 1 } else { fail += 1; failures.append("无进展进程未在空闲超时内中止") }
            print("\(pad("无进展超时中止")) \(ok ? "✓" : "✕")        \(String(format: "%.1f", stalledElapsed))s")

            let busy = try Shell.run("/bin/sh", ["-c", "for i in 1 2 3 4; do echo tick; sleep 0.7; done"],
                                     idleTimeout: 1)
            let busyOK = !busy.timedOut && busy.status == 0
            if busyOK { pass += 1 } else { fail += 1; failures.append("持续有进展的进程被空闲超时误杀") }
            print("\(pad("持续进展不被误杀")) \(busyOK ? "✓" : "✕")        总耗时超过空闲阈值仍完成")
        } catch {
            fail += 1; failures.append("超时用例异常：\(error)")
            print("\(pad("空闲超时")) ✕        \(error)")
        }

        // 子进程输出：大输出不丢尾、多字节字符被分块切开仍可还原、无换行的最后一行不丢
        do {
            let big = try Shell.run("/usr/bin/seq", ["1", "300000"], captureOutput: true)
            let bigOK = big.stdout.split(separator: "\n").last == "300000"
            var lines: [String] = []
            let split = try Shell.run("/bin/sh",
                ["-c", "printf '\\344\\270'; sleep 0.3; printf '\\255\\n'; printf tail"]) { lines.append($0) }
            let splitOK = lines == ["中", "tail"] && split.stdout == "中\ntail"
            let ok = bigOK && splitOK
            if ok { pass += 1 } else { fail += 1; failures.append("子进程输出：大输出=\(bigOK) 分块字符=\(splitOK) \(lines)") }
            print("\(pad("子进程输出完整性")) \(ok ? "✓" : "✕")        大输出尾行、分块中文、无换行末行")
        } catch {
            fail += 1; failures.append("子进程输出用例异常：\(error)")
            print("\(pad("子进程输出完整性")) ✕        \(error)")
        }

        // 输出格式按输入过滤：必然失败的组合不再提供，常规组合保持可选
        do {
            func exts(_ names: [String]) -> Set<String> {
                Set(FormatCatalog.formats(for: FormatCatalog.kind(of: URL(fileURLWithPath: "/x/" + names[0])),
                                          sources: names.map { URL(fileURLWithPath: "/x/" + $0) }).map(\.ext))
            }
            let checks: [(String, Bool)] = [
                ("pptx 只能 PDF/HTML", exts(["a.pptx"]) == ["pdf", "html"]),
                ("xlsx 只能 PDF/HTML", exts(["a.xlsx"]) == ["pdf", "html"]),
                ("pdf 只能 HTML", exts(["a.pdf"]) == ["html"]),
                ("docx 保留全部文档格式", exts(["a.docx"]) == Set(FormatCatalog.documents.map(\.ext))),
                ("csv 不含 epub/md", !exts(["a.csv"]).contains("epub") && exts(["a.csv"]).contains("docx")),
                ("mp3 不含视频/GIF", exts(["a.mp3"]).isDisjoint(with: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"])
                    && exts(["a.mp3"]).contains("flac")),
                ("mp4 保留全部音视频格式", exts(["a.mp4"]) == Set(FormatCatalog.medias.map(\.ext))),
                ("jpg 保留 JPEG 重新编码", exts(["a.jpg"]).contains("jpg")),
                ("多文件取交集", exts(["a.docx", "b.pdf"]) == ["html"]),
            ]
            let bad = checks.filter { !$0.1 }.map(\.0)
            if bad.isEmpty { pass += 1 } else { fail += 1; failures.append("输出格式过滤：\(bad.joined(separator: "、"))") }
            print("\(pad("输出格式按输入过滤")) \(bad.isEmpty ? "✓" : "✕")        \(checks.count) 条规则\(bad.isEmpty ? "" : "，失败：" + bad.joined(separator: "、"))")
        }

        print("-------------------------------------------------------------")
        print("通过 \(pass) 项，失败 \(fail) 项")
        if !failures.isEmpty {
            print("")
            print("失败明细：")
            failures.forEach { print("  - \($0)") }
        }
        print("")
        print(fail == 0 ? "结果：全部通过 ✅" : "结果：有失败项 ❌")
        return fail == 0 ? 0 : 1
    }

    private static func pad(_ text: String) -> String {
        var value = text
        // 中文字符按两个宽度估算，简化对齐
        var width = 0
        for scalar in text.unicodeScalars {
            width += scalar.value > 0x2E80 ? 2 : 1
        }
        while width < 30 { value += " "; width += 1 }
        return value
    }

    /// 200×100 像素、EXIF 方向 6 的 JPEG；正确显示应为 100×200 的竖图。
    private static func makeRotatedJPEG(at url: URL) -> Bool {
        guard let context = CGContext(
            data: nil, width: 200, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { return false }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Display P3 色彩空间的 PNG，用来检查重绘后色域是否被压回 sRGB。
    private static func makeP3PNG(at url: URL) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(colorSpace: space, components: [0.0, 1.0, 0.2, 1.0])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func makePNG(at url: URL) -> Bool {
        let width = 320, height = 240
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.setFillColor(CGColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        context.fill(CGRect(x: 40, y: 60, width: 240, height: 120))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
