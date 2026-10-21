import Foundation

/// 轻量诊断日志：只记关键决策，不记每次轮询
enum DiagLog {
    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/XiaoJuConvert.log")
    private static let queue = DispatchQueue(label: "xiaoju.log")

    static func write(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(),
                                                  dateStyle: .none,
                                                  timeStyle: .medium)
        let line = "[\(stamp)] \(text)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
