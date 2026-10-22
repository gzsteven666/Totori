import AppKit
import SwiftUI

/// 设置面板：拖拽快捷键、外观、压缩默认值。
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var panel: NSPanel?

    func present() {
        let content = SettingsView()
        panel?.orderOut(nil)
        let panel = PanelKit.make(title: "Totori · 设置",
                                  size: NSSize(width: 600, height: 640),
                                  content: content)
        self.panel = panel
        PanelKit.present(panel)
    }
}

struct SettingsView: View {
    @AppStorage("totori.theme") private var themeRaw: String = FanTheme.forest.rawValue
    @AppStorage("totori.compressPreset") private var compressPreset: String = CompressionPreset.balanced.rawValue
    @AppStorage("totori.convertQuality") private var convertQuality: String = ""

    @State private var bindings = Dictionary(uniqueKeysWithValues: FanMode.allCases.map { ($0, KeyMap.keys(for: $0)) })
    @State private var shortcutNotice: String?
    @State private var category: SettingsCategory = .operation
    @State private var showsModifierHelp = false

    private var theme: FanTheme { FanTheme(rawValue: themeRaw) ?? .forest }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $category) {
                ForEach(SettingsPresentation.categories) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18).padding(.top, 14)
            .accessibilityIdentifier("settings.category")

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch category {
                    case .operation: operationSection
                    case .conversion: conversionSection
                    case .appearance: appearanceSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 600, height: 640)
        .tint(Palette.brand)
        .accentColor(Palette.brand)
        .onReceive(NotificationCenter.default.publisher(for: KeyMap.didChange)) { _ in
            bindings = Dictionary(uniqueKeysWithValues: FanMode.allCases.map { ($0, KeyMap.keys(for: $0)) })
        }
    }

    // MARK: 操作

    private var operationSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("拖拽快捷键") {
                Text(SettingsPresentation.shortcutHint)
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                ForEach(FanMode.allCases) { mode in
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.system(size: Palette.TypeSize.label, weight: .medium))
                            .frame(width: 68, alignment: .leading)
                        ForEach(WheelKey.allCases) { key in
                            let keys = bindings[mode] ?? KeyMap.keys(for: mode)
                            let bound = keys.contains(key)
                            let lastKey = bound && keys.count == 1
                            Button {
                                guard !lastKey else {
                                    shortcutNotice = "\(mode.title)的 \(key.displayName) 仍已启用；先添加替代键，才能取消。"
                                    return
                                }
                                KeyMap.toggle(key, for: mode)
                                shortcutNotice = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Text(key.displayName)
                                    if lastKey { Image(systemName: "lock.fill").font(.system(size: 8)) }
                                }
                                .font(.system(size: Palette.TypeSize.caption, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: Palette.Radius.small, style: .continuous)
                                        .fill(bound ? Palette.brand : Palette.surface)
                                )
                                .foregroundStyle(bound ? Palette.onAccent : Palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help((lastKey ? "每类至少保留一个按键；先选替代键，再取消此键。\n" : "") + (key.finderNote ?? "拖动文件时按住此键"))
                            .accessibilityLabel("\(mode.title)：\(key.displayName)")
                            .accessibilityValue(lastKey ? "已启用，锁定；先添加替代键" : (bound ? "已启用" : "未启用"))
                            .accessibilityIdentifier("shortcuts.\(mode.rawValue).\(key.rawValue)")
                        }
                    }
                }
                if !KeyMap.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(KeyMap.conflicts, id: \.key) { conflict in
                            Text("\(conflict.key.displayName) 重复绑定：\(conflict.owners.map(\.title).joined(separator: "、"))；将先打开\(conflict.owners[0].title)。请取消其中一处绑定。")
                        }
                    }
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("shortcuts.conflicts")
                }
                HStack {
                    Text(shortcutNotice ?? "带锁按键仍已启用；先添加替代键，才能取消。")
                        .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("恢复默认快捷键") {
                        KeyMap.resetToDefaults()
                        shortcutNotice = "快捷键已恢复默认"
                    }
                    .controlSize(.small).disabled(KeyMap.isDefault)
                    .help("只恢复拖拽快捷键，保留主题、质量和浮窗设置")
                    .accessibilityIdentifier("shortcuts.reset")
                }
                DisclosureGroup(isExpanded: $showsModifierHelp) {
                    Text(SettingsPresentation.modifierHelp)
                        .font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text("修饰键说明").font(.system(size: Palette.TypeSize.micro)).foregroundStyle(Palette.textSecondary)
                }
                .accessibilityIdentifier("shortcuts.help")
            }

            section("常用格式花瓣") {
                HStack(alignment: .top, spacing: 14) {
                    Text(SettingsPresentation.favoritesHint)
                        .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                    Button("管理常用格式…") { FavoriteFormatsWindow.shared.present() }
                        .controlSize(.small).accessibilityIdentifier("favorites.manage")
                }
            }

            section("操作步骤") {
                Text("拖文件 → 按住已设置的快捷键 → 移到花瓣后松手。回到中心松手即可取消。")
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 转换

    private var conversionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("转换质量") {
                Picker("", selection: $convertQuality) {
                    Text("不指定").tag("")
                    ForEach(CompressionPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Palette.brand)
                .accentColor(Palette.brand)
                .accessibilityIdentifier("settings.convertQuality")
                Text(SettingsPresentation.qualityHint)
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SettingsPresentation.qualityScene(convertQuality))
                    .font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textPrimary)
            }

            section("默认压缩档位") {
                Picker("", selection: $compressPreset) {
                    ForEach(CompressionPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Palette.brand)
                .accentColor(Palette.brand)
                .accessibilityIdentifier("settings.compressPreset")
                Text(SettingsPresentation.compressHint)
                    .font(.system(size: Palette.TypeSize.caption)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SettingsPresentation.qualityScene(compressPreset))
                    .font(.system(size: Palette.TypeSize.label)).foregroundStyle(Palette.textPrimary)
            }
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        section("外观") {
            Picker("", selection: $themeRaw) {
                ForEach(FanTheme.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Palette.brand)
            .accessibilityIdentifier("settings.theme")

            HStack(spacing: 10) {
                ThemeSwatch()
                VStack(alignment: .leading, spacing: 1) {
                    Text("当前：\(theme.title)")
                        .font(.system(size: Palette.TypeSize.caption, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text("影响整个界面的强调色与底色，包括花瓣、窗口和浮窗；切换立即生效")
                        .font(.system(size: Palette.TypeSize.micro))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: Palette.TypeSize.caption, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Palette.Radius.card, style: .continuous)
                .fill(Palette.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: Palette.Radius.card, style: .continuous)
                        .strokeBorder(Palette.line.opacity(0.6), lineWidth: 0.8)
                )
        )
    }
}
