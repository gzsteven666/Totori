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
