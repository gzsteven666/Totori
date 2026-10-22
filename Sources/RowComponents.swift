import SwiftUI

/// 文件行右侧的状态徽标。固定 22×22，状态切换时行高不跳动。
/// 转换中有进度时画进度环，没有时退回系统转圈。
struct JobStateBadge: View {
    let state: AppModel.JobState
    var progress: Double?

    var body: some View {
        ZStack {
            switch state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(Palette.textSecondary)
            case .running:
                if let progress, progress > 0.01 {
                    ProgressRing(value: progress)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                }
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.danger)
            case .cancelled:
                Image(systemName: "pause.circle").foregroundStyle(Palette.textSecondary)
            }
        }
        .font(.system(size: 16))
        .frame(width: 22, height: 22)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.rawValue)
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
    }

    private var helpText: String {
        if state == .running, let progress, progress > 0.01 {
            return "\(state.rawValue) \(Int((progress * 100).rounded()))%"
        }
        return state.rawValue
    }
}

/// 细圆环进度：底环用分隔线色，进度弧用强调色，从 12 点方向顺时针。
struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Palette.line.opacity(0.8), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(Palette.brand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Palette.reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
        }
        .frame(width: 16, height: 16)
    }
}

/// 自动换行的横向排布。输出格式胶囊靠它在窄窗口里折成多行，而不是被截断。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// 输出格式的胶囊选择：几个常用格式一眼看全，不必先点开下拉框。
/// 键盘上获得焦点后用左右方向键切换，和下拉框的可达性等价。
struct FormatChips: View {
    let formats: [OutputFormat]
    @Binding var selection: OutputFormat?

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(formats) { format in chip(format) }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: move(-1)
            case .right: move(1)
            default: break
            }
        }
    }

    private func chip(_ format: OutputFormat) -> some View {
        let selected = selection?.ext == format.ext
        return Button { selection = format } label: {
            Text(format.name)
                .font(.system(size: Palette.TypeSize.label, weight: .medium))
                .foregroundStyle(selected ? Palette.onAccent : Palette.textPrimary)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.surfaceSecondary))
                )
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.line.opacity(0.7), lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("输出格式 \(format.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("format.chip.\(format.ext)")
    }

    private func move(_ step: Int) {
        guard !formats.isEmpty else { return }
        let current = formats.firstIndex { $0.ext == selection?.ext } ?? 0
        selection = formats[(current + step + formats.count) % formats.count]
    }
}
