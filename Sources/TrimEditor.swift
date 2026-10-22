import AppKit
import SwiftUI
import AVFoundation

/// 音视频修剪：拖两端选区间，导出一段。
/// 对应原版 AudioTrimEditor / "Drag the ends to trim"。
@MainActor
final class TrimEditor {
    static let shared = TrimEditor()

    private var panel: NSPanel?

    func present(url: URL) {
        let model = TrimModel(url: url)
        let content = TrimEditorView(
            model: model,
            onExport: { [weak self] in self?.export(model) },
            onCancel: { [weak self] in self?.panel?.orderOut(nil) }
        )
        model.load()
        panel?.orderOut(nil)
        let panel = PanelKit.make(title: "修剪 \(url.lastPathComponent)",
                                  size: NSSize(width: 640, height: 460),
                                  content: content)
        self.panel = panel
        PanelKit.present(panel)
    }

    private func export(_ model: TrimModel) {
        do {
            let output = try model.export()
            panel?.orderOut(nil)
            Feedback.success("已保存", outputs: [output], comparisons: [OutputComparison(source: model.url, output: output)])
        } catch {
            let alert = NSAlert()
            alert.messageText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            alert.runModal()
        }
    }
}

/// 与界面解耦的导出实现，方便自检直接调用
enum TrimExport {
    /// 按输出容器挑编码器：以前一律 H264/AAC 再套 .mp3/.wav/.webm，产物是空文件
    private static func codecArgs(for ext: String, isAudioOnly: Bool) -> [String] {
        if isAudioOnly {
            switch ext {
            case "mp3":        return ["-c:a", "libmp3lame", "-b:a", "192k"]
            case "wav":        return ["-c:a", "pcm_s16le"]
            case "aiff", "aif": return ["-c:a", "pcm_s16be"]
            case "flac":       return ["-c:a", "flac"]
            case "ogg":        return ["-c:a", "libvorbis", "-q:a", "5"]
            case "opus":       return ["-c:a", "libopus", "-b:a", "128k"]
            case "wma":        return ["-c:a", "wmav2", "-b:a", "192k"]
            default:           return ["-c:a", "aac", "-b:a", "192k"]
            }
        }
        switch ext {
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                    "-c:a", "libopus", "-b:a", "128k"]
        case "wmv":
            return ["-c:v", "wmv2", "-b:v", "3M", "-c:a", "wmav2", "-b:a", "160k"]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", "192k"]
        default:
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
                    "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        }
    }

    /// 精确修剪：始终重编码（流拷贝只能切在关键帧上）
    static func run(url: URL, start: Double, end: Double, isAudioOnly: Bool) throws -> URL {
        let wanted = end - start
        guard wanted > 0.1 else { throw ConversionError.failed("区间太短") }
        guard let ffmpeg = Shell.which("ffmpeg") else { throw ConversionError.toolMissing("需要 ffmpeg") }

        let ext = url.pathExtension.lowercased()
        let destination = OutputNaming.path(for: url, suffix: "-截取")

        func encode(inputSeek: Bool) throws -> String? {
            var args = ["-y"]
            if inputSeek {
                args += ["-ss", String(format: "%.3f", start), "-i", url.path,
                         "-t", String(format: "%.3f", wanted)]
            } else {
                args += ["-i", url.path, "-ss", String(format: "%.3f", start),
                         "-t", String(format: "%.3f", wanted)]
            }
            if isAudioOnly { args += ["-vn"] }
            args += codecArgs(for: ext, isAudioOnly: isAudioOnly)
            args.append(destination.path)
            let result = try Shell.run(ffmpeg, args, timeout: 300)
            guard result.status == 0 else {
                return result.stderr.isEmpty ? "ffmpeg 退出码 \(result.status)" : String(result.stderr.suffix(240))
            }
            return nil
        }

        var error = try encode(inputSeek: true)
        var actual = duration(destination)

        // 输入定位对长 GOP 仍可能偏；回退到输出定位重来一次
        if error == nil, abs(actual - wanted) > 0.12 {
            try? FileManager.default.removeItem(at: destination)
            error = try encode(inputSeek: false)
            actual = duration(destination)
        }

        // 先确认产出是可读媒体，再谈精度；空文件不能报「精度不足」
        guard error == nil, FileManager.default.fileExists(atPath: destination.path), size(destination) > 1024 else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.failed("导出失败：\(ext.uppercased()) 容器无法用当前编码器写出\(error.map { "（\($0)）" } ?? "")")
        }
        guard actual > 0.05 else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.failed("导出结果无法读取时长（\(ext.uppercased())）")
        }
        guard abs(actual - wanted) <= 0.25 else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.failed(String(format: "修剪精度不足：请求 %.2fs，实际 %.2fs", wanted, actual))
        }
        return destination
    }

    /// WebM/MKV/AVI 这类容器 AVFoundation 读不出时长，优先用 ffprobe
    static func duration(_ url: URL) -> Double {
        if let ffprobe = Shell.which("ffprobe"),
           let result = try? Shell.run(ffprobe, ["-v", "error",
                                                 "-show_entries", "format=duration",
                                                 "-of", "default=nw=1:nk=1",
                                                 url.path], captureOutput: true, timeout: 30),
           result.status == 0,
           let seconds = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds > 0 {
            return seconds
        }
        let value = DurationValue()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            value.set(seconds.isFinite ? seconds : 0)
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else { return 0 }
        return value.get()
    }

    private final class DurationValue: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double = 0
        func set(_ value: Double) { lock.lock(); seconds = value; lock.unlock() }
        func get() -> Double { lock.lock(); defer { lock.unlock() }; return seconds }
    }

    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

