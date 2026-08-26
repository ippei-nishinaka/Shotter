import AppKit
import SwiftUI

/// ツールバーの下に出る、選択中のツール専用のオプション行。
///
/// 影や角丸のようにツールではない設定も、有効になっている間はここに並べる。
struct ToolOptionsBar: View {

    @ObservedObject var store: AnnotationStore

    /// 出すものが何も無ければ行ごと隠す。
    var hasContent: Bool {
        options(for: store.tool) != .none || store.hasShadow || store.hasRoundedCorners
    }

    var body: some View {
        HStack(spacing: 10) {
            toolOptions

            if store.hasShadow {
                if options(for: store.tool) != .none { divider }
                sliderRow(
                    label: "影の強さ",
                    value: $store.shadowStrength,
                    range: 0.3...2,
                    format: { String(format: "%.1f×", $0) }
                )
            }

            if store.hasRoundedCorners {
                if options(for: store.tool) != .none || store.hasShadow { divider }
                sliderRow(
                    label: "角の丸さ",
                    value: $store.cornerRoundness,
                    range: 0...40,
                    format: { "\(Int($0))" }
                )
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - ツールごと

    private enum OptionKind: Equatable {
        case none
        case arrow
        case rounding
        case line
        case text
        case pixelate
    }

    private func options(for tool: AnnotationTool) -> OptionKind {
        switch tool {
        case .arrow:                                  return .arrow
        case .rectangle, .filledRectangle,
             .highlight, .spotlight:                  return .rounding
        case .line:                                   return .line
        case .text:                                   return .text
        case .pixelate:                               return .pixelate
        case .select, .ellipse, .freehand, .counter:  return .none
        }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch options(for: store.tool) {
        case .arrow:
            labeled("矢じり") {
                Picker("", selection: $store.arrowHeadStyle) {
                    ForEach(ArrowHeadStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

        case .rounding:
            Toggle("角を丸める", isOn: roundingBinding)

        case .line:
            labeled("線の種類") {
                Picker("", selection: $store.lineDashStyle) {
                    ForEach(StrokeDashStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

        case .text:
            textOptions

        case .pixelate:
            labeled("種類") {
                Picker("", selection: $store.pixelateMode) {
                    ForEach(PixelateAnnotation.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            divider
            sliderRow(
                label: "強さ",
                value: $store.pixelateIntensity,
                range: 0.4...3,
                format: { String(format: "%.1f×", $0) }
            )

        case .none:
            EmptyView()
        }
    }

    private var textOptions: some View {
        Group {
            Picker("", selection: fontFamilyBinding) {
                Text(TextTraits.systemFontTitle).tag("")
                Divider()
                ForEach(TextTraits.availableFamilies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)

            sliderRow(
                label: "サイズ",
                value: $store.fontSize,
                range: 10...96,
                format: { "\(Int($0))" }
            )

            divider

            HStack(spacing: 2) {
                traitToggle("bold", help: "太字", isOn: traitBinding(\.isBold))
                traitToggle("italic", help: "斜体", isOn: traitBinding(\.isItalic))
                traitToggle("underline", help: "下線", isOn: traitBinding(\.isUnderlined))
                traitToggle("strikethrough", help: "取り消し線", isOn: traitBinding(\.isStrikethrough))
            }
        }
    }

    private func traitToggle(_ symbol: String, help: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.9) : .clear)
                )
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 部品

    private var divider: some View {
        Divider().frame(height: 16)
    }

    private func labeled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        format: @escaping (CGFloat) -> String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(width: 90)
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    // MARK: - Binding

    /// ツールごとに別々の「角を丸める」設定へつなぐ。
    private var roundingBinding: Binding<Bool> {
        switch store.tool {
        case .rectangle:       return $store.roundsOutline
        case .filledRectangle: return $store.roundsBlock
        case .highlight:       return $store.roundsHighlight
        default:               return $store.roundsFocus
        }
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { store.textTraits.fontFamily ?? "" },
            set: { store.textTraits.fontFamily = $0.isEmpty ? nil : $0 }
        )
    }

    private func traitBinding(_ keyPath: WritableKeyPath<TextTraits, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.textTraits[keyPath: keyPath] },
            set: { store.textTraits[keyPath: keyPath] = $0 }
        )
    }
}
