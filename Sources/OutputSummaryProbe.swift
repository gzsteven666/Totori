import Foundation

/// 结果摘要的纯语义回归：不读文件、不碰 UI、不改偏好。
@MainActor
enum OutputSummaryProbe {
    static func run() -> Int32 {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✕") \(label)")
        }

        print("== 结果摘要 ==")

        // 1. 变大的普通转换：中性，不是错误
        let bigger = ConversionOutputSummary(sourceExtension: "png", outputExtension: "jpg",
                                             sourceBytes: 67_000, outputBytes: 328_000)
        expect(!bigger.isSmaller, "增大不算更小")
        expect(bigger.text.contains("PNG → JPEG"), "扩展名 jpg 显示为 JPEG")
        expect(bigger.text.contains("→") && bigger.text.contains("%"), "文本含大小与比例")
        expect(bigger.deltaText.contains("体积增加") && bigger.deltaText.contains("%"), "deltaText 说明增加")

        // 2. 变小
        let smaller = ConversionOutputSummary(sourceExtension: "PNG", outputExtension: "JPG",
                                              sourceBytes: 1_000_000, outputBytes: 200_000)
        expect(smaller.isSmaller, "变小标记为 isSmaller")
        expect(smaller.deltaText.contains("体积减少"), "deltaText 说明减少")
        expect(smaller.percentChange.map { $0 < 0 } ?? false, "比例为负")

        // 3. 相同
        let same = ConversionOutputSummary(sourceExtension: "png", outputExtension: "png",
                                           sourceBytes: 12_345, outputBytes: 12_345)
        expect(!same.isSmaller, "相同不算更小")
        expect(same.deltaText == "体积相同", "deltaText 相同")
        expect(!same.text.contains("%"), "相同不显示比例")

        // 4. 防御：负数、零
        let negative = ConversionOutputSummary(sourceExtension: "png", outputExtension: "png",
                                               sourceBytes: -5, outputBytes: -9)
        expect(negative.sourceSizeText == "0 KB" && negative.outputSizeText == "0 KB", "负数按 0 处理")
        let zeroSource = ConversionOutputSummary(sourceExtension: "txt", outputExtension: "pdf",
                                                 sourceBytes: 0, outputBytes: 5_000)
        expect(zeroSource.percentChange == nil, "源为 0 不计算比例")
        expect(zeroSource.deltaText.contains("体积增加") && !zeroSource.deltaText.contains("（"), "源为 0 时不给比例")

        // 5. 大小写与空扩展名
        let upper = ConversionOutputSummary(sourceExtension: "TIFF", outputExtension: "JPEG",
                                            sourceBytes: 100, outputBytes: 50)
        expect(upper.text.contains("TIFF → JPEG"), "大写扩展名规范显示")
        let empty = ConversionOutputSummary(sourceExtension: "", outputExtension: ".webp",
                                            sourceBytes: 100, outputBytes: 90)
        expect(empty.text.contains("未知格式 → WEBP"), "空扩展名有兜底")
        expect(empty.outputExtension == "webp", "扩展名归一化去点号")

        print(failures == 0 ? "结果：结果摘要 OK ✅" : "结果：\(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }
}
