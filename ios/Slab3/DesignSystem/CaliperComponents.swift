import SwiftUI

// The Caliper component kit — the SwiftUI rebuild of reference/component-rules.md
// and reference/prop-contracts.md. These are design references written in
// HTML/React; nothing here is a port of that code, only of the rules.
//
// Rules that live in this file and must survive any edit:
//   • Square by default. Radius 3 is the maximum, and only controls get it.
//   • Structure is hairlines. There are NO elevation shadows.
//   • Exactly one cyan primary action per screen.
//   • A missing price is an em dash — never "$0", never blank.
//   • Both price sources stay visible on a row; the toggle changes emphasis.
//   • Confidence is warm so a meter can never be misread as a source hue.

// MARK: - Button

struct CaliperButton: View {
    enum Variant { case primary, outline, accent, text, danger }

    let title: String
    var variant: Variant = .outline
    var icon: String? = nil
    var fullWidth: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Caliper.space3) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
                Text(title).caliperLabel(foreground)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Caliper.hitMin)
            .padding(.horizontal, Caliper.space5)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(Rectangle().strokeBorder(border, lineWidth: Caliper.borderWidth))
            .clipShape(RoundedRectangle(cornerRadius: Caliper.radiusControl))
        }
        .buttonStyle(CaliperPressStyle())
        .disabled(disabled)
        .opacity(disabled ? Caliper.disabledOpacity : 1)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return Caliper.textOnCyan
        case .accent: return Caliper.cyan
        case .danger: return Caliper.danger
        case .outline, .text: return Caliper.textPrimary
        }
    }
    private var background: Color {
        variant == .primary ? Caliper.cyan : .clear
    }
    private var border: Color {
        switch variant {
        case .outline: return Caliper.lineStrong
        case .accent: return Caliper.cyanDim
        case .primary, .text, .danger: return .clear
        }
    }
}

/// Press is opacity, never a color change (component-rules.md § Button).
struct CaliperPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? Caliper.pressedOpacity : 1)
    }
}

// MARK: - Chip

struct Chip: View {
    enum Tone { case standard, quiet, filled, source }

    let text: String
    var tone: Tone = .standard
    var color: Color = Caliper.textSecondary
    /// Export column chips carry their position — the number IS the column order
    /// in the file, so it has to be visible.
    var order: Int? = nil

    var body: some View {
        HStack(spacing: Caliper.space2) {
            if let order {
                Text("\(order)")
                    .font(.mono(8, .bold))
                    .foregroundStyle(tone == .source ? Caliper.textOnCyan : Caliper.bg)
                    .frame(width: 12, height: 12)
                    .background(tone == .source ? color : Caliper.cyan)
            }
            Text(text).font(.mono(9, .medium)).tracking(0.45)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, Caliper.space3)
        .padding(.vertical, Caliper.space2)
        .background(fill)
        .overlay(Rectangle().strokeBorder(stroke, lineWidth: Caliper.borderWidth))
    }

    private var ink: Color {
        switch tone {
        case .standard: return Caliper.textSecondary
        case .quiet: return Caliper.textTertiary
        case .filled: return Caliper.textOnCyan
        case .source: return color
        }
    }
    private var fill: Color {
        switch tone {
        case .standard: return Caliper.surface2
        case .quiet: return .clear
        case .filled: return Caliper.cyan
        case .source: return color.opacity(0.10)
        }
    }
    private var stroke: Color {
        switch tone {
        case .standard: return Caliper.lineStrong
        case .quiet: return Caliper.line
        case .filled: return .clear
        case .source: return color.opacity(0.45)
        }
    }
}

/// The grade badge that closes a card row: `PSA 10`.
struct GradeBadge: View {
    let grader: Grader
    let grade: String?
    var body: some View {
        Chip(text: "\(grader.rawValue.uppercased()) \(grade ?? "—")")
    }
}

// MARK: - SourceToggle

