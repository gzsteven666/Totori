import AppKit
import Vision

/// 二维码 / 条形码识别。原版有 QRCodeResultsPanel/Model 和「Copy QR code text」。
enum QRReader {
    /// 返回每个码的文本内容（可能一张图里有多个）
    static func read(_ url: URL) throws -> [String] {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.failed("读不到这张图片")
        }

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let results = (request.results ?? []).compactMap { $0.payloadStringValue }
        return results
    }

    /// 自检用：生成一张包含指定文本的二维码
    static func makeCode(_ text: String, side: CGFloat = 240) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: side / output.extent.width,
                                                              y: side / output.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
