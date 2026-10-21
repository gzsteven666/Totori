import AppKit

/// 预览几何与列表同步的只读回归：不触发转换、不读写文件。
@MainActor
enum FavoritePreviewProbe {
    static func run() -> Int32 {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✕") \(label)")
        }

        print("== 常用花瓣预览 ==")
        let labelWidth = FavoritePreviewMetrics.petalSize.width - FavoritePreviewMetrics.padding * 2 - FavoritePreviewMetrics.badge - FavoritePreviewMetrics.gap
        let font = NSFont.systemFont(ofSize: FavoritePreviewMetrics.fontSize, weight: .medium)
        let names = FormatCatalog.all.map(\.name) + ["更多"]
        expect(names.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= labelWidth },
               "全部格式名含Markdown在固定字号下完整显示")
        let favorites = FavoriteFormats.formats(for: .image)
        expect(favorites.count >= 4 && favorites.count <= 6, "常用数量在 4—6")

        let model = FavoritePreviewModel(kind: .image, favorites: favorites)
        expect(model.labels.count == favorites.count + (model.includesMore ? 1 : 0), "标签数含更多")
        expect(model.labels.prefix(favorites.count).elementsEqual(favorites.map(\.name)), "预览顺序与列表一致")
        if model.includesMore {
            expect(model.labels.last == "更多", "更多位于末尾")
        }

        // 12 点起顺时针
        let center = CGPoint(x: 100, y: 100)
        let slots = FavoritePreviewGeometry.slots(count: 4, radius: 50, center: center)
        expect(abs(slots[0].center.x - 100) < 0.001 && slots[0].center.y < 100, "第 1 个在 12 点")
        expect(slots[1].center.x > 100, "顺时针第 2 个在右侧")
        expect(slots[2].center.y > 100, "顺时针第 3 个在下方")
        expect(slots[3].center.x < 100, "顺时针第 4 个在左侧")

        // 与真实花瓣同源
        let fan = FanModel()
        let items = favorites.map { FanItem.format($0) }
        fan.configure(mode: .convert, items: items, fileCount: 1)
        let preview = FavoritePreviewGeometry.slots(count: items.count, radius: fan.radius, center: fan.center)
        var matched = true
        for index in items.indices {
            let real = fan.petalCenter(index)
            if abs(real.x - preview[index].center.x) > 0.001 || abs(real.y - preview[index].center.y) > 0.001 {
                matched = false
            }
        }
        expect(matched, "预览坐标与 FanModel.petalCenter 一致")

        // 5/6/7 瓣：矩形互不相交且不越界
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        for count in [5, 6, 7] {
            let layout = FavoritePreviewGeometry.layout(count: count, side: 300)
            let rects = FavoritePreviewGeometry.rects(for: layout, side: 300)
            expect(layout.scale == 1, "\(count) 瓣不缩小字号或截短标签")
            var overlapped = false
            for i in rects.indices {
                for j in rects.indices where j > i {
                    if rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j].insetBy(dx: 0.5, dy: 0.5)) {
                        overlapped = true
                    }
                }
            }
            expect(!overlapped, "\(count) 瓣矩形互不相交")
            expect(rects.allSatisfy { bounds.contains($0.insetBy(dx: -0.5, dy: -0.5)) },
                   "\(count) 瓣都在预览范围内")
        }

        for kind in FavoriteFormats.configurableKinds {
            for commonCount in 4...6 {
                let formats = Array(FormatCatalog.formats(for: kind).prefix(commonCount))
                let previewModel = FavoritePreviewModel(kind: kind, favorites: formats)
                let actualItems = formats.map { FanItem.format($0) } + [.moreFormats(kind)]
                fan.configure(mode: .convert, items: actualItems, fileCount: 1)
                let projected = FavoritePreviewGeometry.slots(count: previewModel.count, radius: fan.radius, center: fan.center)
                expect(actualItems.indices.allSatisfy { index in
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(actualItems.count)
                    let expected = CGPoint(x: fan.center.x + fan.radius * cos(angle), y: fan.center.y + fan.radius * sin(angle))
                    let point = projected[index].center
                    return abs(point.x - expected.x) < 0.001 && abs(point.y - expected.y) < 0.001 &&
                        abs(point.x - fan.petalCenter(index).x) < 0.001 && abs(point.y - fan.petalCenter(index).y) < 0.001
                }, "\(kind.title)\(commonCount)常用含更多，与实际方向和独立公式一致")
            }
        }

        print(failures == 0 ? "结果：预览 OK ✅" : "结果：\(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }
}
