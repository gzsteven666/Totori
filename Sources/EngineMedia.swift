import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

extension Engine {
    // MARK: 音视频

    /// ffmpeg 连续这么多秒没有推进输出时间，就判定卡死并中止。
    static let mediaStallTimeout: TimeInterval = 120

    static func convertMedia(source: URL,
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
        // HEVC / ProRes 只是编码不同，容器仍是 mp4 / mov（字幕规则按容器走）
        let container = FormatCatalog.actualExtension(for: format, source: source)
        // 显式映射：容器支持多音轨时保留全部音轨（默认只会带一条）。
        // V 排除封面图；末尾 ? 让源文件缺少对应流时不报错。
        switch format.ext {
        case "mp4", "hevc", "mov", "prores", "mkv", "webm":
            args += ["-map", "0:V:0?", "-map", "0:a?"]
        case "png", "jpg":
            args += ["-map", "0:V:0"]
        case "avi", "wmv":
            args += ["-map", "0:V:0?", "-map", "0:a:0?"]
        default:
            break   // gif 与纯音频输出沿用 ffmpeg 的默认选流
        }

        // GIF 动图转视频：H.264/HEVC/VP9 要求宽高为偶数、4:2:0 采样；透明处会变成黑底
        if source.pathExtension.lowercased() == "gif", ["mp4", "hevc", "mov", "prores", "mkv", "webm"].contains(format.ext) {
            args += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"]
        }

        switch format.ext {
        case "hevc":
            // hvc1 标签让 QuickTime / 照片 / iOS 能直接播放；码率按 H.264 的六成估算
            args += ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1",
                     "-b:v", videoBitrate(options, probe: info, bitsPerPixel: 0.06, fallback: "4M"),
                     "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "prores":
            // ProRes 422（profile 2），音频用无损 PCM，方便剪辑软件直接用
            args += ["-c:v", "prores_videotoolbox", "-profile:v", "2", "-c:a", "pcm_s16le"]
        case "png", "jpg":
            // thumbnail 从开头 60 帧里挑最有代表性的一帧，避开黑屏片头。
            // 随包的精简版 ffmpeg 没有 PNG 编码器，所以先存一张 RGB 无损 TIFF（ImageIO 读不了 ffmpeg 默认的 YCbCr TIFF），再转成目标格式。
            args += ["-vf", "thumbnail=n=60", "-frames:v", "1", "-update", "1", "-c:v", "tiff", "-pix_fmt", "rgb24"]
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

        let subtitles = subtitleArguments(container: container, codecs: try probeSubtitleCodecs(source))
        let isCover = ["png", "jpg"].contains(format.ext)
        let frame = destination.deletingLastPathComponent().appendingPathComponent("frame-\(UUID().uuidString).tiff")
        let output = isCover ? frame : destination
        defer { if isCover { try? FileManager.default.removeItem(at: frame) } }
        let tail = ["-progress", "pipe:1", "-nostats", output.path]

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
        if format.ext == "prores", !result.timedOut, result.status != 0 {
            // 没有 ProRes 硬件编码器的机器退回软件编码，参数含义相同
            try? FileManager.default.removeItem(at: destination)
            let software = args.map { $0 == "prores_videotoolbox" ? "prores_ks" : $0 }
            result = try run(software + subtitles + tail)
        }
        if !subtitles.isEmpty, !result.timedOut, result.status != 0 {
            // 字幕转换失败不应拖垮整个转码：去掉字幕轨重试一次，和以前的行为一致。
            try? FileManager.default.removeItem(at: destination)
            result = try run(args + tail)
        }

        if result.timedOut {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.failed("转码已 \(Int(mediaStallTimeout)) 秒没有进展，疑似卡住，已中止")
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            let tail = result.stderr.suffix(400)
            if tail.contains("does not contain any stream") || tail.contains("matches no streams") {
                throw ConversionError.failed("源文件没有音轨，无法提取音频")
            }
            throw ConversionError.failed("转码失败：\(tail)")
        }
        if isCover { try writeCoverFrame(frame, ext: format.ext, to: destination) }
        progress(1.0)
    }

    /// 把 ffmpeg 截出的 TIFF 帧存成 PNG / JPEG（质量 0.92）
    private static func writeCoverFrame(_ frame: URL, ext: String, to destination: URL) throws {
        let type = (ext == "jpg" ? UTType.jpeg : UTType.png).identifier as CFString
        guard let input = CGImageSourceCreateWithURL(frame as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw ConversionError.failed("截取封面失败")
        }
        let properties: [CFString: Any] = ext == "jpg" ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ConversionError.failed("截取封面失败") }
    }

    /// ffprobe 读到的源文件信息；读不到的字段保持 nil / 0，调用方各自回退。
    struct MediaProbe: Equatable {
        var duration: Double = 0
        var width: Int?
        var height: Int?
        var fps: Double?
        var videoBitsPerSecond: Int?
    }

    static func probeMedia(_ url: URL) throws -> MediaProbe {
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

    static func probeSubtitleCodecs(_ url: URL) throws -> [String] {
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

    static func videoBitrate(_ options: CompressionOptions, probe: MediaProbe,
                                     bitsPerPixel: Double, fallback: String) -> String {
        // 用户明确选了档位就按档位；否则按源视频规格自适应
        if options.preset != nil { return options.videoBitrate(fallback: fallback) }
        guard let w = probe.width, let h = probe.height, w > 0, h > 0 else { return fallback }
        let bits = adaptiveVideoBitrate(width: w, height: h, fps: probe.fps,
                                        sourceBitsPerSecond: probe.videoBitsPerSecond,
                                        bitsPerPixel: bitsPerPixel)
        return "\(bits / 1000)k"
    }

}
