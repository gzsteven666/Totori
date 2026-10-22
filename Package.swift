// swift-tools-version:5.9
import PackageDescription

// 供 IDE（SourceKit / Xcode 打开 Package）索引和 `swift build` 快速编译检查使用。
// 正式的 .app 仍由 ./build.sh 组装；这里始终带上 Checks/ 里的验收探针（TOTORI_CHECKS）。
let package = Package(
    name: "Totori",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Totori",
            path: ".",
            exclude: ["Resources", "docs", "scripts", "build.sh", "README.md", "README-zh.md",
                      "LICENSE", "THIRD_PARTY_NOTICES.md", ".github", ".gitignore"],
            sources: ["Sources", "Checks"],
            swiftSettings: [.define("TOTORI_CHECKS")]
        )
    ]
)
