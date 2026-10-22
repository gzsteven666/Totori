import SwiftUI

/// 菜单栏单色模板图：优先用设计交付的 menubar.png（20×18，系统着色）
struct MenuBarGlyph: View {
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .accessibilityLabel("Totori")
        .help("Totori")
        .task {
            guard let loaded = NSImage(named: "menubar") else { return }
            loaded.size = NSSize(width: 20, height: 18)
            loaded.isTemplate = true
            image = loaded
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activityToken: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 全局监听 ⌘/⇧ + 拖动；没有辅助功能权限时菜单栏仍可用
        // 后台常驻的工具容易被 App Nap 降频，定时器一卡动画就断，这里直接禁止
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "拖拽格式轮需要稳定的动画帧"
        )
        FanController.shared.prepare()
        ProgressHUD.shared.attach()
        FanController.shared.startMonitoring()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { FanController.shared.hide() }
        }
    }



}

struct TotoriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Totori", id: "main") {
            ContentView(model: model).followsTheme()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("显示主窗口") { openMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            // 标准设置命令：⌘, 在任何前台状态都能打开
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { SettingsWindow.shared.present() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("最近任务…") { RecentTasksWindow.shared.present() }
                Button("文件浮窗") { FileShelf.shared.toggle() }
            }
            CommandMenu("文件工具") {
                ForEach(ToolKind.allCases) { tool in
                    Button(tool.title) { ToolRunner.run(urls: model.files.map(\.url), tool: tool) }
                        .disabled(!supports(tool))
                }
            }
            CommandMenu("滚轮") {
                Button("格式滚轮") { showWheel(.convert) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("工具滚轮") { showWheel(.tools) }
                Button("动作滚轮") { showWheel(.actions) }
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarGlyph()
        }
    }

    private func supports(_ tool: ToolKind) -> Bool {
        guard !model.isConverting, let first = model.files.first else { return false }
        switch tool {
        case .cropImage, .redactImage, .compressImage, .rotateRight, .resizeSmall, .stripMetadata, .qrText:
            return first.kind == .image
        case .trimMedia: return first.kind == .media
        case .mergePDF: return model.files.count > 1 && model.files.allSatisfy { $0.url.pathExtension.lowercased() == "pdf" }
        case .splitPDF: return first.url.pathExtension.lowercased() == "pdf"
        case .toPDF: return first.kind == .image || first.kind == .document
        case .zipArchive: return true
        }
    }

    private func showWheel(_ mode: FanMode) {
        if model.files.isEmpty { FanController.shared.showAtMouse(mode: mode) }
        else { FanController.shared.showMenu(mode: mode, urls: model.files.map(\.url)) }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @State private var bindings = Dictionary(uniqueKeysWithValues: FanMode.allCases.map { ($0, KeyMap.keys(for: $0)) })

    var body: some View {
        if model.isConverting {
            Text("正在转换… \(Int(model.progress * 100))%")
            Button(model.cancelRequested ? "取消中…" : "取消转换任务") { model.cancelConversion() }
                .disabled(model.cancelRequested)
        } else if model.files.isEmpty {
            Text("没有待转换文件")
        } else {
            Text("待转换 \(model.files.count) 个文件")
            if model.failedCount > 0 {
                Button("重试失败项（\(model.failedCount)）") { model.retryFailed() }
            }
            if model.cancelledCount > 0 {
                Button("继续未完成") { model.resumeUnfinished() }
            }
        }

        Divider()

        Text("文件转换在本机完成")

        Button("最近任务…") { RecentTasksWindow.shared.present() }
        Button("文件浮窗") { FileShelf.shared.toggle() }
        Button("设置…") { SettingsWindow.shared.present() }
            .keyboardShortcut(",", modifiers: .command)

        Menu("拖拽快捷键") {
            ForEach([FanMode.convert, .tools, .actions]) { mode in
                let bound = bindings[mode] ?? KeyMap.keys(for: mode)
                Menu("\(mode.title)：\(bound.map(\.symbol).sorted().joined())") {
                    ForEach(WheelKey.allCases) { key in
                        Button {
                            KeyMap.toggle(key, for: mode)
                        } label: {
                            Text(bound.contains(key)
                                 ? "\(key.symbol)  \(key.title)  ✓\(bound.count == 1 ? " · 已启用 🔒" : "")"
                                 : "\(key.symbol)  \(key.title)")
                        }
                        .disabled(bound.contains(key) && bound.count == 1)
                        .help(bound.contains(key) && bound.count == 1 ? "先添加替代键，才能取消此键；当前仍已启用" : "替代键任选其一即可")
                    }
                }
            }
            Divider()
            ForEach(KeyMap.conflicts, id: \.key) { conflict in
                Text("\(conflict.key.displayName) 重复绑定，优先：\(conflict.owners[0].title)")
            }
            Button("恢复默认快捷键") { KeyMap.resetToDefaults() }.disabled(KeyMap.isDefault)
            Text("任意一个已选按键即可；每类至少保留一个")
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyMap.didChange)) { _ in
            bindings = Dictionary(uniqueKeysWithValues: FanMode.allCases.map { ($0, KeyMap.keys(for: $0)) })
        }

        Menu("滚轮外观") {
            ForEach(FanTheme.allCases) { theme in
                Button(theme.title) {
                    UserDefaults.standard.set(theme.rawValue, forKey: "totori.theme")
                }
            }
        }

        Button("显示格式扇（对着选中文件）") {
            FanController.shared.showAtMouse()
        }

        Button("打开主窗口") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut("0", modifiers: .command)

        if !model.files.isEmpty {
            Button("开始转换") { model.convertAll() }
                .disabled(model.isConverting || model.selectedFormat == nil)
        }

        Divider()

        Button("退出 Totori") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
