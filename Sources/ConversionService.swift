import Foundation

/// 主窗口与滚轮共用串行出口，包含同名避让到写出完成的整个区间。
enum ConversionService {
    static let queue = DispatchQueue(label: "totori.conversion-service", qos: .userInitiated)

    static func convert(source: URL, format: OutputFormat, to directory: URL,
                        stripMetadata: Bool = false,
                        options: CompressionOptions = .none,
                        cancellation: ConversionCancellation? = nil,
                        progress: @escaping (Double) -> Void) throws -> URL {
        try cancellation?.check()
        return try queue.sync {
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
        return try queue.sync {
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
