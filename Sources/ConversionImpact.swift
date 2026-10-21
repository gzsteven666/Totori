import Foundation

/// 只说明当前输入与目标之间确定的变化，不估算体积、不改变转换参数。
enum ConversionImpact {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "wma"]

    static func text(format: OutputFormat, sources: [FileMetadataSnapshot]) -> String {
        let readable = sources.filter(\.isReadable)
        var changes: [String] = []
        if format.ext == "jpg", readable.contains(where: { $0.isImage && $0.hasAlpha == true }) {
            changes.append("JPEG 不保留透明背景")
        }
        if audioExtensions.contains(format.ext), readable.contains(where: \.isVideo) {
            changes.append("仅保留声音，不含画面")
        }
        if format.ext == "gif", readable.contains(where: \.isVideo) {
            changes.append("转为动图，不保留声音")
        }
        if format.ext == "txt", format.kind == .document {
            changes.append("仅保留文字，不保留排版与图片")
        }
        if format.ext == "pdf", format.kind == .image {
            changes.append("每张图片单独生成单页 PDF")
        }
        if changes.isEmpty {
            return format.ext == "jpg" ? "有损，适合照片" : format.hint
        }
        return changes.joined(separator: "；")
    }

    /// 有界并发，离开界面会取消；不在拖动轮询或绘制阶段读取文件。
    static func read(_ urls: [URL]) async -> [FileMetadataSnapshot] {
        var result: [FileMetadataSnapshot] = []
        for start in stride(from: 0, to: urls.count, by: 4) {
            guard !Task.isCancelled else { return [] }
            let end = min(start + 4, urls.count)
            let batch = await withTaskGroup(of: (Int, FileMetadataSnapshot).self) { group in
                for index in start..<end {
                    group.addTask { (index, await FileMetadataReader.read(urls[index])) }
                }
                var entries: [(Int, FileMetadataSnapshot)] = []
                for await value in group { entries.append(value) }
                return entries.sorted { $0.0 < $1.0 }.map(\.1)
            }
            result.append(contentsOf: batch)
        }
        return Task.isCancelled ? [] : result
    }
}
