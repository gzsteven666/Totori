import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension Engine {
    // MARK: 图标

    /// ICO 常用尺寸：网站 favicon 用 16/32/48，Windows 桌面最大 256
    static let icoSizes = [16, 32, 48, 64, 128, 256]
    /// ICNS 常用尺寸：Finder 与 Dock 会按需取用，1024 对应 512@2x
    static let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// 图片转 ICO / ICNS：按 EXIF 方向摆正，等比缩放后居中放进透明正方形（不裁切、不拉伸），
    /// 一次写入多个尺寸，系统按显示大小自动挑选。
    /// - Throws: 读不出图片或写出失败时抛出 `ConversionError`。
    static func convertIcon(source: URL, ext: String, destination: URL,
                            progress: @escaping (Double) -> Void) throws {
        progress(0.05)
        let sizes = ext == "ico" ? icoSizes : icnsSizes
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.failed("无法读取图片")
        }
        // 按最大尺寸取一张已摆正方向的图，后面各尺寸都从它缩小
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sizes.max()!,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else {
            throw ConversionError.failed("无法读取图片")
        }
        let type = (ext == "ico" ? "com.microsoft.ico" : "com.apple.icns") as CFString
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type, sizes.count, nil) else {
            throw ConversionError.failed("系统不支持写出 \(ext.uppercased())")
        }
        for (index, size) in sizes.enumerated() {
            try ConversionCancellation.current?.check()
            guard let square = squareIcon(image, size: size) else {
                throw ConversionError.failed("生成 \(size)×\(size) 图标失败")
            }
            CGImageDestinationAddImage(output, square, nil)
            progress(0.05 + 0.85 * Double(index + 1) / Double(sizes.count))
        }
        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.failed("写出 \(ext.uppercased()) 失败")
        }
        progress(1)
    }

    private static func squareIcon(_ image: CGImage, size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        let scale = min(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2,
                                       width: width, height: height))
        return context.makeImage()
    }
}
