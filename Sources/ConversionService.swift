import Foundation

/// 主窗口与滚轮共用的转换出口。
///
/// 按引擎分三条串行队列：图片/压缩包、音视频（ffmpeg）、文档（LibreOffice）。
/// 同类任务仍排队，避免同时跑多个 ffmpeg 或 LibreOffice 抢占资源；
/// 不同类任务互不等待，一个长视频不会再卡住后面的图片转换（见基准）。
/// 同名避让不再靠整体串行保证，而是在 `Engine.convert` 发布输出时原子占用文件名。
enum ConversionService {
    private static let imageQueue = DispatchQueue(label: "totori.conversion-service.image", qos: .userInitiated)
    private static let mediaQueue = DispatchQueue(label: "totori.conversion-service.media", qos: .userInitiated)
    /// 文档队列也用于整批文档的预转换，保证同一时刻只有一个 LibreOffice 在工作。
    static let queue = DispatchQueue(label: "totori.conversion-service.document", qos: .userInitiated)

    private static func queue(for source: URL) -> DispatchQueue {
        switch FormatCatalog.kind(of: source) {
        case .media:    return mediaQueue
        case .document: return queue
        default:        return imageQueue
        }
    }

    static func convert(source: URL, format: OutputFormat, to directory: URL,
                        stripMetadata: Bool = false,
                        options: CompressionOptions = .none,
                        cancellation: ConversionCancellation? = nil,
                        progress: @escaping (Double) -> Void) throws -> URL {
        try cancellation?.check()
        return try queue(for: source).sync {
            // 等待队列时也可能已取消，不能在取得执行权后继续写出。
            try cancellation?.check()
            return try Engine.convert(source: source, format: format, to: directory,
                               stripMetadata: stripMetadata, options: options,
                               cancellation: cancellation, progress: progress)
        }
    }

    struct CompressionResult {
        let output: URL?
        let sourceBytes: Int64
        let encodedBytes: Int64
        var savedBytes: Int64 { output == nil ? 0 : max(0, sourceBytes - encodedBytes) }
    }

    /// 没有收益也属于有效结果；只移除本次生成的副本，原件不变。
    static func compress(source: URL, format: OutputFormat, options: CompressionOptions,
                         cancellation: ConversionCancellation? = nil,
                         progress: @escaping (Double) -> Void) throws -> CompressionResult {
        try cancellation?.check()
        return try queue(for: source).sync {
            try cancellation?.check()
            let before = try byteCount(source)
            let output = try Engine.convert(source: source, format: format,
                                            to: source.deletingLastPathComponent(),
                                            options: options, cancellation: cancellation,
                                            progress: progress)
            let after = try byteCount(output)
            guard after < before else {
                try FileManager.default.removeItem(at: output)
                return CompressionResult(output: nil, sourceBytes: before, encodedBytes: after)
            }
            return CompressionResult(output: output, sourceBytes: before, encodedBytes: after)
        }
    }

    private static func byteCount(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ConversionError.failed("读不到文件大小：\(url.lastPathComponent)")
        }
        return size.int64Value
    }
}
