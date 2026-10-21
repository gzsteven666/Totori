import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 成功结果由任务提供；这里按图片类型筛选，保持原有顺序而不触碰文件。
/// 不因文件后来移动而删掉一项：窗口会给出读取失败说明，仍能继续翻页。
enum ComparisonBatch {
    static func isImage(_ url: URL) -> Bool {
        FormatCatalog.kind(of: url) == .image || UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true
    }

    static func isImagePair(_ pair: OutputComparison) -> Bool {
        isImage(pair.source) && isImage(pair.output)
    }

    static func imagePairs(_ pairs: [OutputComparison]) -> [OutputComparison] {
        struct Key: Hashable { let source: URL; let output: URL }
        var seen: Set<Key> = []
        return pairs.filter { pair in
            guard isImagePair(pair) else { return false }
            let key = Key(source: pair.source.standardizedFileURL, output: pair.output.standardizedFileURL)
            return seen.insert(key).inserted
        }
    }
}

/// 每次只交付同一组的完整快照；调用者以请求令牌决定是否接收。
struct ComparisonPairPreview: @unchecked Sendable {
    let sourceMetadata: FileMetadataSnapshot
    let outputMetadata: FileMetadataSnapshot
    let sourceImage: CGImage?
    let outputImage: CGImage?
    static let maximumSide = 4096

    static func read(_ source: URL, _ output: URL) async -> ComparisonPairPreview {
        async let left = FileMetadataReader.read(source)
        async let right = FileMetadataReader.read(output)
        let metadata = await (left, right)
        guard !Task.isCancelled, metadata.0.isImage, metadata.1.isImage else {
            return ComparisonPairPreview(sourceMetadata: metadata.0, outputMetadata: metadata.1,
                                         sourceImage: nil, outputImage: nil)
        }
        let bitmaps = Task.detached(priority: .userInitiated) {
            let first = loadBitmap(source)
            let second = loadBitmap(output)
            return (first, second)
        }
        let images = await withTaskCancellationHandler(operation: { await bitmaps.value },
                                                       onCancel: { bitmaps.cancel() })
        return ComparisonPairPreview(sourceMetadata: metadata.0, outputMetadata: metadata.1,
                                     sourceImage: images.0, outputImage: images.1)
    }

    private static func loadBitmap(_ url: URL) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        return thumbnail
    }
}
