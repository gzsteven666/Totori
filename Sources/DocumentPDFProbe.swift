import AppKit
import PDFKit

/// 合成宽表和长表检查中文内容、页宽适配、原件保护及批次参数快照。
@MainActor
enum DocumentPDFProbe {
    static func run(source: URL? = nil) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in exit(await execute(source: source)) }
        app.run()
        return 0
    }

    private static func execute(source: URL?) async -> Int32 {
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ label: String) {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("totori-中文 PDF-\(UUID().uuidString)")
        print("OUTPUT \(root.path)")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let wide = try source ?? makeWorkbook(in: root, rows: 6)
            let bytes = try Data(contentsOf: wide)
            let pdf = FormatCatalog.documents.first { $0.ext == "pdf" }!
            let original = try Engine.convert(source: wide, format: pdf, to: root.appendingPathComponent("original")) { _ in }
            let originalPDF = PDFDocument(url: original)!
            expect(originalPDF.pageCount > 1, "默认保留原表分页")
            if source == nil { expect(originalPDF.string?.contains("中文字体测试") == true, "默认导出包含正确中文") }

            let model = AppModel()
            model.add(urls: [wide])
            model.selectedFormat = pdf
            expect(model.spreadsheetPDFLayout == .original && model.supportsSpreadsheetPDFLayout,
                   "Excel 转 PDF 显示选项并默认保留原表设置")
            model.spreadsheetPDFLayout = .fitWidth
            model.useSourceFolder = false
            model.outputDirectory = root.appendingPathComponent("fit-width")
            model.convertAll()
            model.spreadsheetPDFLayout = .original
            try await wait(model)
            let fitted = model.results.first?.output.flatMap { PDFDocument(url: $0) }
            expect(model.results.first?.ok == true && fitted?.pageCount == 1, "批次固定适配选项，宽表导出一页")
            expect(fitted?.page(at: 0).map { $0.bounds(for: .mediaBox).width > $0.bounds(for: .mediaBox).height } == true,
                   "适配页宽采用横向纸张")
            if source == nil { expect(fitted?.string?.contains("中文字体测试") == true, "适配导出包含正确中文") }
            expect(try Data(contentsOf: wide) == bytes, "Excel 原件字节保持不变")

            var options = CompressionOptions.none
            options.spreadsheetPDFLayout = .fitWidth
            let tall = try makeWorkbook(in: root, rows: 160)
            let longPDF = try Engine.convert(source: tall, format: pdf, to: root.appendingPathComponent("tall"), options: options) { _ in }
            expect((PDFDocument(url: longPDF)?.pageCount ?? 0) > 1, "长表保留纵向分页，没有压成一张长页")

            let legacyDir = root.appendingPathComponent("legacy")
            try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            if let soffice = Shell.which("soffice") {
                let profile = root.appendingPathComponent("xls-profile").absoluteString
                let converted = try Shell.run(soffice, ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", "xls:MS Excel 97", "--outdir", legacyDir.path, wide.path], timeout: 60)
                let legacy = legacyDir.appendingPathComponent(wide.deletingPathExtension().lastPathComponent + ".xls")
                expect(converted.status == 0 && fm.fileExists(atPath: legacy.path), "生成 XLS 合成兼容样本")
                let legacyPDF = try Engine.convert(source: legacy, format: pdf, to: root.appendingPathComponent("xls-fit"), options: options) { _ in }
                expect(PDFDocument(url: legacyPDF)?.pageCount == 1, "XLS 也支持适配页宽")
            } else { expect(false, "缺少 LibreOffice，无法验证 XLS") }

            model.clear()
            expect(model.spreadsheetPDFLayout == .original, "清空后恢复原表设置")
            let text = root.appendingPathComponent("中文.txt")
            try "中文字体测试\n第二行文本。".write(to: text, atomically: true, encoding: .utf8)
            model.add(urls: [text])
            model.selectedFormat = pdf
            expect(!model.supportsSpreadsheetPDFLayout, "非 Excel 文件不显示页宽选项")
            let textPDF = try Engine.convert(source: text, format: pdf, to: root.appendingPathComponent("text")) { _ in }
            expect(PDFDocument(url: textPDF)?.string?.contains("中文字体测试") == true, "文本文档共用中文字体配置")
        } catch { failed += 1; print("FAIL \(error)") }
        print("RESULT \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    private static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(90)
        while model.isConverting && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        if model.isConverting { model.cancelConversion(); throw ConversionError.failed("文档验收超时") }
    }

    private static func makeWorkbook(in root: URL, rows: Int) throws -> URL {
        let folder = root.appendingPathComponent("fixture-\(rows)")
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let content = (1...rows).map { row in
            let cells = (0..<15).map { col in
                "<c r=\"\(String(UnicodeScalar(65 + col)!))\(row)\" t=\"inlineStr\"><is><t>中文字体测试\(row)</t></is></c>"
            }.joined()
            return "<row r=\"\(row)\" ht=\"20\" customHeight=\"1\">\(cells)</row>"
        }.joined()
        let files = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>",
            "_rels/.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            "xl/workbook.xml": "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"中文宽表\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>",
            "xl/styles.xml": "<styleSheet xmlns=\"\(ns)\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"微软雅黑\"/></font></fonts><fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf/></cellStyleXfs><cellXfs count=\"1\"><xf fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs></styleSheet>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(ns)\"><cols><col min=\"1\" max=\"15\" width=\"20\" customWidth=\"1\"/></cols><sheetData>\(content)</sheetData><pageSetup paperSize=\"9\" orientation=\"portrait\"/></worksheet>"
        ]
        for (entry, xml) in files {
            let file = folder.appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: file, atomically: true, encoding: .utf8)
        }
        let output = root.appendingPathComponent("中文 宽表-\(rows).xlsx")
        let zipped = try Shell.run("/usr/bin/ditto", ["-c", "-k", folder.path, output.path])
        guard zipped.status == 0 else { throw ConversionError.failed("无法生成 Excel 测试样本") }
        return output
    }
}
