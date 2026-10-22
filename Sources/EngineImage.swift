import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

extension Engine {
    // MARK: 图片

    static func convertImage(source: URL,
                                     ext: String,
                                     destination: URL,
                                     stripMetadata: Bool,
                                     options: CompressionOptions,
                                     progress: @escaping (Double) -> Void) throws {
        progress(0.05)

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionError.failed("无法读取图片：\(source.lastPathComponent)")
        }

        if ext == "webp" {
            guard let cwebp = Shell.which("cwebp") else {
                throw ConversionError.toolMissing("需要 cwebp 才能输出 WebP（brew install webp）")
            }
            let temp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("totori-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temp) }
            // cwebp 不读 PNG 里的 EXIF 方向标记，必须先把方向烘焙进像素，否则竖拍照片会横过来。
            let working = downscaled(imageSource, maxSide: options.maxSide)
                ?? orientationBaked(imageSource) ?? imageSource
            try ConversionCancellation.current?.check()
            try writeImage(imageSource: working, to: temp, type: .png,
                           quality: 1.0, flattened: stripMetadata)
            progress(0.4)
            let quality = String(Int(min(1, max(0, options.jpegQuality)) * 100))
            let result = try Shell.run(cwebp, ["-quiet", "-q", quality, "-mt", "-o", destination.path, temp.path])
            guard result.status == 0 else {
                throw ConversionError.failed("WebP 编码失败：\(result.stderr.suffix(300))")
            }
            progress(1.0)
            return
        }

        let type: UTType
        switch ext {
        case "pdf":  type = .pdf
        case "jpg", "jpeg": type = .jpeg
        case "heic": type = .heic
        case "tiff": type = .tiff
        // 这些格式 ImageIO 都能直接写出，和 PNG/JPEG 走同一条管线，才会遵守
        // 「清除元数据」「缩边」选项并烘焙 EXIF 方向（旧的 sips 分支全都忽略，
        // 且 sips 在新系统上写不出 JP2、AVIF 会丢失方向）。
        case "avif": type = UTType("public.avif") ?? .png
        case "bmp":  type = .bmp
        case "gif":  type = .gif
        case "jp2":  type = UTType("public.jpeg-2000") ?? .png
        default:     type = UTType(filenameExtension: ext) ?? .png
        }

        // AVIF 不保留 EXIF 方向标记、JP2 编码器不接受“从数据源直接复制”，
        // 这两种格式先烘焙方向，再写入解码后的像素。
        let pixelOnly = ["avif", "jp2"].contains(ext)
        let working = downscaled(imageSource, maxSide: options.maxSide)
            ?? (pixelOnly ? orientationBaked(imageSource) : nil) ?? imageSource
        try ConversionCancellation.current?.check()
        try writeImage(imageSource: working, to: destination, type: type,
                       quality: options.jpegQuality, flattened: stripMetadata,
                       decodedPixels: pixelOnly)
        progress(1.0)
    }

    /// EXIF 方向不是 1 时，返回方向已转正、像素尺寸不变的数据源；无需处理时返回 nil。
    static func orientationBaked(_ source: CGImageSource) -> CGImageSource? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation != 1,
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return downscaled(source, maxSide: CGFloat(max(width, height)))
    }

    /// 需要缩边时，先做一份缩略图数据源，后续流程不变
    static func downscaled(_ source: CGImageSource, maxSide: CGFloat?) -> CGImageSource? {
        guard let maxSide, maxSide > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return CGImageSourceCreateWithData(data, nil)
    }

    static func writeImage(imageSource: CGImageSource,
                                   to url: URL,
                                   type: UTType,
                                   quality: Double,
                                   flattened: Bool,
                                   decodedPixels: Bool = false) throws {
        try ConversionCancellation.current?.check()
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, CGImageSourceGetCount(imageSource), nil
        ) else {
            throw ConversionError.failed("不支持输出为 \(type.identifier)")
        }
        if flattened, let clean = flattenedImage(imageSource) {
            CGImageDestinationAddImage(destination, clean, options as CFDictionary)
        } else if decodedPixels, let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        } else {
            let count = type == .pdf ? 1 : CGImageSourceGetCount(imageSource)
            for index in 0..<count {
                try ConversionCancellation.current?.check()
                CGImageDestinationAddImageFromSource(destination, imageSource, index, options as CFDictionary)
            }
        }
        try ConversionCancellation.current?.check()
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("写出失败：\(url.lastPathComponent)")
        }
    }

    /// 重绘一遍像素，丢掉 EXIF/GPS 等元数据
    static func flattenedImage(_ source: CGImageSource) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // 清元数据前先把 EXIF 方向/镜像烘焙进像素，否则竖图会被"抹平"成横图
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1

        var pixels = image
        if orientation != 1 {
            let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
            guard let baked = CIContext(options: nil).createCGImage(oriented, from: oriented.extent) else {
                return nil
            }
            pixels = baked
        }

        let width = pixels.width, height = pixels.height
        // 沿用原图色彩空间重绘，否则 Display P3 等广色域照片会被压成设备 RGB、颜色变淡；
        // 灰度/CMYK 等不能直接做 RGBA 画布的空间，退回 sRGB 并由 CoreGraphics 做色彩匹配。
        let source = pixels.colorSpace
        let usable = source.flatMap { $0.model == .rgb ? $0 : nil }
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // 源图超过 8 位（16-bit PNG/TIFF、浮点 HDR）时用 16 位画布，否则渐变会出现色带；
        // 浮点源也落到 16 位整数，能保留的精度比 8 位多得多，且各输出格式都可写。
        let depth = pixels.bitsPerComponent > 8 ? 16 : 8
        func makeContext(space: CGColorSpace, bits: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height,
                      bitsPerComponent: bits, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = makeContext(space: usable ?? fallback, bits: depth)
            ?? makeContext(space: fallback, bits: depth)
            ?? makeContext(space: fallback, bits: 8) else { return nil }
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

}
