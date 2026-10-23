import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import AppKit

extension Engine {
    // MARK: PDF → 图片 / 纯文本

    /// PDF 转 PNG、JPEG、纯文本时不走 LibreOffice：它只能把 PDF 当绘图打开，导不出这些格式。
    /// 改用系统自带的 PDF 渲染（CoreGraphics 画页面、PDFKit 取文字），不依赖外部工具。
    static func usesPDFRenderer(source: URL, ext: String) -> Bool {
        FormatCatalog.effectiveExtension(of: source) == "pdf" && ["png", "jpg", "txt"].contains(ext.lowercased())
    }

    /// 多页文档逐页图片所在文件夹的名字，如“报告 - PNG 页面”
    static func pageFolderName(for source: URL, ext: String) -> String {
        "\(source.deletingPathExtension().lastPathComponent) - \(ext == "jpg" ? "JPEG" : ext.uppercased()) 页面"
    }

    /// 渲染倍率：2 倍即 144 dpi，A4 约 1190×1684 像素，屏幕查看与一般打印都够清晰。
    /// 超大页面（海报、工程图）把最长边限制在 8000 像素，避免一页就占用上百 MB 内存。
    static let pdfRenderScale: CGFloat = 2
    static let pdfMaxPixels: CGFloat = 8000

    /// 任意文档转逐页图片：PDF 直接渲染；其他文档先用 LibreOffice 转成临时 PDF（沿用 Excel 排版选项），再渲染。
    /// - Returns: 单页时是写好的图片 `file`；多页时是装着各页图片的 `folder`。
    static func convertToPageImages(source: URL, ext: String, file: URL, folder: URL,
                                    pageBaseName: String, layout: SpreadsheetPDFLayout,
                                    progress: @escaping (Double) -> Void) throws -> URL {
        // SVG 用系统直接画，不必启动 LibreOffice，也保留透明背景（PNG）
        if FormatCatalog.effectiveExtension(of: source) == "svg", (try? renderSVG(source, ext: ext, to: file)) == true {
            progress(1)
            return file
        }
        var pdf = source
        var render = progress
        if FormatCatalog.effectiveExtension(of: source) != "pdf" {
            pdf = folder.deletingLastPathComponent().appendingPathComponent("render-\(UUID().uuidString).pdf")
            // 转 PDF 占前六成进度，渲染占后四成
            try convertDocument(source: source, ext: "pdf", destination: pdf, layout: layout) { progress($0 * 0.6) }
            render = { progress(0.6 + $0 * 0.4) }
        }
        defer { if pdf != source { try? FileManager.default.removeItem(at: pdf) } }
        let count = CGPDFDocument(pdf as CFURL)?.numberOfPages ?? 0
        let destination = count > 1 ? folder : file
        try convertPDF(source: pdf, ext: ext, destination: destination, pageBaseName: pageBaseName, progress: render)
        return destination
    }

    /// - Parameters:
    ///   - destination: 单页时是图片文件本身；多页时是要新建的文件夹。
    ///   - pageBaseName: 页面图片的文件名前缀，用原文件名，不用暂存区里的符号链接名。
    /// - Throws: 打不开、有密码、没有页面或（转文字时）没有可提取的文字时抛出 `ConversionError`；
    ///   每页之间检查取消。
    static func convertPDF(source: URL, ext: String, destination: URL,
                           pageBaseName: String,
                           progress: @escaping (Double) -> Void) throws {
        progress(0.05)
        if ext == "txt" {
            try extractPDFText(source: source, destination: destination)
            progress(1)
            return
        }

        guard let document = CGPDFDocument(source as CFURL) else {
            throw ConversionError.failed("无法打开这个 PDF，文件可能已损坏")
        }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw ConversionError.failed("这个 PDF 有密码保护，无法转换")
        }
        let count = document.numberOfPages
        guard count > 0 else { throw ConversionError.failed("这个 PDF 没有页面") }

        let isFolder = count > 1
        if isFolder {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let digits = String(count).count
        for number in 1...count {
            try ConversionCancellation.current?.check()
            guard let page = document.page(at: number), let image = renderPDFPage(page, opaque: true) else {
                throw ConversionError.failed("第 \(number) 页渲染失败")
            }
            let pageName = "\(pageBaseName)-\(String(repeating: "0", count: digits - String(number).count))\(number).\(ext)"
            let target = isFolder ? destination.appendingPathComponent(pageName) : destination
            try writePageImage(image, ext: ext, to: target)
            progress(0.05 + 0.95 * Double(number) / Double(count))
        }
    }

    /// 按页面的裁切框和旋转角度渲染一页，白底（PDF 页面本来就是白纸，透明底在看图软件里会变成黑底或棋盘格）。
    static func renderPDFPage(_ page: CGPDFPage, opaque: Bool) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(pdfRenderScale, pdfMaxPixels / max(size.width, size.height))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // getDrawingTransform 会把裁切框按页面自带的旋转角度摆正，放进目标矩形
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// SVG 按自身尺寸的 2 倍渲染；系统读不了这个 SVG 时返回 false，调用方改走 LibreOffice。
    /// PNG 保留透明背景，JPEG 没有透明通道，铺白底。
    static func renderSVG(_ source: URL, ext: String, to target: URL) throws -> Bool {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else { return false }
        let scale = min(pdfRenderScale, pdfMaxPixels / max(image.size.width, image.size.height))
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        if ext == "jpg" {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = context.makeImage() else { return false }
        try writePageImage(rendered, ext: ext, to: target)
        return true
    }

    private static func writePageImage(_ image: CGImage, ext: String, to url: URL) throws {
        let type = (ext == "jpg" ? UTType.jpeg : UTType.png).identifier as CFString
        guard let target = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ConversionError.failed("无法写出图片：\(url.lastPathComponent)")
        }
        let properties: [CFString: Any] = ext == "jpg" ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(target, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(target) else {
            throw ConversionError.failed("无法写出图片：\(url.lastPathComponent)")
        }
    }

    /// 只取文字，页与页之间空一行；扫描件这类没有文字层的 PDF 给出明确提示，而不是写出空文件。
    private static func extractPDFText(source: URL, destination: URL) throws {
        guard let document = PDFDocument(url: source) else {
            throw ConversionError.failed("无法打开这个 PDF，文件可能已损坏")
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw ConversionError.failed("这个 PDF 有密码保护，无法转换")
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try ConversionCancellation.current?.check()
            pages.append(document.page(at: index)?.string ?? "")
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.failed("这个 PDF 没有可提取的文字（可能是扫描件或纯图片）")
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }
}
