import SwiftUI

enum FavoritePreviewMetrics {
    static let side: CGFloat = 300
    static let petalSize = CGSize(width: 80, height: 26)
    static let fontSize: CGFloat = 10.5
    static let badge: CGFloat = 12
    static let gap: CGFloat = 3
    static let padding: CGFloat = 5
}

/// 与 FanModel.petalCenter 同源的预览几何：12 点起顺时针。
@MainActor
enum FavoritePreviewGeometry {
    struct Slot {
        let angle: Double
        let center: CGPoint
    }

    struct Layout {
        let slots: [Slot]
        let petalSize: CGSize
        let scale: CGFloat
    }

    static func angle(index: Int, count: Int) -> Double {
        -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(max(count, 1))
    }

    static func point(index: Int, count: Int, radius: CGFloat, center: CGPoint) -> CGPoint {
        let radians = angle(index: index, count: count)
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    static func slots(count: Int, radius: CGFloat, center: CGPoint) -> [Slot] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            Slot(angle: angle(index: index, count: count),
                 center: point(index: index, count: count, radius: radius, center: center))
        }
    }

    /// 按花瓣真实矩形求半径：任意两颗的中心距至少让矩形分开
    static func minimumRadius(count: Int, width: CGFloat, height: CGFloat) -> CGFloat {
        guard count > 1 else { return 0 }
        let horizontal = width + 8
        let vertical = height + 8
        var radius: CGFloat = 40
        for a in 0..<count {
            for b in (a + 1)..<count {
                let angleA = -Double.pi / 2 + Double(a) * 2 * Double.pi / Double(count)
                let angleB = -Double.pi / 2 + Double(b) * 2 * Double.pi / Double(count)
                let dx = CGFloat(abs(cos(angleA) - cos(angleB)))
                let dy = CGFloat(abs(sin(angleA) - sin(angleB)))
                let xRadius = dx > 0.0001 ? horizontal / dx : CGFloat.infinity
                let yRadius = dy > 0.0001 ? vertical / dy : CGFloat.infinity
                radius = max(radius, min(xRadius, yRadius))
            }
        }
        return radius
    }

    /// 统一缩放整套布局（花瓣与半径同比），直到矩形互不相交且不越界
    static func layout(count: Int, side: CGFloat, basePetal: CGSize = FavoritePreviewMetrics.petalSize) -> Layout {
        let center = CGPoint(x: side / 2, y: side / 2)
        let margin: CGFloat = 8
        var scale: CGFloat = 1
        while scale >= 0.55 {
            let size = CGSize(width: basePetal.width * scale, height: basePetal.height * scale)
            let radius = minimumRadius(count: count, width: size.width, height: size.height)
            let maxRadius = min(side / 2 - margin - size.width / 2,
                                side / 2 - margin - size.height / 2)
            if radius <= maxRadius {
                return Layout(slots: slots(count: count, radius: radius, center: center),
                              petalSize: size, scale: scale)
            }
            scale -= 0.02
        }
        let size = CGSize(width: basePetal.width * 0.55, height: basePetal.height * 0.55)
        let radius = min(minimumRadius(count: count, width: size.width, height: size.height),
                         side / 2 - margin - size.width / 2)
        return Layout(slots: slots(count: count, radius: max(20, radius), center: center),
                      petalSize: size, scale: 0.55)
    }

    static func rects(for layout: Layout, side: CGFloat) -> [CGRect] {
        layout.slots.map { slot in
            CGRect(x: slot.center.x - layout.petalSize.width / 2,
                   y: slot.center.y - layout.petalSize.height / 2,
                   width: layout.petalSize.width, height: layout.petalSize.height)
        }
    }
}

struct FavoritePreviewModel {
    let kind: FileKind
    let favorites: [OutputFormat]

    /// 常用少于该类型全部格式时，末尾追加“更多”
    var includesMore: Bool {
        favorites.count < FormatCatalog.formats(for: kind).count
    }

    var labels: [String] {
        favorites.map(\.name) + (includesMore ? ["更多"] : [])
    }

    var count: Int { favorites.count + (includesMore ? 1 : 0) }
}

/// 只读预览：无手势、无回调，不可能触发转换或文件操作。
struct FavoritePreviewView: View {
    let kind: FileKind
    let formats: [OutputFormat]

    private var model: FavoritePreviewModel { FavoritePreviewModel(kind: kind, favorites: formats) }

    var body: some View {
        let side = FavoritePreviewMetrics.side
        let layout = FavoritePreviewGeometry.layout(count: model.count, side: side)

        return ZStack {
            Circle()
                .fill(Palette.brand.opacity(0.05))
                .frame(width: side - 14, height: side - 14)
            Circle()
                .strokeBorder(Palette.brand.opacity(0.14), lineWidth: 1)
                .frame(width: side - 14, height: side - 14)

            Text("预览")
                .font(.system(size: Palette.TypeSize.micro, weight: .medium))
                .foregroundStyle(Palette.textSecondary)

            ForEach(Array(layout.slots.enumerated()), id: \.offset) { index, slot in
                petal(index: index, slot: slot, size: layout.petalSize)
                    .position(slot.center)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("常用花瓣预览")
        .accessibilityIdentifier("favorites.preview")
    }

    private func petal(index: Int, slot: FavoritePreviewGeometry.Slot, size: CGSize) -> some View {
        let name = index < model.favorites.count ? model.favorites[index].name : "更多"
        let isMore = index >= model.favorites.count
        return HStack(spacing: FavoritePreviewMetrics.gap) {
            Text("\(index + 1)")
                .font(.system(size: Palette.TypeSize.micro, weight: .bold)).monospacedDigit()
                .foregroundStyle(Palette.onAccent)
                .frame(width: FavoritePreviewMetrics.badge, height: FavoritePreviewMetrics.badge)
                .background(Circle().fill(isMore ? Palette.textSecondary : Palette.brand))
            Text(name)
                .font(.system(size: FavoritePreviewMetrics.fontSize, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, FavoritePreviewMetrics.padding)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(
            Capsule().fill(Palette.surface.opacity(0.92))
                .overlay(Capsule().strokeBorder(
                    (isMore ? Palette.textSecondary : Palette.brand).opacity(0.35), lineWidth: 0.8))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(index + 1) 个\(name)")
        .accessibilityIdentifier(isMore ? "favorites.preview.more" : "favorites.preview.petal.\(model.favorites[index].ext)")
    }
}
