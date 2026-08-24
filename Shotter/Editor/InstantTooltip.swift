import SwiftUI

/// ツールチップに出す内容。
struct TooltipContent {
    let title: String
    let shortcut: String?
    let detail: String?
}

/// ホバー中の要素の位置と内容。
struct TooltipAnchor {
    let bounds: Anchor<CGRect>
    let content: TooltipContent
}

struct TooltipPreferenceKey: PreferenceKey {
    static let defaultValue: TooltipAnchor? = nil

    static func reduce(value: inout TooltipAnchor?, nextValue: () -> TooltipAnchor?) {
        value = nextValue() ?? value
    }
}

extension View {

    /// マウスを乗せた瞬間に出るツールチップ。
    ///
    /// SwiftUI 標準の `.help()` は表示まで約 1 秒かかるうえ、
    /// `.disabled()` された要素では出ないため、自前で用意している。
    /// - Parameter forceVisible: 動作確認用。true の間はホバーしていなくても表示する。
    func instantTooltip(
        title: String,
        shortcut: String? = nil,
        detail: String? = nil,
        forceVisible: Bool = false
    ) -> some View {
        modifier(
            InstantTooltipModifier(
                content: TooltipContent(title: title, shortcut: shortcut, detail: detail),
                forceVisible: forceVisible
            )
        )
    }

    /// ツールチップを実際に描く場所。ツールバーより外側のビューに付ける。
    func instantTooltipContainer() -> some View {
        overlayPreferenceValue(TooltipPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    TooltipOverlay(anchor: anchor, proxy: proxy)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct InstantTooltipModifier: ViewModifier {

    let content: TooltipContent
    let forceVisible: Bool

    @State private var isHovering = false

    func body(content view: Content) -> some View {
        view
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) { bounds in
                (isHovering || forceVisible)
                    ? TooltipAnchor(bounds: bounds, content: content)
                    : nil
            }
    }
}

private struct TooltipOverlay: View {

    /// カードの最大幅。位置決めもこの幅を基準にする（実測はしない）。
    private static let maxWidth: CGFloat = 260

    let anchor: TooltipAnchor
    let proxy: GeometryProxy

    var body: some View {
        let target = proxy[anchor.bounds]

        ZStack(alignment: .topLeading) {
            Color.clear

            card
                .offset(x: horizontalOffset(for: target), y: target.maxY + 6)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(anchor.content.title)
                    .font(.system(size: 12, weight: .semibold))

                if let shortcut = anchor.content.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.12))
                        )
                }
            }

            if let detail = anchor.content.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize(horizontal: anchor.content.detail == nil, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Material.regular)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    /// 対象の左端に合わせて真下へ置きつつ、ウィンドウからはみ出さないように寄せる。
    private func horizontalOffset(for target: CGRect) -> CGFloat {
        let maximum = max(proxy.size.width - Self.maxWidth - 8, 8)
        return min(max(target.minX, 8), maximum)
    }
}