/// CL | CY. One instance of the state, global, on every tab's context line.
/// The active segment fills with that source's own hue, so the control teaches the
/// colour code every time it's used.
struct SourceToggle: View {
    @Binding var value: PriceSource

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PriceSource.allCases) { source in
                let active = source == value
                Button {
                    value = source
                } label: {
                    Text(source.rawValue)
                        .font(.mono(9, .medium))
                        .tracking(1.0)
                        .foregroundStyle(active ? Caliper.bg : Caliper.textSecondary)
                        .frame(width: 30, height: 22)
                        .background(active ? source.hue : .clear)
                        .modifier(ActiveSegmentGlow(color: source.hue, active: active))
                }
                .buttonStyle(CaliperPressStyle())
                .accessibilityLabel(source.accessibilityName)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
        .clipShape(RoundedRectangle(cornerRadius: Caliper.radiusControl))
    }
}

/// The active source bloom.
private struct ActiveSegmentGlow: ViewModifier {
    let color: Color
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.shadow(color: color.opacity(0.45), radius: 6) } else { content }
    }
}

// MARK: - Prices

/// Two prices, one card. The active source leads in its own hue; the other source
/// trails in the meta line. It never disappears — the toggle changes emphasis,
/// not visibility.
struct PriceLead: View {
    let prices: PriceSet
    let source: PriceSource

    var body: some View {
        let cents = prices[source]
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(caliperMoney(cents: cents))
                .font(.price)
                .foregroundStyle(cents == nil ? Caliper.textTertiary : source.hue)
            Text(source.rawValue)
                .font(.mono(8, .medium))
                .foregroundStyle(source.hue.opacity(0.75))
        }
    }
}

/// The source that isn't leading, in the metadata register.
struct PriceRest: View {
    let prices: PriceSet
    let source: PriceSource

    var body: some View {
        HStack(spacing: Caliper.space3) {
            ForEach(PriceSource.allCases.filter { $0 != source }) { other in
                HStack(spacing: 2) {
                    Text(other.rawValue).foregroundStyle(other.hue.opacity(0.7))
                    Text(caliperMoney(cents: prices[other]))
                        .foregroundStyle(prices[other] == nil ? Caliper.textTertiary : Caliper.textSecondary)
                }
                .font(.meta)
            }
        }
    }
}

// MARK: - ConfidenceMeter

/// Five segments, filled left to right. Warm tones ONLY — never a source hue, or
/// the meter and the price it sits beside become confusable.
struct ConfidenceMeter: View {
    /// 0–5. 0 means we have no basis for a match at all.
    let value: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Rectangle()
                    .fill(i < value ? Caliper.confidence(value) : Caliper.line)
                    .frame(width: 7, height: 4)
            }
        }
        .modifier(HighConfidenceBloom(active: value >= 4))
        .accessibilityElement()
        .accessibilityLabel("Match confidence \(value) of 5")
    }
}

private struct HighConfidenceBloom: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.shadow(color: Caliper.confHigh.opacity(0.35), radius: 4) } else { content }
    }
}

// MARK: - GroupTag

/// A buyer group: dot + name, always together. Names are rendered verbatim —
/// never capitalised or reformatted, because `philcgc` and `Triumph 7/24` are
/// what the user typed and how they'll search for it.
struct GroupTag: View {
    let name: String
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: Caliper.space2) {
            Circle().fill(color).frame(width: size, height: size)
            Text(name).font(.meta).foregroundStyle(Caliper.textSecondary)
        }
    }
}

// MARK: - SummaryBlock

