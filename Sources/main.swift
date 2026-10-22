import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--probe-document-pdf") {
    let source = CommandLine.arguments.count > index + 1
        ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
    exit(MainActor.assumeIsolated { DocumentPDFProbe.run(source: source) })
}

// 无 GUI 的分发自检：确认工具来自当前 App，而不是开发机路径。
if CommandLine.arguments.contains("--probe-runtime") {
    var failed = false
    for name in ["ffmpeg", "ffprobe", "cwebp", "soffice"] {
        guard let path = Shell.which(name) else {
            print("MISSING \(name)")
            failed = true
            continue
        }
        let bundled = URL(fileURLWithPath: path).path.hasPrefix(Bundle.main.bundleURL.path + "/")
        print("\(name): \(path) [bundled=\(bundled)]")
        if !bundled { failed = true }
        do {
            let result = try Shell.run(path, [name == "soffice" ? "--version" : "-version"],
                                       captureOutput: true, timeout: 30)
            print(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if result.status != 0 || result.timedOut { failed = true }
        } catch {
            print(error.localizedDescription)
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}


if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

#if TOTORI_CHECKS
// 带验收探针的构建：识别 --probe-* 等参数并直接退出，不启动 GUI。
runChecksIfRequested()
#endif

// 旧版本（xiaoju 前缀）的设置带到新名字下，必须在任何界面读取偏好之前
PreferencesMigration.runIfNeeded()
TotoriApp.main()
