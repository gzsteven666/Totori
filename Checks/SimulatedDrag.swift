import AppKit

/// 模拟「来源应用开始了一次文件拖动」：真实拖动开始时，来源应用会重写拖放粘贴板，计数随之变化。
/// 探针在“鼠标未按下”的 tick 之后调用它，再发送按下和移动的 tick。
enum SimulatedDrag {
    static func begin(_ urls: [URL]) {
        let board = NSPasteboard(name: .drag)
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
    }

    /// 一次与文件无关的拖动（例如拖动文字）：计数变化但没有文件。
    static func beginText() {
        let board = NSPasteboard(name: .drag)
        board.clearContents()
        board.setString("plain text", forType: .string)
    }
}
