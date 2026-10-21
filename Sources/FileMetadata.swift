import Foundation
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 只记录从文件读到的值；缺失字段保持 nil，不把读取失败显示成 0。
struct FileMetadataSnapshot: Sendable {
    let url: URL
    var formatName: String
    var byteCount: Int64?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var pageCount: Int?
    var frameCount: Int?
    var isImage = false
    var isVideo = false
    var isAudio = false
    var isDirectory = false
    var isReadable = true
    /// ImageIO 的通道标记；nil 表示未读到，不能据此断言图片不透明。
    var hasAlpha: Bool? = nil

    var sizeText: String? {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    var resolutionText: String? {
        guard let width = pixelWidth, let height = pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    var durationText: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let seconds = Int(duration.rounded())
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        if duration < 1 { return String(format: "%.2f 秒", duration) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 用于列表的一行简介。完整精确字节数可在详情或帮助文本中展示。
    var summary: String {
        var parts = [formatName]
        if let resolutionText { parts.append("\(resolutionText) 像素") }
        if let durationText { parts.append(durationText) }
        if let pageCount { parts.append("\(pageCount) 页") }
        if let frameCount, frameCount > 1 { parts.append("\(frameCount) 帧") }
        if let sizeText { parts.append(sizeText) }
        if !isReadable { parts.append("无法读取") }
        return parts.joined(separator: " · ")
    }

    var exactSizeText: String? {
        guard let byteCount, let sizeText else { return nil }
        return "\(sizeText)（\(byteCount.formatted()) 字节）"
    }
}

private struct FileMetadataKey: Hashable, Sendable {
    let path: String
    let targetPath: String
    let byteCount: Int64?
    let modified: Date?
    let created: Date?
    let isDirectory: Bool
    let isReadable: Bool

    init(_ url: URL) {
        path = url.standardizedFileURL.path
        targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: targetPath)
        let directory = attributes?[.type] as? FileAttributeType == .typeDirectory
        isDirectory = directory
        byteCount = directory ? nil : (attributes?[.size] as? NSNumber)?.int64Value
        modified = attributes?[.modificationDate] as? Date
        created = attributes?[.creationDate] as? Date
        isReadable = attributes != nil && FileManager.default.isReadableFile(atPath: path)
    }
}

private actor FileMetadataCache {
    static let shared = FileMetadataCache()
    private var entries: [String: (key: FileMetadataKey, value: FileMetadataSnapshot)] = [:]
    private var order: [String] = []

    func lookup(_ key: FileMetadataKey) -> FileMetadataSnapshot? {
        guard let entry = entries[key.path], entry.key == key else { return nil }
        return entry.value
    }

    func insert(_ value: FileMetadataSnapshot, key: FileMetadataKey) {
        entries[key.path] = (key, value)
        order.removeAll { $0 == key.path }
        order.append(key.path)
        while order.count > 128 { entries.removeValue(forKey: order.removeFirst()) }
    }

    func invalidate(_ url: URL) {
        let path = url.standardizedFileURL.path
        entries.removeValue(forKey: path)
        order.removeAll { $0 == path }
    }
}

enum FileMetadataReader {
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "alac", "ogg", "opus", "wma"
    ]

    /// 文件属性、ImageIO/PDF 与 ffprobe 都在后台任务中执行，调用方可直接从主线程 await。
    /// 每次读取先检查大小与修改时间，文件原地覆盖后不会命中旧缓存。
    static func read(_ url: URL) async -> FileMetadataSnapshot {
        let source = url.standardizedFileURL
        let job = Task.detached(priority: .utility) { () -> FileMetadataSnapshot in
            let initialKey = FileMetadataKey(source)
            if !Task.isCancelled, let cached = await FileMetadataCache.shared.lookup(initialKey) {
                return cached
            }
            var key = initialKey
            var value = await inspect(source, key: key)
            let after = FileMetadataKey(source)
            if after != key, !Task.isCancelled {
                key = after
                value = await inspect(source, key: key)
            }
            if !Task.isCancelled, key == FileMetadataKey(source), key.isReadable {
                await FileMetadataCache.shared.insert(value, key: key)
            }
            return value
        }
        return await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
    }

    static func invalidate(_ url: URL) async {
        await FileMetadataCache.shared.invalidate(url)
    }

    private static func inspect(_ url: URL, key: FileMetadataKey) async -> FileMetadataSnapshot {
        let ext = url.pathExtension.lowercased()
        var value = FileMetadataSnapshot(url: url, formatName: formatName(url),
                                         byteCount: key.byteCount, isDirectory: key.isDirectory,
                                         isReadable: key.isReadable)
        if key.isDirectory { value.formatName = "文件夹"; return value }
        guard key.isReadable, !Task.isCancelled else { return value }

        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true || FormatCatalog.kind(of: url) == .image {
            value.isImage = true
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            if let image = CGImageSourceCreateWithURL(url as CFURL, options) {
                if let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, options) as? [CFString: Any] {
                    value.hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue
                }
                if let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, options) as? [CFString: Any],
                   let width = positiveInt(properties[kCGImagePropertyPixelWidth]),
                   let height = positiveInt(properties[kCGImagePropertyPixelHeight]) {
                    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                    let rotates = (5...8).contains(orientation)
                    value.pixelWidth = rotates ? height : width
                    value.pixelHeight = rotates ? width : height
                }
                let count = CGImageSourceGetCount(image)
                if count > 1 { value.frameCount = count }
            }
        } else if ext == "pdf" {
            if let document = PDFDocument(url: url), document.pageCount > 0 {
                value.pageCount = document.pageCount
            }
        } else if type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true ||
                    FormatCatalog.kind(of: url) == .media {
            let audioOnly = type?.conforms(to: .audio) == true || audioExtensions.contains(ext)
            let asset = AVURLAsset(url: url)
            let nativeDuration = try? await asset.load(.duration).seconds
            value.duration = validDuration(nativeDuration)
            guard !Task.isCancelled else { return value }
            if !audioOnly, let track = try? await asset.loadTracks(withMediaType: .video).first {
                value.isVideo = true
                if let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    if rect.width.isFinite, rect.height.isFinite, abs(rect.width) > 0, abs(rect.height) > 0 {
                        value.pixelWidth = Int(abs(rect.width).rounded())
                        value.pixelHeight = Int(abs(rect.height).rounded())
                    }
                }
            }
            if !value.isVideo { value.isAudio = (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false }
            guard !Task.isCancelled else { return value }
            if value.duration == nil || (!value.isVideo && !value.isAudio) || (value.isVideo && value.pixelWidth == nil) {
                applyProbe(url, to: &value, audioOnly: audioOnly)
            }
        }
        return value
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.intValue > 0 else { return nil }
        return number.intValue
    }

    private static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < Double(Int.max / 2) else { return nil }
        return value
    }

    private static func formatName(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        case "webp": return "WebP"
        case "aif", "aiff": return "AIFF"
        case "": return "文件"
        default: return url.pathExtension.uppercased()
        }
    }

    /// 仅询问容器/流头信息，不读取所有帧、不解压内容。
    private static func applyProbe(_ url: URL, to value: inout FileMetadataSnapshot, audioOnly: Bool) {
        guard let executable = Shell.which("ffprobe"), !Task.isCancelled,
              let result = try? Shell.run(executable, ["-v", "error", "-show_entries",
                  "format=duration:stream=codec_type,width,height,duration:stream_tags=rotate:stream_side_data=rotation:stream_disposition=attached_pic",
                  "-of", "json", url.path], captureOutput: true, timeout: 5), result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func number(_ raw: Any?) -> Double? {
            if let n = raw as? NSNumber { return n.doubleValue }
            return (raw as? String).flatMap(Double.init)
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        if value.duration == nil {
            let format = json["format"] as? [String: Any]
            value.duration = validDuration(number(format?["duration"])) ??
                streams.compactMap { validDuration(number($0["duration"])) }.max()
        }
        if !audioOnly, let video = streams.first(where: {
            $0["codec_type"] as? String == "video" &&
                (($0["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.boolValue != true
        }) {
            value.isVideo = true
            value.isAudio = false
            if value.pixelWidth == nil,
               let width = positiveInt(video["width"]), let height = positiveInt(video["height"]) {
                let tags = video["tags"] as? [String: Any]
                let sideData = video["side_data_list"] as? [[String: Any]] ?? []
                let rotation = sideData.compactMap { number($0["rotation"]) }.first ?? number(tags?["rotate"]) ?? 0
                let angle = rotation.isFinite ? rotation.truncatingRemainder(dividingBy: 360) * .pi / 180 : 0
                value.pixelWidth = Int((abs(Double(width) * cos(angle)) + abs(Double(height) * sin(angle))).rounded())
                value.pixelHeight = Int((abs(Double(width) * sin(angle)) + abs(Double(height) * cos(angle))).rounded())
            }
        } else if streams.contains(where: { $0["codec_type"] as? String == "audio" }) {
            value.isAudio = true
        }
    }
}
