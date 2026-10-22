import Foundation
import os

/// 轻量诊断日志：只记关键决策，不记每次轮询。
///
/// 同时写两处：
///  · `~/Library/Logs/Totori.log`：文本文件，方便用户直接发给开发者；超过 1 MB 时转存为 `.1` 并重新开始，
///    最多占用约 2 MB，不再无限增长。
///  · 系统统一日志（`os.Logger`）：可在“控制台”里按子系统和类别过滤。内容含文件名，
///    因此用默认的 private 级别，发布版里会被系统脱敏。
enum DiagLog {
    static let maxFileBytes: UInt64 = 1_000_000
    private static var migratedLegacy = false   // 只在串行日志队列里访问

    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Totori.log")
    /// 旧版本（名字还叫 XiaoJuConvert）的日志位置；第一次写入时若新文件不存在就搬过来。
    private static let legacyURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/XiaoJuConvert.log")
    private static let queue = DispatchQueue(label: "totori.log")
    private static let logger = Logger(subsystem: "com.local.totori", category: "diag")

    static func write(_ text: String) {
        logger.notice("\(text, privacy: .private)")
        let stamp = DateFormatter.localizedString(from: Date(),
                                                  dateStyle: .none,
                                                  timeStyle: .medium)
        let line = "[\(stamp)] \(text)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !migratedLegacy {
                migratedLegacy = true
                if fm.fileExists(atPath: legacyURL.path), !fm.fileExists(atPath: url.path) {
                    try? fm.moveItem(at: legacyURL, to: url)
                }
            }
            rotateIfNeeded(url, limit: maxFileBytes)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 文件达到上限就改名为 `<文件名>.1`（覆盖旧的转存），调用方随后会重新创建新文件。
    static func rotateIfNeeded(_ file: URL, limit: UInt64) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= limit else { return }
        let archive = file.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: file, to: archive)
    }
}