/// The two money figures. Always both, never one. A group with no matched cards
/// legitimately shows `EST. PAYOUT $0` and `0 of 4 matched` — information, not an
/// error state.
struct SummaryBlock: View {
    let totalCents: Int
    /// Nil when no payout rate is configured — the rate is a real number we don't
    /// have, and inventing one would be inventing money (CLAUDE.md).
    let payoutCents: Int?
    let matched: Int
    let of: Int
    var scoped: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Caliper.space2) {
                Text(scoped ? "Group total" : "Estimated total").caliperLabel()
                Text(caliperMoney(cents: totalCents))
                    .font(.figure)
                    .foregroundStyle(Caliper.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Caliper.space6)

            Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: Caliper.space2) {
                    Text("Est. payout").caliperLabel()
                    Text(payoutCents == nil ? "—" : caliperMoney(cents: payoutCents))
                        .font(.figureSmall)
                        .foregroundStyle(payoutCents == nil ? Caliper.textTertiary : Caliper.payout)
                }
                Spacer()
                Text("\(matched) of \(of) matched").caliperMeta()
            }
            .padding(Caliper.space6)
        }
        .caliperPanel()
    }
}

// MARK: - ScreenHeader

/// Every screen starts with this. The context line must always reflect live scope
/// — a card count, a selection count, a filename. If it can be a static string,
/// it's wrong.
struct ScreenHeader<Actions: View>: View {
    let context: String
    let title: String
    var contextTint: Color = Caliper.textSecondary
    var source: Binding<PriceSource>? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Caliper.space5) {
            HStack(alignment: .center) {
                Text(context).caliperLabel(contextTint)
                Spacer(minLength: Caliper.space4)
                if let source { SourceToggle(value: source) }
                actions
            }
            Text(title)
                .font(.calTitle)
                .foregroundStyle(Caliper.textPrimary)
        }
        .padding(.horizontal, Caliper.gutter)
        .padding(.top, Caliper.space5)
        .padding(.bottom, Caliper.space6)
    }
}

extension ScreenHeader where Actions == EmptyView {
    init(context: String, title: String, contextTint: Color = Caliper.textSecondary, source: Binding<PriceSource>? = nil) {
        self.init(context: context, title: title, contextTint: contextTint, source: source, actions: { EmptyView() })
    }
}

// MARK: - FilterPill

/// The filter entry point, on both Cards and Export. Clearing is inline — the
/// user never has to open a sheet to undo a filter.
struct FilterPill: View {
    let label: String
    var color: Color? = nil
    var isActive: Bool = false
    let open: () -> Void
    var clear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Caliper.space4) {
            Button(action: open) {
                HStack(spacing: Caliper.space4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? Caliper.cyan : Caliper.textSecondary)
                    if let color { Circle().fill(color).frame(width: 6, height: 6) }
                    Text(label)
                        .font(.calBody)
                        .foregroundStyle(Caliper.textPrimary)
                    Spacer()
                    if !isActive {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Caliper.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())

            if isActive, let clear {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(CaliperPressStyle())
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Caliper.rowPad)
        .frame(height: Caliper.hitMin)
        .overlay(Rectangle().strokeBorder(isActive ? Caliper.cyanDim : Caliper.lineStrong, lineWidth: Caliper.borderWidth))
    }
}

// MARK: - SelectionBar

/// Rises ABOVE the tab bar in selection mode — it never replaces it. The running
/// total is the point of the whole mode: sourcers select until they hit a target.
/// Delete stays last and is the only red thing in the bar.
struct SelectionBar: View {
    let count: Int
    let totalCents: Int
    var canGroup: Bool = true
    let group: () -> Void
    let remove: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Caliper.cyan).frame(height: Caliper.borderWidth)
            HStack {
                Text("\(count) selected").caliperLabel(Caliper.cyan)
                Spacer()
                Text(caliperMoney(cents: totalCents))
                    .font(.figureSmall)
                    .foregroundStyle(Caliper.textPrimary)
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.vertical, Caliper.space5)

            Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)

            HStack(spacing: 0) {
                action("Group", "folder", enabled: canGroup, run: group)
                divider
                action("Remove", "folder.badge.minus", run: remove)
                divider
                action("Export", "square.and.arrow.up", run: export)
                divider
                action("Delete", "trash", tint: Caliper.danger, run: delete)
            }
        }
        .background(Caliper.surface)
    }

    private var divider: some View {
        Rectangle().fill(Caliper.line).frame(width: Caliper.borderWidth, height: 34)
    }

    private func action(_ title: String, _ icon: String, tint: Color = Caliper.textPrimary, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: Caliper.space2) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).caliperLabel(tint)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : Caliper.disabledOpacity)
    }
}

