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
        if FormatCatalog.kind(of: source) == .archive, format.ext == "zip" {
            destination = wrappedZipDestination(for: source, in: directory)
        } else if FormatCatalog.kind(of: source) == .archive {
            // 解压出文件夹、重新打包：都以去掉压缩扩展名后的名字命名（x.tar.gz → x）
            let base = archiveBaseName(source)
            destination = directory.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
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
            // 逐页图片可能产出一个文件夹（多页时），发布时换成文件夹名
            var produced = pending
            var target = destination
            // ImageIO/CoreImage 等同步系统调用只能在调用前后协作停止。
            // 子进程则继承本线程 token，取消时终止本次 Process。
            switch FormatCatalog.kind(of: source) {
            case .image where FormatCatalog.animatedOnlyImageExts.contains(ext):
                // 动图转视频交给 ffmpeg，参数与视频转 MP4/WebM 相同
                guard let media = FormatCatalog.medias.first(where: { $0.ext == ext }) else {
                    throw ConversionError.unsupported("暂不支持输出为 \(format.name)")
                }
                try convertMedia(source: input, format: media, destination: pending, options: options, progress: progress)
            case .image where FormatCatalog.iconExts.contains(ext):
                try convertIcon(source: input, ext: ext, destination: pending, progress: progress)
            case .image:
                try convertImage(source: input, ext: ext, destination: pending,
                                 stripMetadata: stripMetadata, options: options, progress: progress)
            case .document where FormatCatalog.pageImageExts.contains(ext):
                let folderName = pageFolderName(for: source, ext: ext)
                produced = try convertToPageImages(source: input, ext: ext, file: pending,
                                                   folder: staging.appendingPathComponent(folderName, isDirectory: true),
                                                   pageBaseName: source.deletingPathExtension().lastPathComponent,
                                                   layout: options.spreadsheetPDFLayout, progress: progress)
                if produced != pending { target = directory.appendingPathComponent(folderName, isDirectory: true) }
            case .document where usesPDFRenderer(source: input, ext: ext):
                try convertPDF(source: input, ext: ext, destination: pending,
                               pageBaseName: source.deletingPathExtension().lastPathComponent, progress: progress)
            case .document:
                try convertDocument(source: input, ext: ext, destination: pending,
                                    layout: options.spreadsheetPDFLayout, progress: progress)
            case .media:
                try convertMedia(source: input, format: format, destination: pending,
                                 options: options, progress: progress)
            case .archive where format.ext == "zip":
                try convertArchive(source: source, destination: pending, progress: progress)
            case .archive:
                produced = try convertArchiveContents(source: source, formatExt: format.ext,
                                                      destination: pending, progress: progress)
                // 单个压缩文件（如 notes.txt.gz）解出来是文件，按文件发布
                if produced != pending { target = directory.appendingPathComponent(produced.lastPathComponent) }
            case .unknown:
                throw ConversionError.unsupported("无法识别的文件类型：\(source.pathExtension)")
            }
            try cancellation?.check()
            // 发布后即为完成的文件；后到的取消保留这一结果，在下个文件前停止。
            return try publish(produced, as: target)
        }
    }

    static let publishLock = NSLock()

    /// 原子占用最终文件名并移入：不同队列的转换可能同时完成，选名与移动必须在同一把锁内，
    /// 否则两个同名任务会选到同一个名字；名字已被占用时依次尝试 "名字 2.扩展名"、"名字 3.扩展名"……
    static func publish(_ pending: URL, as preferred: URL) throws -> URL {
        publishLock.lock()
        defer { publishLock.unlock() }
        var target = preferred
        // 文件夹（多页 PDF 的逐页图片）整个名字都是主名，不能把名字里的“.”当扩展名切开
        var isDirectory: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: pending.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let base = folder ? preferred.lastPathComponent : preferred.deletingPathExtension().lastPathComponent
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = preferred.deletingLastPathComponent().appendingPathComponent("\(base) \(index)")
            if !folder { target = target.appendingPathExtension(preferred.pathExtension) }
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
