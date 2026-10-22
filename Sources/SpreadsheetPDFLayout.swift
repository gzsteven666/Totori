import Foundation

enum SpreadsheetPDFLayout: String, CaseIterable, Identifiable {
    case original, fitWidth
    var id: String { rawValue }
    var title: String { self == .original ? "保留原表设置" : "适配页宽" }

    static func supports(_ source: URL) -> Bool {
        ["xlsx", "xls"].contains(source.pathExtension.lowercased())
    }

    /// 只读取选定的 XML 条目，不解包用户归档；修改临时副本，原表保持不变。
    static func fitWidthCopy(of source: URL, in staging: URL) throws -> URL {
        let listing = try Shell.run("/usr/bin/unzip", ["-Z1", source.path], captureOutput: true)
        let entries = listing.stdout.split(separator: "\n").map(String.init).filter {
            // macOS ZIP 中的 ._ 元数据不是工作表。
            $0.range(of: "^xl/worksheets/[^./][^/]*\\.xml$", options: .regularExpression) != nil
                && !$0.contains("..")
        }
        guard listing.status == 0, !entries.isEmpty else {
            throw ConversionError.failed("无法读取 Excel 工作表，页宽适配未执行")
        }
        let copy = staging.appendingPathComponent("fit-width.xlsx")
        try FileManager.default.copyItem(at: source, to: copy)
        let patches = staging.appendingPathComponent("page-layout", isDirectory: true)
        for entry in entries {
            let raw = staging.appendingPathComponent("worksheet.xml")
            let xml = try Shell.run("/usr/bin/unzip", ["-p", source.path, entry], stdoutTo: raw)
            guard xml.status == 0 else { throw ConversionError.failed("无法读取 Excel 页面设置") }
            let document = try XMLDocument(data: Data(contentsOf: raw), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
            guard let sheet = document.rootElement(), sheet.localName == "worksheet" else {
                throw ConversionError.failed("Excel 工作表格式不受支持")
            }
            func child(_ parent: XMLElement, _ name: String, first: Bool = false) -> XMLElement {
                if let value = parent.children?.compactMap({ $0 as? XMLElement }).first(where: { $0.localName == name }) { return value }
                let value = XMLElement(name: name, uri: sheet.uri)
                if first { parent.insertChild(value, at: 0) }
                else if name == "pageSetup", let index = parent.children?.firstIndex(where: {
                    ["headerFooter", "rowBreaks", "colBreaks", "customProperties", "cellWatches",
                     "ignoredErrors", "smartTags", "drawing", "legacyDrawing", "legacyDrawingHF",
                     "picture", "oleObjects", "controls", "webPublishItems", "tableParts", "extLst"].contains($0.localName ?? "")
                }) { parent.insertChild(value, at: index) }
                else { parent.addChild(value) }
                return value
            }
            func set(_ element: XMLElement, _ key: String, _ value: String) {
                element.removeAttribute(forName: key)
                element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
            }
            set(child(child(sheet, "sheetPr", first: true), "pageSetUpPr"), "fitToPage", "1")
            let setup = child(sheet, "pageSetup")
            setup.removeAttribute(forName: "scale")
            set(setup, "orientation", "landscape")
            set(setup, "paperSize", "9")
            set(setup, "fitToWidth", "1")
            set(setup, "fitToHeight", "0")
            let patch = patches.appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: patch.deletingLastPathComponent(), withIntermediateDirectories: true)
            try document.xmlData.write(to: patch)
        }
        let result = try Shell.run("/usr/bin/zip", ["-q", copy.path] + entries,
                                   currentDirectory: patches)
        guard result.status == 0 else { throw ConversionError.failed("无法写入 Excel 页宽适配副本") }
        return copy
    }
}