// MARK: - Sheet shell

/// Filters and Groups are the same shell with different confirms. The confirm
/// label always states the outcome with its live count.
struct CaliperSheet<Content: View, Confirm: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @ViewBuilder var confirm: Confirm

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.calHeading).foregroundStyle(Caliper.textPrimary)
                Spacer()
                trailing
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.vertical, Caliper.space6)

            Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)

            ScrollView { content.padding(.bottom, Caliper.space6) }

            Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)

            confirm
                .padding(.horizontal, Caliper.gutter)
                .padding(.top, Caliper.space5)
                .padding(.bottom, Caliper.space4)
        }
        .background(Caliper.bg)
    }
}

/// One row inside a sheet.
struct SheetRow<Leading: View>: View {
    let label: String
    var sub: String? = nil
    var trailing: String? = nil
    var active: Bool = false
    @ViewBuilder var leading: Leading
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: Caliper.space5) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.calBody).foregroundStyle(Caliper.textPrimary)
                    if let sub { Text(sub).caliperMeta(Caliper.textTertiary) }
                }
                Spacer(minLength: Caliper.space4)
                if let trailing { Text(trailing).caliperMeta() }
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Caliper.cyan)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .frame(minHeight: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
    }
}

extension SheetRow where Leading == EmptyView {
    init(label: String, sub: String? = nil, trailing: String? = nil, active: Bool = false, tap: @escaping () -> Void) {
        self.init(label: label, sub: sub, trailing: trailing, active: active, leading: { EmptyView() }, tap: tap)
    }
}

/// Section heading inside a sheet or a settings list.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .caliperLabel(Caliper.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space7)
            .padding(.bottom, Caliper.space4)
    }
}

/// A full-width hairline — the system's only structural device.
struct Hairline: View {
    var color: Color = Caliper.line
    var body: some View { Rectangle().fill(color).frame(height: Caliper.borderWidth) }
}

// MARK: - Scanner controls

/// The ZOOM row: a 2pt track, cyan fill to the current value, and a 14 × 14 cyan
/// square thumb that carries the one sanctioned glow. Built by hand because a
/// stock `Slider` is a rounded pill with a circular knob, and Caliper has no pills
/// and no circles outside the selection check and the group dot.
struct CaliperSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - 14, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Rectangle().fill(Caliper.line).frame(height: 2)
                Rectangle().fill(Caliper.cyan).frame(width: usable * fraction + 7, height: 2)
                Rectangle()
                    .fill(Caliper.cyan)
                    .frame(width: 14, height: 14)
                    .caliperGlow()
                    .offset(x: usable * fraction)
            }
            .frame(height: Caliper.hitMin)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = min(max((drag.location.x - 7) / usable, 0), 1)
                    value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                }
            )
        }
        .frame(height: Caliper.hitMin)
        .accessibilityElement()
        .accessibilityValue(Double(value).formatted(.number.precision(.fractionLength(1))) + "×")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 0.25
            value = min(max(direction == .increment ? value + step : value - step, range.lowerBound), range.upperBound)
        }
    }
}

/// The TORCH switch: 44 × 22, square, cyan when on. Same reason as the slider —
/// the stock control is a capsule.
struct CaliperSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? Caliper.cyan.opacity(0.22) : Caliper.surface2)
                    .overlay(Rectangle().strokeBorder(isOn ? Caliper.cyan : Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                Rectangle()
                    .fill(isOn ? Caliper.cyan : Caliper.textSecondary)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .frame(width: 44, height: 22)
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
