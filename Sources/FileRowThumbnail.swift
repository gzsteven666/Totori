import AppKit
import SwiftUI

/// 与浮窗共用有界后台缩略图缓存；只加载进入 LazyVStack 可见范围的行。
struct FileRowThumbnail: View {
    let url: URL
    let kind: FileKind
    let revision: Int
    @State private var image: CGImage?

    private var isVideo: Bool { kind == .media && ShelfThumbnailStore.isVideo(url) }
    private var supportsPreview: Bool { kind == .image || isVideo }
    private var requestID: String { "\(url.path)|\(revision)" }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: Palette.Radius.small).fill(Palette.surfaceSecondary)
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFill()
                    .frame(width: 44, height: 44).clipped()
            } else {
                Image(systemName: kind.symbol).font(.system(size: 19, weight: .light))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, height: 44)
            }
            if isVideo {
                Image(systemName: "play.fill").font(.system(size: 7))
                    .foregroundStyle(.white).padding(4)
                    .background(.black.opacity(0.55), in: Circle()).padding(2)
            }
        }
        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: Palette.Radius.small))
        .accessibilityHidden(true)
        .task(id: requestID) {
            image = nil
            guard supportsPreview else { return }
            let store = ShelfThumbnailStore.shared
            let stamp = store.signature(for: url)
            if let cached = store.cached(url) { image = cached; return }
            // 浮窗正在生成同一缩略图时等待共用缓存，不重复解码。
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                // 缓存与浮窗共用尺寸，避免先打开主列表后让浮窗命中较小的图片。
                if let result = await store.load(url, maxPixel: 220) {
                    guard !Task.isCancelled, result.stamp == stamp,
                          store.signature(for: url) == stamp else { return }
                    image = result.image
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
        }
    }
}
