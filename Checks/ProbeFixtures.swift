import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 各 `--probe-*` 验收入口共用的合成样本。
///
/// 这些探针原先读取作者本机的固定目录，换一台机器必然失败。这里在临时目录里按需生成同名同规格的样本：
/// 1200×800 PNG、EXIF 方向 6 的 JPEG、3 秒 640×360 的 MP4 / WebM、MP3 / WAV、14 字节的损坏 PNG、tar 归档。
enum ProbeFixtures {
    /// 探针的工作目录（输出、临时副本都放这里）。
    static let work: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("totori-probe-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 样本输入目录；首次访问时生成。缺少 ffmpeg 时音视频样本不会生成，相关探针项会如实失败。
    static let inputs: URL = {
        let dir = work.appendingPathComponent("inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        generate(into: dir)
        return dir
    }()

    private static func generate(into dir: URL) {
        let forest = dir.appendingPathComponent("01-森林样本.png")
        writeImage(forest, type: .png, width: 1200, height: 800, orientation: nil)
        // 2400×1600：大于“最小体积”档的 1600 边长上限，用来验证普通转换不缩小尺寸
        writeImage(dir.appendingPathComponent("01-旅行照片-家庭合影-精选修订版.png"), type: .png,
                   width: 2400, height: 1600, orientation: nil)
        for name in ["抓取测试-B.png", "02-透明图层.png"] {
            try? FileManager.default.copyItem(at: forest, to: dir.appendingPathComponent(name))
        }
        writeImage(dir.appendingPathComponent("02-透明图层.jpg"), type: .jpeg, width: 600, height: 400, orientation: nil)
        writeImage(dir.appendingPathComponent("08-方向6.jpg"), type: .jpeg, width: 1200, height: 800, orientation: 6)
        writeImage(dir.appendingPathComponent("02-带元数据.jpg"), type: .jpeg, width: 800, height: 600, orientation: nil)
        try? Data("中文 文件名带空格\n".utf8).write(to: dir.appendingPathComponent("03-中文 空格.txt"))
        try? Data("unsupported".utf8).write(to: dir.appendingPathComponent("05-不支持.xyz"))
        try? Data("not-a-real-png".utf8).write(to: dir.appendingPathComponent("04-损坏.png"))   // 14 字节

        let archiveSource = dir.appendingPathComponent("archive-source", isDirectory: true)
        try? FileManager.default.createDirectory(at: archiveSource, withIntermediateDirectories: true)
        try? Data("归档内容\n".utf8).write(to: archiveSource.appendingPathComponent("a.txt"))
        _ = try? Shell.run("/usr/bin/tar", ["-cf", dir.appendingPathComponent("06-归档.tar").path,
                                           "-C", archiveSource.path, "a.txt"])

        guard let ffmpeg = Shell.which("ffmpeg") else { return }
        let video = ["-f", "lavfi", "-i", "testsrc=size=640x360:rate=15",
                     "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-t", "3", "-pix_fmt", "yuv420p"]
        _ = try? Shell.run(ffmpeg, ["-hide_banner", "-y"] + video
                           + ["-c:v", "libx264", "-c:a", "aac", "-shortest",
                              dir.appendingPathComponent("07-视频样本.mp4").path])
        _ = try? Shell.run(ffmpeg, ["-hide_banner", "-y"] + video
                           + ["-c:v", "libvpx-vp9", "-c:a", "libopus", "-shortest",
                              dir.appendingPathComponent("11-视频样本.webm").path])
        _ = try? Shell.run(ffmpeg, ["-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                    dir.appendingPathComponent("10-音频样本.wav").path])
        _ = try? Shell.run(ffmpeg, ["-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                    "-c:a", "libmp3lame", dir.appendingPathComponent("09-音频样本.mp3").path])
    }

    private static func writeImage(_ url: URL, type: UTType, width: Int, height: Int, orientation: Int?) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 条纹 + 方块，避免纯色被压成几十字节而让体积相关的判断失真
        for stripe in 0..<24 {
            let t = CGFloat(stripe) / 24
            context.setFillColor(CGColor(red: 0.1 + 0.5 * t, green: 0.45 + 0.3 * (1 - t), blue: 0.25, alpha: 1))
            context.fill(CGRect(x: 0, y: CGFloat(height) * t, width: CGFloat(width), height: CGFloat(height) / 24 + 1))
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
