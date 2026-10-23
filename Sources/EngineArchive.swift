import Foundation
import Compression

extension Engine {
    // MARK: 压缩包解压与重新打包

    /// 去掉压缩扩展名后的名字：x.tar.gz、x.tgz、x.zip → x；notes.txt.gz → notes.txt
    static func archiveBaseName(_ source: URL) -> String {
        var name = source.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        name = source.deletingPathExtension().lastPathComponent
        return name.isEmpty ? source.lastPathComponent : name
    }

    /// 解压（`extract`）或解开后重新打包（`repack` → ZIP，`tgz` → tar.gz）。
    ///
    /// 解包用系统自带的 bsdtar（libarchive）：zip、7z、rar、tar 及其 gz/bz2/xz 压缩都能读，
    /// 并且默认拒绝绝对路径和 `..`，压缩包里的文件写不到目标文件夹外面。
    /// 不是 tar 的单个压缩文件（notes.txt.gz）bsdtar 不认，按单文件解压。
    /// - Returns: 实际产出的路径。单个压缩文件解压时是还原出的文件（不是文件夹）。
    /// - Throws: 解包失败（损坏、加密、格式不支持）或打包失败时抛出 `ConversionError`。
    static func convertArchiveContents(source: URL, formatExt: String, destination: URL,
                                       progress: @escaping (Double) -> Void) throws -> URL {
        progress(0.05)
        let workspace = destination.deletingLastPathComponent()
        let base = archiveBaseName(source)
        // 先解到暂存区里的同名位置；解压就直接用它，重新打包则以它为内容
        let unpacked = formatExt == "extract" ? destination
            : workspace.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(base)
        try FileManager.default.createDirectory(at: unpacked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try unpack(source, to: unpacked)
        progress(formatExt == "extract" ? 1 : 0.6)
        guard formatExt != "extract" else { return content }

        let parent = content.deletingLastPathComponent()
        switch formatExt {
        case "repack":
            guard let ditto = Shell.which("ditto") else { throw ConversionError.toolMissing("系统缺少 ditto") }
            let result = try Shell.run(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", content.path, destination.path])
            guard result.status == 0 else { throw ConversionError.failed("打包失败：\(result.stderr.suffix(200))") }
        case "tgz":
            guard let bsdtar = Shell.which("bsdtar") else { throw ConversionError.toolMissing("系统缺少 bsdtar") }
            let result = try Shell.run(bsdtar, ["-czf", destination.path, "-C", parent.path, content.lastPathComponent])
            guard result.status == 0 else { throw ConversionError.failed("打包失败：\(result.stderr.suffix(200))") }
        default:
            throw ConversionError.unsupported("暂不支持输出为 \(formatExt)")
        }
        try? FileManager.default.removeItem(at: parent)
        progress(1)
        return destination
    }

    /// 解到 `target`：普通压缩包解成文件夹；单个压缩文件还原成去掉压缩后缀的文件（与文件夹同名同位置）。
    private static func unpack(_ source: URL, to target: URL) throws -> URL {
        guard let bsdtar = Shell.which("bsdtar") else { throw ConversionError.toolMissing("系统缺少 bsdtar") }
        let lower = source.lastPathComponent.lowercased()
        let compressedSingle = ["gz", "bz2", "xz"].contains(source.pathExtension.lowercased())
            && !lower.contains(".tar.")
        // 单个压缩文件先看看里面是不是 tar；不是就按单文件解压
        if compressedSingle {
            let listing = try Shell.run(bsdtar, ["-tf", source.path], captureOutput: true)
            if listing.status != 0 {
                try decompressSingle(source, to: target)
                return target
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let result = try Shell.run(bsdtar, ["-xf", source.path, "-C", target.path])
        guard result.status == 0 else {
            let message = result.stderr.lowercased()
            if message.contains("passphrase") || message.contains("encrypt") {
                throw ConversionError.failed("压缩包有密码保护，无法解压")
            }
            throw ConversionError.failed("解压失败：\(result.stderr.suffix(300))")
        }
        return target
    }

    private static func decompressSingle(_ source: URL, to target: URL) throws {
        switch source.pathExtension.lowercased() {
        case "gz", "bz2":
            let tool = source.pathExtension.lowercased() == "gz" ? "gunzip" : "bunzip2"
            guard let path = Shell.which(tool) else { throw ConversionError.toolMissing("系统缺少 \(tool)") }
            let result = try Shell.run(path, ["-c", source.path], stdoutTo: target)
            guard result.status == 0 else { throw ConversionError.failed("解压失败：\(result.stderr.suffix(200))") }
        default:
            // .xz：系统没有 xz 命令，用 Compression 框架的 LZMA 解码（支持 .xz 容器）
            let input = try Data(contentsOf: source)
            var output = Data()
            let filter = try OutputFilter(.decompress, using: .lzma) { output.append($0 ?? Data()) }
            var offset = 0
            while offset < input.count {
                try ConversionCancellation.current?.check()
                let end = min(offset + 1 << 20, input.count)
                try filter.write(input[offset..<end])
                offset = end
            }
            try filter.finalize()
            try output.write(to: target)
        }
    }
}