@MainActor
final class TrimModel: ObservableObject {
    let url: URL
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var thumbnails: [NSImage] = []
    @Published var loading = true
    @Published var loadError: String?

    init(url: URL) { self.url = url }

    var isAudioOnly: Bool {
        ["mp3", "m4a", "wav", "flac", "aiff", "aif", "ogg", "opus", "wma", "aac"]
            .contains(url.pathExtension.lowercased())
    }

    var selectedDuration: Double { max(0, end - start) }

    func load() {
        let asset = AVURLAsset(url: url)
        Task {
            let nativeDuration = (try? await asset.load(.duration).seconds) ?? 0
            let source = url
            let seconds = nativeDuration.isFinite && nativeDuration > 0
                ? nativeDuration : await Task.detached { TrimExport.duration(source) }.value
            guard seconds.isFinite, seconds > 0.1 else {
                loadError = "无法读取媒体时长，文件可能损坏或格式不受支持。"
                loading = false
                return
            }
            duration = seconds
            start = 0
            end = seconds
            loading = false
            if !isAudioOnly, nativeDuration > 0 { await loadThumbnails(asset) }
        }
    }

    private func loadThumbnails(_ asset: AVAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        var images: [NSImage] = []
        let count = 6
        for index in 0..<count {
            let ratio = (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: duration * ratio, preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image {
                images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        let result = images
        await MainActor.run { self.thumbnails = result }
    }

    func export() throws -> URL {
        try TrimExport.run(url: url, start: start, end: end, isAudioOnly: isAudioOnly)
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

struct TrimEditorView: View {
    @ObservedObject var model: TrimModel
    var onExport: () -> Void
    var onCancel: () -> Void

    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue
    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(spacing: 14) {
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.loadError {
                Text(error).foregroundStyle(Palette.textPrimary)
                Button("关闭", action: onCancel)
            } else {
                filmstrip

                VStack(spacing: 8) {
                    slider(title: "起点", value: Binding(
                        get: { model.start },
                        set: { model.start = min($0, model.end - 0.1) }
                    ))
                    slider(title: "终点", value: Binding(
                        get: { model.end },
                        set: { model.end = max($0, model.start + 0.1) }
                    ))
                }

                Text("已选 \(time(model.selectedDuration)) / 总长 \(time(model.duration))")
                    .font(.system(size: Palette.TypeSize.caption))
                    .foregroundStyle(Palette.textPrimary.opacity(0.65))

                Spacer()

                HStack {
                    Button("取消") { onCancel() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Spacer()
                    Button("截取这一段") { onExport() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 460)
        .tint(Palette.brand)
        .background(Palette.surface)
    }

    private var filmstrip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let startX = CGFloat(model.start / max(model.duration, 0.1)) * width
            let endX = CGFloat(model.end / max(model.duration, 0.1)) * width

            ZStack(alignment: .leading) {
                if model.thumbnails.isEmpty {
                    RoundedRectangle(cornerRadius: Palette.Radius.row)
                        .fill(Palette.brand.opacity(0.18))
                        .overlay(
                            Text(model.isAudioOnly ? "音频" : "无预览")
                                .font(.system(size: Palette.TypeSize.caption))
                                .foregroundStyle(Palette.textPrimary.opacity(0.5))
                        )
                } else {
                    HStack(spacing: 2) {
                        ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: (width - CGFloat(model.thumbnails.count - 1) * 2)
                                       / CGFloat(max(model.thumbnails.count, 1)))
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Palette.Radius.row, style: .continuous))
                }

                // 未选中区域压暗
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, startX))
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)

                // 选区边框
                Rectangle()
                    .strokeBorder(Palette.brand, lineWidth: 2)
                    .frame(width: max(2, endX - startX))
                    .offset(x: startX)
            }
        }
        .frame(height: 130)
    }

    private func slider(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: Palette.TypeSize.micro))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Slider(value: value, in: 0...max(model.duration, 0.1))
            Text(time(value.wrappedValue))
                .font(.system(size: Palette.TypeSize.micro, design: .monospaced))
                .foregroundStyle(Palette.textPrimary.opacity(0.7))
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
