import AppKit
import SwiftUI

/// 通用浮动面板：所有工具窗口都从这里出，避免每个功能各写一套
@MainActor
enum PanelKit {
    static func make<Content: View>(title: String, size: NSSize, content: Content) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(size)
        panel.center()
        return panel
    }

    static func present(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 进度

@MainActor
final class ProgressCenter: ObservableObject {
    static let shared = ProgressCenter()

    @Published var visible = false
    @Published var title = ""
    @Published var detail = ""
    @Published var fraction: Double = 0
    @Published var fileIndex = 0
    @Published var fileCount = 0
    @Published var canCancel = false
    @Published var isCancelling = false

    private var hideWork: DispatchWorkItem?
    private var cancelAction: (() -> Void)?

    func begin(title: String, files: Int, onCancel: (() -> Void)? = nil) {
        hideWork?.cancel()
        self.title = title
        self.fileCount = files
        self.fileIndex = 0
        self.fraction = 0
        self.detail = files > 1 ? "第 1 / \(files) 个" : ""
        cancelAction = onCancel
        canCancel = onCancel != nil
        isCancelling = false
        withAnimation(.easeOut(duration: 0.16)) { visible = true }
    }

    func update(_ value: Double) {
        fraction = min(max(value, 0), 1)
    }

    func nextFile(_ index: Int) {
        fileIndex = index
        fraction = 0
        if fileCount > 1 { detail = "第 \(index + 1) / \(fileCount) 个" }
    }

    /// 按钮立即反馈；同步图片处理会在当前步骤结束后停止，外部编码进程接收终止请求。
    func cancel() {
        guard canCancel, !isCancelling else { return }
        isCancelling = true
        canCancel = false
        detail = "正在取消，已完成文件保留"
        cancelAction?()
    }

    func finish(message: String? = nil) {
        canCancel = false
        isCancelling = false
        cancelAction = nil
        if let message { detail = message }
        fraction = 1
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.18)) { self?.visible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}

/// 位于屏幕下方的进度浮层（原版 OperationProgressPanel 的对应物）
@MainActor
final class ProgressHUD {
    static let shared = ProgressHUD()

    private var panel: NSPanel?

    func attach() {
        guard panel == nil else { return }
        let size = NSSize(width: 340, height: 112)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: ProgressHUDView().environmentObject(ProgressCenter.shared))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel

        ProgressCenter.shared.$visible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.setVisible(visible) }
            .store(in: &bag)
    }

    private var bag = Set<AnyCancellable>()

    private func setVisible(_ visible: Bool) {
        guard let panel else { return }
        if visible {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - 170, y: frame.minY + 120))
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
    }
}

struct ProgressHUDView: View {
    @EnvironmentObject var center: ProgressCenter
    @AppStorage("xiaoju.theme") private var themeRaw: String = FanTheme.forest.rawValue

    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(center.title)
                    .font(.system(size: Palette.TypeSize.body, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(center.detail)
                    .font(.system(size: Palette.TypeSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.35))
                    Capsule()
                        .fill(theme.gradient)
                        .frame(width: max(6, geo.size.width * center.fraction))
                }
            }
            .frame(height: 6)
            if center.canCancel || center.isCancelling {
                HStack {
                    Spacer()
                    Button(center.isCancelling ? "取消中…" : "取消任务") { center.cancel() }
                        .controlSize(.small)
                        .disabled(center.isCancelling)
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Palette.Radius.popover, style: .continuous)
                .fill(Palette.reduceTransparency ? AnyShapeStyle(Palette.surface) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: Palette.Radius.popover, style: .continuous)
                        .fill(theme.tint.opacity(Palette.reduceTransparency ? 0 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Palette.Radius.popover, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.8)
                )
        )
    }
}

import Combine
