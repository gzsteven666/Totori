import SwiftUI

/// 森林色凝胶按钮：高光、内边与阴影共用同一光源，按压保留清晰焦点边框。
struct BrandPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Palette.TypeSize.body, weight: .semibold))
            .foregroundStyle(enabled ? Palette.onAccent : Palette.textSecondary)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Palette.Radius.row, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.brand, Palette.brandHover],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(enabled ? 1 : 0.22)
                    .overlay(
                        RoundedRectangle(cornerRadius: Palette.Radius.row, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(enabled ? 0.23 : 0.08), .clear],
                                                 startPoint: .top, endPoint: .center))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Palette.Radius.row, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Palette.Radius.row, style: .continuous)
                            .strokeBorder(Palette.focus.opacity(focused ? 1 : 0), lineWidth: 2)
                            .padding(-3)
                    )
            )
            .shadow(color: Palette.brand.opacity(enabled ? 0.18 : 0), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Palette.reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// macOS 原生 checkbox 不总是响应 tint；保留 Toggle 的可访问语义。
struct BrandCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(configuration.isOn ? Palette.brand : Palette.textSecondary)
                configuration.label.foregroundStyle(Palette.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

struct BrandProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(1, max(0, configuration.fractionCompleted ?? 0))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line.opacity(0.4))
                Capsule().fill(Palette.brand)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityRepresentation { ProgressView(value: fraction).progressViewStyle(.linear) }
    }
}
