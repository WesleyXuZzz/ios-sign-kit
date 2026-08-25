import SwiftUI

struct NumericSettingInput {
    static func committedValue(
        from draftText: String,
        in range: ClosedRange<Int>
    ) -> Int? {
        guard let numericValue = Int(draftText), !draftText.isEmpty else {
            return nil
        }

        return Swift.min(
            Swift.max(numericValue, range.lowerBound),
            range.upperBound
        )
    }
}

struct NumberStepperValuePolicy: Equatable {
    let range: ClosedRange<Int>
    let step: Int

    init(min: Int, max: Int, step: Int) {
        let upperBound = Swift.max(min, max)
        self.range = min...upperBound
        self.step = Swift.max(step, 1)
    }

    func clamped(_ value: Int) -> Int {
        Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    func adjusted(_ value: Int, direction: Int) -> Int {
        clamped(value + (direction * step))
    }

    func committedValue(from text: String) -> Int? {
        NumericSettingInput.committedValue(from: text, in: range)
    }
}

struct NumberStepper: View {
    @Binding var value: Int
    var min: Int = 1
    var max: Int
    var step: Int = 1
    var unit: String
    var isDisabled: Bool = false

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var valueBeforeEditing = 0
    @FocusState private var isControlFocused: Bool
    @FocusState private var isEditorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var policy: NumberStepperValuePolicy {
        NumberStepperValuePolicy(min: min, max: max, step: step)
    }

    private var isFocused: Bool {
        isControlFocused || isEditorFocused || isEditing
    }

    var body: some View {
        HStack(spacing: 0) {
            NumberStepperAdjustmentButton(
                systemImage: "minus",
                helpText: "减少 \(unit)",
                isEnabled: !isDisabled && value > policy.range.lowerBound,
                action: { adjust(direction: -1) }
            )

            valueEditor
                .frame(width: 60)

            NumberStepperAdjustmentButton(
                systemImage: "plus",
                helpText: "增加 \(unit)",
                isEnabled: !isDisabled && value < policy.range.upperBound,
                action: { adjust(direction: 1) }
            )
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .background(containerBackground)
        .overlay(containerBorder)
        .overlay(focusHalo)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isControlFocused)
        .onHover { isHovered = $0 }
        .onKeyPress(.leftArrow) {
            guard !isEditing else { return .ignored }
            adjust(direction: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isEditing else { return .ignored }
            adjust(direction: 1)
            return .handled
        }
        .opacity(isDisabled ? 0.55 : 1)
        .allowsHitTesting(!isDisabled)
        .animation(
            reduceMotion ? nil : MotionTokens.easeOut(0.20),
            value: isDisabled
        )
        .onAppear {
            value = policy.clamped(value)
            syncDraftWithValue()
        }
        .onChange(of: value) { _, _ in
            if !isEditing {
                syncDraftWithValue()
            }
        }
        .onChange(of: isDisabled) { _, disabled in
            if disabled {
                cancelEditing()
                isControlFocused = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("数值步进器")
        .accessibilityValue("\(value) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(direction: 1)
            case .decrement:
                adjust(direction: -1)
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        if isEditing {
            VStack(spacing: 1) {
                TextField("", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ColorTokens.Text.primary)
                    .focused($isEditorFocused)
                    .onSubmit { commitEditing() }
                    .onKeyPress(.escape) {
                        cancelEditing()
                        return .handled
                    }
                    .onChange(of: draftText) { _, newValue in
                        let filtered = newValue.filter(\.isNumber)
                        if filtered != newValue {
                            draftText = filtered
                        }
                    }
                    .frame(height: 17)

                unitLabel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: isEditorFocused) { _, focused in
                if !focused, isEditing {
                    commitEditing()
                }
            }
        } else {
            Button(action: beginEditing) {
                VStack(spacing: 1) {
                    ZStack {
                        Text("\(value)")
                            .id(value)
                            .transition(.opacity)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(ColorTokens.Text.primary)
                    .animation(
                        reduceMotion ? nil : MotionTokens.easeOut(0.18),
                        value: value
                    )

                    unitLabel
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("点击直接编辑")
            .accessibilityLabel("编辑数值")
            .accessibilityValue("\(value) \(unit)")
        }
    }

    private var unitLabel: some View {
        Text(unit)
            .font(.system(size: 10, weight: .medium))
            .tracking(0.2)
            .foregroundStyle(ColorTokens.Text.secondary)
            .lineLimit(1)
    }

    private var containerBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isDisabled
                    ? ColorTokens.BG.surfaceEmphasis
                    : ColorTokens.BG.surface
            )
    }

    private var containerBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isFocused
                    ? ColorTokens.Accent.renew
                    : (isHovered
                        ? ColorTokens.Border.strong
                        : ColorTokens.Border.subtle),
                lineWidth: isFocused ? 1.5 : 1
            )
    }

    @ViewBuilder
    private var focusHalo: some View {
        if isFocused && !isDisabled {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(ColorTokens.Accent.renew.opacity(0.16), lineWidth: 3)
                .padding(-3)
                .allowsHitTesting(false)
        }
    }

    private func adjust(direction: Int) {
        guard !isDisabled else { return }
        let adjustedValue = policy.adjusted(value, direction: direction)
        guard adjustedValue != value else { return }

        if isEditing {
            isEditing = false
            isEditorFocused = false
        }
        value = adjustedValue
        syncDraftWithValue()
        isControlFocused = true
    }

    private func beginEditing() {
        guard !isDisabled else { return }
        valueBeforeEditing = value
        draftText = "\(value)"
        isEditing = true
        Task { @MainActor in
            isEditorFocused = true
        }
    }

    private func commitEditing() {
        guard isEditing else { return }
        if let committedValue = policy.committedValue(from: draftText) {
            value = committedValue
        } else {
            value = valueBeforeEditing
        }
        isEditing = false
        isEditorFocused = false
        syncDraftWithValue()
        isControlFocused = true
    }

    private func cancelEditing() {
        guard isEditing else { return }
        value = valueBeforeEditing
        isEditing = false
        isEditorFocused = false
        syncDraftWithValue()
        isControlFocused = true
    }

    private func syncDraftWithValue() {
        draftText = "\(policy.clamped(value))"
    }
}

private struct NumberStepperAdjustmentButton: View {
    let systemImage: String
    let helpText: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    isEnabled
                        ? (isHovered
                            ? ColorTokens.Accent.renew
                            : ColorTokens.Text.secondary)
                        : ColorTokens.Text.tertiary
                )
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(
            NumberStepperAdjustmentButtonStyle(
                isHovered: isHovered,
                isEnabled: isEnabled
            )
        )
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : 0.30)
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

private struct NumberStepperAdjustmentButtonStyle: ButtonStyle {
    let isHovered: Bool
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.9 : 1)
            .animation(
                MotionTokens.easeOut(0.12),
                value: configuration.isPressed
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed {
            return ColorTokens.Accent.renew.opacity(0.12)
        }
        return isHovered ? ColorTokens.BG.surfaceEmphasis : .clear
    }
}
