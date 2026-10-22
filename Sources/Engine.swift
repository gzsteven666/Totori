import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

// MARK: - 转换引擎

enum Engine {

    /// 计算最终输出路径，自动避让同名文件。
    static func destinationURL(for source: URL, ext: String, in directory: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// 执行一次转换，返回输出文件 URL。
    static func convert(source: URL,
                        format: OutputFormat,
                        to directory: URL,
                        stripMetadata: Bool = false,
                        options: CompressionOptions = .none,
                        cancellation: ConversionCancellation? = nil,
                        progress: @escaping (Double) -> Void) throws -> URL {
        let cancellation = cancellation ?? ConversionCancellation.current
        try cancellation?.check()
        let ext = FormatCatalog.actualExtension(for: format, source: source)
        // 压缩包转 ZIP 是「外层打包」，文件名保留原扩展名，避免被当成重新压缩
        let destination: URL
        if FormatCatalog.kind(of: source) == .archive, ext == "zip" {
            destination = wrappedZipDestination(for: source, in: directory)
        } else {
            destination = destinationURL(for: source, ext: ext, in: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cancellation?.check()
        let staging = directory.appendingPathComponent(".totori-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let pending = staging.appendingPathComponent(destination.lastPathComponent)

        // 没有扩展名（或扩展名不认识）的文件按文件头识别过类型；LibreOffice 等引擎仍要靠扩展名判断，
        // 所以在暂存目录里放一个带正确扩展名的符号链接当输入。输出名仍沿用原文件名。
        var input = source
        let detected = FormatCatalog.effectiveExtension(of: source)
        if FormatCatalog.kind(of: source) != .archive, FormatCatalog.kind(of: source) != .unknown,
           source.pathExtension.lowercased() != detected {
            let link = staging.appendingPathComponent("input.\(detected)")
            if (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)) != nil {
                input = link
            }
        }

        return try ConversionCancellation.withCurrent(cancellation) {
            try cancellation?.check()
            // ImageIO/CoreImage 等同步系统调用只能在调用前后协作停止。
            // 子进程则继承本线程 token，取消时终止本次 Process。
            switch FormatCatalog.kind(of: source) {
            case .image:
                try convertImage(source: input, ext: ext, destination: pending,
                                 stripMetadata: stripMetadata, options: options, progress: progress)
            case .document:
                try convertDocument(source: input, ext: ext, destination: pending,
                                    layout: options.spreadsheetPDFLayout, progress: progress)
            case .media:
                try convertMedia(source: input, format: format, destination: pending,
                                 options: options, progress: progress)
            case .archive:
                try convertArchive(source: source, destination: pending, progress: progress)
            case .unknown:
                throw ConversionError.unsupported("无法识别的文件类型：\(source.pathExtension)")
            }
            try cancellation?.check()
            // 发布后即为完成的文件；后到的取消保留这一结果，在下个文件前停止。
            return try publish(pending, as: destination)
        }
    }

    static let publishLock = NSLock()

    /// 原子占用最终文件名并移入：不同队列的转换可能同时完成，选名与移动必须在同一把锁内，
    /// 否则两个同名任务会选到同一个名字；名字已被占用时依次尝试 "名字 2.扩展名"、"名字 3.扩展名"……
    static func publish(_ pending: URL, as preferred: URL) throws -> URL {
        publishLock.lock()
        defer { publishLock.unlock() }
        var target = preferred
        let base = preferred.deletingPathExtension().lastPathComponent
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = preferred.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(index)").appendingPathExtension(preferred.pathExtension)
            index += 1
        }
        try FileManager.default.moveItem(at: pending, to: target)
        return target
    }

    /// 06-归档.tar → 06-归档.tar.zip
    static func wrappedZipDestination(for source: URL, in directory: URL) -> URL {
        let base = source.lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).zip")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).zip")
            index += 1
        }
        return candidate
    }

    // MARK: 压缩包

    static func convertArchive(source: URL,
                                       destination: URL,
                                       progress: @escaping (Double) -> Void) throws {
        progress(0.05)
        guard let ditto = Shell.which("ditto") else {
            throw ConversionError.toolMissing("系统缺少 ditto")
        }
        let result = try Shell.run(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                           source.path, destination.path])
        guard result.status == 0 else {
            throw ConversionError.failed("打包失败：\(result.stderr.suffix(200))")
        }
        progress(1.0)
    }

    // MARK: 工具

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
