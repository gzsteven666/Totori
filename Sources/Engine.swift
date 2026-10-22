import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

// MARK: - 错误

enum ConversionError: LocalizedError {
    case unsupported(String)
    case toolMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let m): return m
        case .toolMissing(let m): return m
        case .failed(let m):      return m
        }
    }
}

// MARK: - 子进程

enum Shell {
    /// Process 的启动、停止与收尾共用一把锁；定时回调不会作用于后续任务。
    private final class ProcessControl: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var started = false
        private var finished = false
        private var cancelled = false
        private var didTimeOut = false
        private var timeoutWork: DispatchWorkItem?
        private var killWork: DispatchWorkItem?

        init(_ process: Process) { self.process = process }

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
            started = true
        }

        func cancel() { stop(isTimeout: false) }

        private var lastActivity = Date()
        private var idleWork: DispatchWorkItem?

        /// 记录一次"有进展"，长任务据此区分仍在工作与已卡死。
        func touch() {
            lock.lock()
            lastActivity = Date()
            lock.unlock()
        }

        /// 连续 `interval` 秒没有 touch 才终止进程；只要持续有进展，总耗时不设上限。
        func scheduleIdleTimeout(_ interval: TimeInterval) {
            guard interval > 0 else { return }
            lock.lock()
            lastActivity = Date()
            lock.unlock()
            armIdleCheck(after: interval, interval: interval)
        }

        private func armIdleCheck(after delay: TimeInterval, interval: TimeInterval) {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let remaining = interval - Date().timeIntervalSince(self.lastActivity)
                let done = self.finished
                self.lock.unlock()
                if done { return }
                if remaining <= 0 { self.stop(isTimeout: true) }
                else { self.armIdleCheck(after: remaining, interval: interval) }
            }
            lock.lock()
            guard !finished else { lock.unlock(); return }
            idleWork = work
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        }

        func scheduleTimeout(_ interval: TimeInterval) {
            guard interval > 0 else { return }
            let work = DispatchWorkItem { [weak self] in self?.stop(isTimeout: true) }
            lock.lock()
            guard !finished else { lock.unlock(); return }
            timeoutWork = work
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: work)
        }

        private func stop(isTimeout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            if isTimeout {
                guard started, process.isRunning else { return }
                didTimeOut = true
            } else {
                cancelled = true
            }
            guard started, process.isRunning, killWork == nil else { return }
            process.terminate()
            let work = DispatchWorkItem { [weak self] in self?.forceStop() }
            killWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        private func forceStop() {
            lock.lock()
            defer { lock.unlock() }
            guard started, !finished, process.isRunning else { return }
            // 只回收这一只 Process，绝不按名称或进程组终止其他任务。
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            timeoutWork?.cancel()
            idleWork?.cancel()
            killWork?.cancel()
            return didTimeOut
        }
    }

    /// 分发版优先使用包内运行时；缺失时报告错误，避免悄悄依赖开发机的 Homebrew。
    static func which(_ name: String) -> String? {
        let app = Bundle.main.bundleURL
        let portable = FileManager.default.fileExists(atPath:
            app.appendingPathComponent("Contents/Resources/RuntimeManifest.json").path)
        if ["ffmpeg", "ffprobe", "cwebp", "soffice"].contains(name) {
            let relative = name == "soffice"
                ? "Contents/Frameworks/LibreOffice.app/Contents/MacOS/soffice"
                : "Contents/Helpers/\(name)"
            let bundled = app.appendingPathComponent(relative).path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
            if portable { return nil }
        }
        var dirs = portable ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            : ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
        if !portable, let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    stdoutTo file: URL? = nil,
                    captureOutput: Bool = false,
                    timeout: TimeInterval = 0,
                    idleTimeout: TimeInterval = 0,
                    isProgress: ((String) -> Bool)? = nil,
                    currentDirectory: URL? = nil,
                    cancellation: ConversionCancellation? = nil,
                    onStdoutLine: ((String) -> Void)? = nil) throws -> Result {
        let cancellation = cancellation ?? ConversionCancellation.current
        try cancellation?.check()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        if URL(fileURLWithPath: executable).lastPathComponent == "soffice" {
            // 禁止文档引擎在已签名的包内重写 Python 字节码缓存，保持搬移后签名有效。
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            guard let fonts = Bundle.main.url(forResource: "fonts", withExtension: "conf") else {
                throw ConversionError.failed("文档引擎缺少字体配置，请重新安装 Totori")
            }
            environment["FONTCONFIG_FILE"] = fonts.path
        }
        process.environment = environment
        let control = ProcessControl(process)

        let errPipe = Pipe()
        process.standardError = errPipe

        var outHandle: FileHandle?
        var stdoutCollector: (() -> String)?
        // 专用读线程一直读到 EOF，进程退出后再汇合，保证不丢尾部输出；
        // 按字节切行后再解码，多字节字符不会因分块被切坏。
        let readers = DispatchGroup()
        func drain(_ handle: FileHandle, _ onData: @escaping (Data) -> Void, onEnd: @escaping () -> Void = {}) {
            readers.enter()
            DispatchQueue.global().async {
                // read(2) 有多少返回多少；FileHandle.read(upToCount:) 会攒满再返回，进度行会被延迟。
                let fd = handle.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n > 0 { onData(Data(buffer[0..<n])) }
                    else if n < 0 && errno == EINTR { continue }
                    else { break }
                }
                onEnd()
                readers.leave()
            }
        }
        if let file {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            outHandle = handle
            process.standardOutput = handle
        } else if onStdoutLine != nil || captureOutput || idleTimeout > 0 {
            // 空闲超时靠 stdout 活动判断进展，所以也需要接管输出管道。
            let outPipe = Pipe()
            process.standardOutput = outPipe
            let lock = NSLock()
            var pending = Data()
            var collected = Data()
            func emit(_ lineData: Data) {
                let line = String(decoding: lineData, as: UTF8.self)
                if isProgress?(line) ?? true { control.touch() }
                onStdoutLine?(line)
            }
            drain(outPipe.fileHandleForReading, { data in
                lock.lock()
                collected.append(data)
                pending.append(data)
                var lines: [Data] = []
                while let idx = pending.firstIndex(of: 0x0A) {
                    lines.append(pending.subdata(in: pending.startIndex..<idx))
                    pending.removeSubrange(pending.startIndex...idx)
                }
                lock.unlock()
                lines.forEach(emit)
            }, onEnd: {
                lock.lock()
                let rest = pending
                pending = Data()
                lock.unlock()
                if !rest.isEmpty { emit(rest) }
            })
            stdoutCollector = {
                lock.lock(); defer { lock.unlock() }
                return String(decoding: collected, as: UTF8.self)
            }
        }

        let errLock = NSLock()
        var errData = Data()
        drain(errPipe.fileHandleForReading) { data in
            errLock.lock()
            errData.append(data)
            if errData.count > 64_000 { errData = errData.suffix(32_000) }
            errLock.unlock()
        }

        let registration = cancellation?.registerProcess { control.cancel() }
        defer {
            cancellation?.unregisterProcess(registration)
            _ = control.finish()
            outHandle?.closeFile()
        }
        try control.start()
        // 单文件上限保留；退出后取消超时工作，避免旧计时器误报。
        control.scheduleTimeout(timeout)
        control.scheduleIdleTimeout(idleTimeout)
        process.waitUntilExit()
        let timedOut = control.finish()
        try cancellation?.check()
        // 子进程若留下继续持有管道的孙进程，EOF 可能迟迟不来；最多再等 2 秒，不无限挂起。
        _ = readers.wait(timeout: .now() + 2)

        errLock.lock()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        errLock.unlock()

        let outText = stdoutCollector?() ?? ""

        return Result(status: process.terminationStatus, stdout: outText,
                      stderr: errText, timedOut: timedOut)
    }
}

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
            try FileManager.default.moveItem(at: pending, to: destination)
            return destination
        }
    }

    /// 06-归档.tar → 06-归档.tar.zip
    private static func wrappedZipDestination(for source: URL, in directory: URL) -> URL {
        let base = source.lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).zip")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).zip")
            index += 1
        }
        return candidate
    }

    // MARK: 图片

    private static func convertImage(source: URL,
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
                .appendingPathComponent("tangerine-\(UUID().uuidString).png")
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
    private static func orientationBaked(_ source: CGImageSource) -> CGImageSource? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation != 1,
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return downscaled(source, maxSide: CGFloat(max(width, height)))
    }

    /// 需要缩边时，先做一份缩略图数据源，后续流程不变
    private static func downscaled(_ source: CGImageSource, maxSide: CGFloat?) -> CGImageSource? {
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

    private static func writeImage(imageSource: CGImageSource,
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
    private static func flattenedImage(_ source: CGImageSource) -> CGImage? {
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

    // MARK: 文档

    /// 走 LibreOffice 的格式过滤器名
    static func libreOfficeFilter(for ext: String) -> String {
        switch ext {
        case "pdf":  return "pdf"
        case "html": return "html"
        case "txt":  return "txt:Text"
        case "rtf":  return "rtf"
        case "docx": return "docx:MS Word 2007 XML"
        case "odt":  return "odt"
        case "epub": return "epub"
        case "md", "markdown": return "md:Markdown"
        default:     return ext
        }
    }

    /// 分发版只用包内 LibreOffice；开发构建可退回 /Applications 里的安装。
    static func resolveSoffice() -> String? {
        if let bundled = Shell.which("soffice") { return bundled }
        let portable = FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/RuntimeManifest.json").path)
        let system = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return !portable && FileManager.default.isExecutableFile(atPath: system) ? system : nil
    }

    private static func convertDocument(source: URL,
                                        ext: String,
                                        destination: URL,
                                        layout: SpreadsheetPDFLayout,
                                        progress: @escaping (Double) -> Void) throws {
        progress(0.05)

        // 1) 优先 LibreOffice：Office/ODF/Pages/EPUB 都能吃，排版最接近原版
        if let soffice = resolveSoffice() {
            if try libreOfficeConvert(soffice: soffice,
                                      source: source,
                                      filter: source.pathExtension.lowercased() == "svg"
                                          ? nil : libreOfficeFilter(for: ext),
                                      destination: destination,
                                      layout: layout,
                                      progress: progress) {
                return
            }
            progress(0.4)
        }

        // 2) PDF：退回 cupsfilter（纯文本/RTF/HTML 效果可接受）
        if ext == "pdf" {
            guard let cupsfilter = Shell.which("cupsfilter") else {
                throw ConversionError.toolMissing("系统缺少 cupsfilter，无法生成 PDF")
            }
            let result = try Shell.run(cupsfilter, ["-m", "application/pdf", source.path], stdoutTo: destination)
            if result.status != 0 || fileSize(destination) < 100 {
                try? FileManager.default.removeItem(at: destination)
                throw ConversionError.failed("PDF 生成失败：该格式需要 LibreOffice 支持")
            }
            progress(1.0)
            return
        }

        // 3) 纯文本类：textutil 兜底
        guard let textutil = Shell.which("textutil") else {
            throw ConversionError.toolMissing("系统缺少 textutil")
        }
        let convertName: String
        switch ext {
        case "docx": convertName = "docx"
        case "rtf":  convertName = "rtf"
        case "html": convertName = "html"
        case "odt":  convertName = "odt"
        case "txt":  convertName = "txt"
        default:     convertName = ext
        }

        let result = try Shell.run(textutil, ["-convert", convertName, "-output", destination.path, source.path])
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw ConversionError.failed("文档转换失败：\(result.stderr.suffix(300))")
        }
        progress(1.0)
    }

    /// 调 LibreOffice headless；成功写出 destination 返回 true。
    private static func libreOfficeConvert(soffice: String,
                                           source: URL,
                                           filter: String?,
                                           destination: URL,
                                           layout: SpreadsheetPDFLayout = .original,
                                           progress: @escaping (Double) -> Void) throws -> Bool {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xiaoju-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var input = source
        if layout == .fitWidth, destination.pathExtension.lowercased() == "pdf",
           SpreadsheetPDFLayout.supports(source) {
            if source.pathExtension.lowercased() == "xls" {
                let intermediate = staging.appendingPathComponent("intermediate.xlsx")
                guard try libreOfficeConvert(soffice: soffice, source: source,
                    filter: "xlsx:Calc MS Excel 2007 XML", destination: intermediate,
                    progress: { _ in }) else {
                    throw ConversionError.failed("无法为此 Excel 创建页宽适配副本")
                }
                input = intermediate
            }
            input = try SpreadsheetPDFLayout.fitWidthCopy(of: input, in: staging)
        }

        /// 用指定配置目录跑一次转换；成功写出 destination 返回 true。
        func attempt(profile: URL) throws -> Bool {
            let args = [
                "--headless", "--norestore", "--nolockcheck", "--nodefault",
                "-env:UserInstallation=\(profile.absoluteString)",
                "--convert-to", filter ?? destination.pathExtension,
                "--outdir", staging.path,
                input.path,
            ]
            do {
                _ = try Shell.run(soffice, args, timeout: 300)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 工具启动失败仍允许原有文档后端兜底；取消绝不走兜底。
            }
            try ConversionCancellation.current?.check()

            let produced = (try? FileManager.default.contentsOfDirectory(at: staging,
                                                                        includingPropertiesForKeys: nil))?
                .first { $0.pathExtension.lowercased() == destination.pathExtension.lowercased() }
            guard let produced, fileSize(produced) > 0 else { return false }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: produced, to: destination)
            return true
        }

        // 命中同批预转换的结果就直接取用，不再启动 LibreOffice。
        let fitsWidth = layout == .fitWidth && destination.pathExtension.lowercased() == "pdf"
            && SpreadsheetPDFLayout.supports(source)
        if !fitsWidth,
           let cached = DocumentPrefetch.take(source: source, ext: destination.pathExtension, filter: filter) {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: cached, to: destination)
            try? FileManager.default.removeItem(at: cached)
            progress(1.0)
            return true
        }

        if try withSharedProfile(fallback: staging.appendingPathComponent("profile", isDirectory: true),
                                 attempt) {
            progress(1.0)
            return true
        }
        return false
    }

    /// 优先复用 Totori 专用的配置目录：每次新建配置要多花约一半时间（见基准）。
    /// 它与用户自己的 LibreOffice 配置互不相干；同一时刻只允许一个转换占用，
    /// 占不到锁就退回一次性配置目录。`attempt` 成功产出文件返回 true。
    static func withSharedProfile(fallback: URL, _ attempt: (URL) throws -> Bool) throws -> Bool {
        guard sharedProfileLock.`try`() else { return try attempt(fallback) }
        defer { sharedProfileLock.unlock() }
        let existed = FileManager.default.fileExists(atPath: sharedProfile.path)
        try? FileManager.default.createDirectory(at: sharedProfile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if try attempt(sharedProfile) { return true }
        guard existed else { return false }
        // 复用的配置可能被上次被取消的进程弄坏：用干净配置再试一次，成功就丢弃旧配置。
        try? FileManager.default.removeItem(at: fallback)
        if try attempt(fallback) {
            try? FileManager.default.removeItem(at: sharedProfile)
            return true
        }
        return false
    }

    private static let sharedProfileLock = NSLock()

    /// 文档引擎的专用配置目录，放在 Application Support，不会影响用户自己的 LibreOffice。
    static var sharedProfile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Totori/lo-profile", isDirectory: true)
    }

    // MARK: 音视频

    /// ffmpeg 连续这么多秒没有推进输出时间，就判定卡死并中止。
    static let mediaStallTimeout: TimeInterval = 120

    private static func convertMedia(source: URL,
                                     format: OutputFormat,
                                     destination: URL,
                                     options: CompressionOptions,
                                     progress: @escaping (Double) -> Void) throws {
        guard let ffmpeg = Shell.which("ffmpeg") else {
            throw ConversionError.toolMissing("需要 ffmpeg（brew install ffmpeg）")
        }

        let info = try probeMedia(source)
        let duration = info.duration
        progress(0.02)

        var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path]
        // 显式映射：容器支持多音轨时保留全部音轨（默认只会带一条）。
        // V 排除封面图；末尾 ? 让源文件缺少对应流时不报错。
        switch format.ext {
        case "mp4", "mov", "mkv", "webm":
            args += ["-map", "0:V:0?", "-map", "0:a?"]
        case "avi", "wmv":
            args += ["-map", "0:V:0?", "-map", "0:a:0?"]
        default:
            break   // gif 与纯音频输出沿用 ffmpeg 的默认选流
        }

        switch format.ext {
        case "mp4":
            args += ["-c:v", "h264_videotoolbox", "-b:v", videoBitrate(options, probe: info, bitsPerPixel: 0.1, fallback: "6M"), "-c:a", "aac", "-b:a", "160k",
                     "-movflags", "+faststart"]
        case "mov":
            args += ["-c:v", "h264_videotoolbox", "-b:v", videoBitrate(options, probe: info, bitsPerPixel: 0.13, fallback: "8M"), "-c:a", "aac", "-b:a", "192k",
                     "-movflags", "+faststart"]
        case "mkv":
            args += ["-c:v", "libx264", "-preset", "veryfast",
                     "-crf", "\(options.videoCRF)", "-c:a", "aac", "-b:a", "160k"]
        case "avi":
            args += ["-c:v", "mpeg4", "-qscale:v", "4", "-c:a", "libmp3lame", "-b:a", "192k"]
        case "wmv":
            args += ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case "webm":
            args += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                     "-c:a", "libopus", "-b:a", "128k"]
        case "gif":
            args += ["-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                     "-loop", "0"]
        case "mp3":
            args += ["-vn", "-c:a", "libmp3lame", "-b:a", "192k"]
        case "m4a":
            args += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav":
            args += ["-vn", "-c:a", "pcm_s16le"]
        case "flac":
            args += ["-vn", "-c:a", "flac", "-compression_level", "5"]
        case "aiff":
            args += ["-vn", "-c:a", "pcm_s16be"]
        case "ogg", "opus":
            args += ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "wma":
            args += ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default:
            throw ConversionError.unsupported("暂不支持输出为 \(format.name)")
        }

        let subtitles = subtitleArguments(container: format.ext, codecs: try probeSubtitleCodecs(source))
        let tail = ["-progress", "pipe:1", "-nostats", destination.path]

        // 只要输出时间还在推进就一直等；ffmpeg 即使卡住也会周期性打印进度行，
        // 所以仅把 out_time_us 变化算作"有进展"，长视频不再被固定上限误杀。
        func run(_ arguments: [String]) throws -> Shell.Result {
            let lastOutTime = NSLock()
            var lastValue = ""
            return try Shell.run(ffmpeg, arguments, idleTimeout: mediaStallTimeout, isProgress: { line in
                guard line.hasPrefix("out_time_us=") else { return false }
                lastOutTime.lock(); defer { lastOutTime.unlock() }
                let value = String(line.dropFirst("out_time_us=".count))
                defer { lastValue = value }
                return value != lastValue && value != "N/A"
            }) { line in
                guard duration > 0, line.hasPrefix("out_time_us=") else { return }
                let raw = line.dropFirst("out_time_us=".count)
                if let us = Double(raw) {
                    progress(min(0.99, max(0.02, us / (duration * 1_000_000))))
                }
            }
        }

        var result = try run(args + subtitles + tail)
        if !subtitles.isEmpty, !result.timedOut, result.status != 0 {
            // 字幕转换失败不应拖垮整个转码：去掉字幕轨重试一次，和以前的行为一致。
            try? FileManager.default.removeItem(at: destination)
            result = try run(args + tail)
        }

        if result.timedOut {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.failed("转码已 \(Int(mediaStallTimeout)) 秒没有进展，疑似卡住，已中止")
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let tail = result.stderr.suffix(400)
            if tail.contains("does not contain any stream") || tail.contains("matches no streams") {
                throw ConversionError.failed("源文件没有音轨，无法提取音频")
            }
            throw ConversionError.failed("转码失败：\(tail)")
        }
        progress(1.0)
    }

    /// ffprobe 读到的源文件信息；读不到的字段保持 nil / 0，调用方各自回退。
    struct MediaProbe: Equatable {
        var duration: Double = 0
        var width: Int?
        var height: Int?
        var fps: Double?
        var videoBitsPerSecond: Int?
    }

    private static func probeMedia(_ url: URL) throws -> MediaProbe {
        guard let ffprobe = Shell.which("ffprobe") else { return MediaProbe() }
        do {
            let result = try Shell.run(ffprobe, [
                "-v", "error", "-select_streams", "V:0",
                "-show_entries", "stream=width,height,r_frame_rate,bit_rate:format=duration",
                "-of", "json", url.path,
            ], captureOutput: true)
            guard result.status == 0 else { return MediaProbe() }
            return parseProbe(json: result.stdout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return MediaProbe()
        }
    }

    /// 解析 ffprobe 的 JSON；独立成纯函数便于自检。
    static func parseProbe(json: String) -> MediaProbe {
        var probe = MediaProbe()
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return probe
        }
        if let format = root["format"] as? [String: Any], let text = format["duration"] as? String {
            probe.duration = Double(text) ?? 0
        }
        if let stream = (root["streams"] as? [[String: Any]])?.first {
            probe.width = stream["width"] as? Int
            probe.height = stream["height"] as? Int
            if let rate = stream["r_frame_rate"] as? String {
                let parts = rate.split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { probe.fps = parts[0] / parts[1] }
                else if parts.count == 1 { probe.fps = parts[0] }
            }
            if let text = stream["bit_rate"] as? String, let value = Int(text), value > 0 {
                probe.videoBitsPerSecond = value
            }
        }
        return probe
    }

    private static func probeSubtitleCodecs(_ url: URL) throws -> [String] {
        guard let ffprobe = Shell.which("ffprobe") else { return [] }
        do {
            let result = try Shell.run(ffprobe, ["-v", "error", "-select_streams", "s",
                                                 "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path],
                                       captureOutput: true)
            guard result.status == 0 else { return [] }
            return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    /// 各容器能保留的字幕：MKV 几乎全部可原样复制（mov_text 转 SRT）；
    /// MP4 / MOV 只能放 mov_text，文字字幕转换后保留、图片字幕（PGS、DVD）无法放入而跳过；
    /// WebM 只能放 WebVTT；AVI / WMV 等不保留字幕。`codecs` 按源文件字幕流的顺序给出。
    static func subtitleArguments(container: String, codecs: [String]) -> [String] {
        let text: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]
        var result: [String] = []
        var output = 0
        for (index, codec) in codecs.enumerated() {
            let target: String?
            switch container {
            case "mkv":
                target = (codec == "mov_text" || codec == "text") ? "srt" : "copy"
            case "mp4", "mov":
                target = text.contains(codec) ? "mov_text" : nil
            case "webm":
                target = text.contains(codec) ? "webvtt" : nil
            default:
                target = nil
            }
            guard let target else { continue }
            result += ["-map", "0:s:\(index)", "-c:s:\(output)", target]
            output += 1
        }
        return result
    }

    /// 按分辨率与帧率估算视频码率：`bitsPerPixel` 取自旧的固定值（1080p30 约 6M），
    /// 这样 1080p 的结果基本不变，4K 不再偏低、480p 不再虚胖。
    /// 不超过源视频自身码率（重新编码不应比原片更大），并限制在 0.5–50 Mbps。
    static func adaptiveVideoBitrate(width: Int, height: Int, fps: Double?,
                                     sourceBitsPerSecond: Int?, bitsPerPixel: Double) -> Int {
        let rate = min(max(fps ?? 30, 1), 60)
        var bits = Double(width * height) * rate * bitsPerPixel
        if let source = sourceBitsPerSecond { bits = min(bits, Double(source)) }
        return Int(min(max(bits, 500_000), 50_000_000))
    }

    private static func videoBitrate(_ options: CompressionOptions, probe: MediaProbe,
                                     bitsPerPixel: Double, fallback: String) -> String {
        // 用户明确选了档位就按档位；否则按源视频规格自适应
        if options.preset != nil { return options.videoBitrate(fallback: fallback) }
        guard let w = probe.width, let h = probe.height, w > 0, h > 0 else { return fallback }
        let bits = adaptiveVideoBitrate(width: w, height: h, fps: probe.fps,
                                        sourceBitsPerSecond: probe.videoBitsPerSecond,
                                        bitsPerPixel: bitsPerPixel)
        return "\(bits / 1000)k"
    }

    // MARK: 压缩包

    private static func convertArchive(source: URL,
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
