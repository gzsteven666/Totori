import AppKit
import SwiftUI
import ImageIO
import Quartz

struct ComparisonView: View {
    @ObservedObject var model: ComparisonModel
    var quickLook: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoBar
            toolbar
            if let notice = dividerNotice {
                Text(notice).font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
            }
            if model.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取文件简介与预览…").foregroundStyle(Palette.textSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hasImagePair {
                imageArea
                if model.previewIsReduced {
                    Text("超大图片使用最长边 4096 像素的预览；100% 按原始像素定位。")
                        .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                }
            } else {
                fallback
            }
        }
        .padding(16)
        .foregroundStyle(Palette.textPrimary)
        .tint(Palette.brand)
        .background(Palette.canvas)
        .onDisappear { model.releaseHold() }
        .onExitCommand { model.releaseHold() }
    }

    // MARK: 顶部信息栏

    var infoBar: some View {
        HStack(spacing: 12) {
            compactFile(model.source, metadata: model.sourceMetadata, tag: "原文件")
            Image(systemName: "arrow.right")
                .font(.system(size: Palette.TypeSize.micro, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            compactFile(model.output, metadata: model.outputMetadata, tag: "结果")
            Spacer(minLength: 8)
            if let change = model.changeText {
                Text(change).font(.system(size: Palette.TypeSize.caption, weight: .medium))
                    .foregroundStyle(model.volumeDecreased ? Palette.brand : Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(change)
            }
            Menu {
                Button("快速查看原文件") { quickLook(model.source) }
                Button("快速查看结果") { quickLook(model.output) }
                Divider()
                Button("打开原文件") { NSWorkspace.shared.open(model.source) }
                Button("打开结果") { NSWorkspace.shared.open(model.output) }
                Divider()
                Button("在访达显示原文件") { NSWorkspace.shared.activateFileViewerSelecting([model.source]) }
                Button("在访达显示结果") { NSWorkspace.shared.activateFileViewerSelecting([model.output]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityIdentifier("comparison.actions")
            .accessibilityLabel("文件操作")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassSurface(cornerRadius: Palette.Radius.card, tintOpacity: 0.05, strokeOpacity: 0.45)
    }

    func compactFile(_ url: URL, metadata: FileMetadataSnapshot?, tag: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(tag).font(.system(size: Palette.TypeSize.micro, weight: .medium)).foregroundStyle(Palette.textSecondary)
                Text(url.lastPathComponent)
                    .font(.system(size: Palette.TypeSize.label, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.path)
            }
            Text(detailLine(metadata))
                .font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .help([metadata?.summary, metadata?.exactSizeText].compactMap { $0 }.joined(separator: "\n"))
        }
        .frame(minWidth: 168, maxWidth: 250, alignment: .leading)
    }

    func detailLine(_ metadata: FileMetadataSnapshot?) -> String {
        guard let metadata else { return "读取中…" }
        let parts = [metadata.formatName, metadata.resolutionText, metadata.durationText,
                     metadata.pageCount.map { "\($0) 页" }, metadata.sizeText]
            .compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    // MARK: 控件

    /// 上一张/下一张、对比方式、缩放、看原图合并成一条工具栏；窗口太窄时自动折成两行。
    var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                if model.hasImageBatch { batchNavigation }
                modeCluster
                Spacer(minLength: 8)
                zoomCluster
                holdCluster
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    if model.hasImageBatch { batchNavigation }
                    modeCluster
                    Spacer(minLength: 8)
                }
                HStack(spacing: 14) {
                    zoomCluster
                    Spacer(minLength: 8)
                    holdCluster
                }
            }
        }
        .controlSize(.small)
        .disabled(!model.hasImagePair)
    }

    var batchNavigation: some View {
        HStack(spacing: 6) {
            Button { model.previous() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canMovePrevious)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .accessibilityIdentifier("comparison.previous")
                .accessibilityLabel("上一张")
                .help("上一张（⌥⌘←）；保留缩放、位置与对比方式")
            Text(model.positionText)
                .font(.system(size: Palette.TypeSize.caption, weight: .medium)).monospacedDigit()
                .accessibilityIdentifier("comparison.position")
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canMoveNext)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .accessibilityIdentifier("comparison.next")
                .accessibilityLabel("下一张")
                .help("下一张（⌥⌘→）；保留缩放、位置与对比方式")
        }
    }

    var modeCluster: some View {
        HStack(spacing: 8) {
            modeButton(.sideBySide, enabled: model.hasImagePair)
            modeButton(.divider, enabled: model.canUseDivider)
            if model.mode == .divider && model.canUseDivider {
                Slider(value: Binding(get: { model.divider }, set: { model.setDivider($0) }), in: 0...1)
                    .frame(width: 100)
                    .accessibilityIdentifier("comparison.divider")
                    .accessibilityLabel("分界线位置")
                    .help("左右移动分界线（可用方向键微调）")
                Text("\(Int((model.divider * 100).rounded()))%")
                    .font(.system(size: Palette.TypeSize.micro)).monospacedDigit().frame(width: 32)
            }
        }
    }

    var zoomCluster: some View {
        HStack(spacing: 8) {
            Button("适应") { model.fit = true; model.anchor = CGPoint(x: 0.5, y: 0.5) }
                .accessibilityIdentifier("comparison.fit").help("缩放到适合窗口")
            Button("100%") { model.fit = false; model.zoom = 1 }
                .accessibilityIdentifier("comparison.actualSize").help("按 1:1 像素显示")
            Slider(value: Binding(get: { model.zoom }, set: { model.fit = false; model.zoom = $0 }), in: 0.05...4)
                .frame(width: 110).accessibilityLabel("共同缩放")
            Text(model.fit ? "适应窗口" : "\(Int((model.zoom * 100).rounded()))%")
                .font(.system(size: Palette.TypeSize.caption)).monospacedDigit().frame(width: 58, alignment: .leading)
        }
    }

    var holdCluster: some View {
        HStack(spacing: 10) {
            holdButton
            Toggle(isOn: $model.lockOriginal) {
                Text("锁定原图").font(.system(size: Palette.TypeSize.caption))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("comparison.lockOriginal")
            .help("锁定后持续显示原图，切换图片时保留；再点一次恢复对比")
        }
    }

    /// 一切正常时不提示；只有分界不可用、文件读不到这类需要解释的情形才出声。
    var dividerNotice: String? {
        if model.loading { return "正在读取文件预览…" }
        if model.sourceMetadata?.isReadable == false || model.outputMetadata?.isReadable == false {
            return "文件已移动或无法读取，分界与缩放不可用"
        }
        guard model.hasImagePair else { return "无法生成图片对比；可使用快速查看" }
        if !model.canUseDivider { return "两张图像素尺寸不同，分界不可用；可继续并排查看" }
        return nil
    }

    func modeButton(_ mode: ComparisonModel.ComparisonMode, enabled: Bool) -> some View {
        Button {
            model.setMode(mode)
        } label: {
            Text(mode.title)
                .font(.system(size: Palette.TypeSize.caption, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Palette.brand.opacity(model.mode == mode ? 0.85 : 0.12)))
                .foregroundStyle(model.mode == mode ? Palette.onAccent : Palette.brand)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("comparison.mode.\(mode.rawValue)")
        .accessibilityLabel(mode == .divider ? "分界对比" : "并排对比")
        .help(mode == .divider
              ? (enabled ? "分界线逐像素对比" : "两张图像素尺寸不同，无法逐像素对齐")
              : "左右并排查看")
    }

    var holdButton: some View {
        Button { } label: {
            Text("按住看原图").font(.system(size: Palette.TypeSize.caption, weight: .medium))
        }
        .buttonStyle(HoldOriginalButtonStyle(active: model.showingOriginalOnly) { pressed in
            model.holdOriginal = pressed
        })
        .accessibilityIdentifier("comparison.holdOriginal")
        .accessibilityLabel("按住查看原图")
        .accessibilityHint("按住期间只显示原图，松开或取消恢复")
        .help("按住期间只显示原图，松开立即恢复（Esc 也可恢复）")
    }

    var statusText: String {
        if model.showingOriginalOnly {
            return model.lockOriginal ? "当前：只显示原图（已锁定）" : "当前：只显示原图（松开恢复）"
        }
        if model.dividerUnavailable {
            return "原图与结果像素尺寸不同，无法逐像素对齐；已保持并排查看。"
        }
        return model.mode == .divider ? "当前：分界对比" : "当前：并排对比"
    }

    var statusIsExceptional: Bool { model.showingOriginalOnly || model.dividerUnavailable }

    // MARK: 内容

    var imageArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // “并排/分界”已由上方分段按钮高亮表示，这里只在看原图、被迫退回并排时才出声
                Text(statusText).font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                    .opacity(statusIsExceptional ? 1 : 0)
                    .accessibilityIdentifier("comparison.status")
                Spacer()
                if (model.sourceMetadata?.frameCount ?? 1) > 1 || (model.outputMetadata?.frameCount ?? 1) > 1 {
                    Text("动图预览显示第一帧；播放请使用“快速查看”。")
                        .font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                }
            }
            GeometryReader { geometry in
                let viewport = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
                let backing = NSScreen.main?.backingScaleFactor ?? 2
                let maximumWidth = CGFloat(max(model.sourceMetadata?.pixelWidth ?? 1, model.outputMetadata?.pixelWidth ?? 1))
                let maximumHeight = CGFloat(max(model.sourceMetadata?.pixelHeight ?? 1, model.outputMetadata?.pixelHeight ?? 1))
                let single = model.showingOriginalOnly || (model.mode == .divider && model.canUseDivider)
                let paneWidth = max(1, (single ? viewport.width : (viewport.width - 12) / 2) - 26)
                let fitScale = min(paneWidth / maximumWidth, max(1, viewport.height - 26) / maximumHeight, 1 / backing)
                let scale = model.fit ? fitScale : CGFloat(model.zoom) / backing

                if model.showingOriginalOnly || (model.mode == .divider && model.canUseDivider) {
                    ComparisonImageScroll(image: model.sourceBitmap,
                                          secondImage: model.showingOriginalOnly ? nil : model.outputBitmap,
                                          originalSize: imagePointSize(model.sourceMetadata),
                                          scale: scale,
                                          divider: CGFloat(model.divider),
                                          originalOnly: model.showingOriginalOnly,
                                          onDividerChange: model.showingOriginalOnly
                                              ? nil
                                              : { model.setDivider(Double($0)) },
                                          anchor: $model.anchor)
                        .clipShape(RoundedRectangle(cornerRadius: Palette.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Palette.Radius.control).stroke(Palette.line, lineWidth: 0.8))
                } else {
                    HStack(spacing: 12) {
                        imagePane(model.sourceBitmap, metadata: model.sourceMetadata, scale: scale)
                        imagePane(model.outputBitmap, metadata: model.outputMetadata, scale: scale)
                    }
                }
            }
        }
    }

    func imagePointSize(_ metadata: FileMetadataSnapshot?) -> CGSize {
        CGSize(width: max(1, metadata?.pixelWidth ?? 1), height: max(1, metadata?.pixelHeight ?? 1))
    }

    var fallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .light))
            Text("可通过快速查看检查内容，或打开文件使用对应应用查看。")
                .font(.system(size: Palette.TypeSize.body)).multilineTextAlignment(.center)
            if model.sourceMetadata?.isReadable == false || model.outputMetadata?.isReadable == false {
                Text("原文件或结果已移动、删除或无法读取。可在上方菜单尝试定位文件。")
                    .font(.system(size: Palette.TypeSize.caption))
            } else if model.sourceMetadata?.isImage == true && model.outputMetadata?.isImage == true {
                Text("这组图片无法生成并排预览。原文件与转换结果仍可通过上方菜单打开。")
                    .font(.system(size: Palette.TypeSize.caption))
            }
        }
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func imagePane(_ image: CGImage?, metadata: FileMetadataSnapshot?, scale: CGFloat) -> some View {
        ComparisonImageScroll(image: image,
                              originalSize: CGSize(width: metadata?.pixelWidth ?? 1,
                                                   height: metadata?.pixelHeight ?? 1),
                              scale: scale, anchor: $model.anchor)
            .clipShape(RoundedRectangle(cornerRadius: Palette.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Palette.Radius.control).stroke(Palette.line, lineWidth: 0.8))
    }
}

struct HoldOriginalButtonStyle: ButtonStyle {
    var active: Bool
    var onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Palette.brand.opacity(active ? 0.88 : 0.14)))
            .foregroundStyle(active ? Palette.onAccent : Palette.brand)
            .contentShape(Capsule())
            .onChange(of: configuration.isPressed) { pressed in
                onPressChanged(pressed)
            }
    }
}
