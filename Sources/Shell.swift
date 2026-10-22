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

