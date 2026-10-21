import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// 浮窗缩略图：后台生成、内存有界、按「路径 + mtime + size」校验，
/// 绘制阶段只读缓存，不解码、不跑 ffprobe、不写磁盘。
private actor RenderGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()          // 直接把名额转交，active 不变
        } else {
            active -= 1
        }
    }
}

final class ShelfThumbnailStore: @unchecked Sendable {
    static let shared = ShelfThumbnailStore()

    private struct Key: Hashable {
        let path: String
        let stamp: String
    }

    private struct Box: @unchecked Sendable {
        let image: CGImage?
    }

    private let limit = 96
    private let gate = RenderGate(limit: 3)
    private let lock = NSLock()
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var inFlight: Set<Key> = []

    /// 供调用方做迟到结果校验
    func signature(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(modified)-\(size)"
    }

    func cached(_ url: URL) -> CGImage? {
        let key = Key(path: url.path, stamp: signature(for: url))
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private enum Start {
        case hit(CGImage)
        case busy
        case missed
    }

    /// 返回生成时的签名；调用方必须与当前签名比对后再采用。
    func load(_ url: URL, maxPixel: CGFloat) async -> (stamp: String, image: CGImage?)? {
        guard !Task.isCancelled else { return nil }
        let stamp = signature(for: url)
        let key = Key(path: url.path, stamp: stamp)

        switch begin(key) {
        case .hit(let image):
            return (stamp, image)
        case .busy:
            return nil
        case .missed:
            break
        }

        await gate.acquire()
        guard !Task.isCancelled else {
            await gate.release()
            finish(key, image: nil)
            return nil
        }
        let rendered = await Self.render(url, maxPixel: maxPixel)
        await gate.release()
        let usable = Task.isCancelled ? nil : rendered
        finish(key, image: usable)
        return Task.isCancelled ? nil : (stamp, usable)
    }

    private func begin(_ key: Key) -> Start {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] {
            touch(key)
            return .hit(hit)
        }
        if inFlight.contains(key) { return .busy }
        inFlight.insert(key)
        return .missed
    }

    private func finish(_ key: Key, image: CGImage?) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(key)
        guard let image else { return }
        cache[key] = image
        order.append(key)
        while cache.count > limit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    // MARK: 生成

    private static func render(_ url: URL, maxPixel: CGFloat) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if isVideo(url) { return await videoFrame(url, maxPixel: maxPixel) }
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        guard !Task.isCancelled else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private static func videoFrame(_ url: URL, maxPixel: CGFloat) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let request = VideoThumbnailRequest(generator)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                request.start { image in continuation.resume(returning: image) }
            }
        }, onCancel: { request.cancel() })
    }
}

/// 注册取帧与取消串行化，避免取消先于异步取帧注册而失效。
private final class VideoThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let generator: AVAssetImageGenerator
    private var cancelled = false

    init(_ generator: AVAssetImageGenerator) { self.generator = generator }

    func start(_ completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); completion(nil); return }
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in completion(image) }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        generator.cancelAllCGImageGeneration()
        lock.unlock()
    }
}
