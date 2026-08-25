import SwiftUI

enum DeviceSelectTargetStatus: Equatable {
    case connected
    case offline
    case pairingRequired

    var title: String {
        switch self {
        case .connected:
            return "已连接"
        case .offline:
            return "未连接"
        case .pairingRequired:
            return "检查 USB / Wi-Fi 配对"
        }
    }

    var color: Color {
        switch self {
        case .connected:
            return ColorTokens.Semantic.success
        case .offline:
            return ColorTokens.Semantic.offline
        case .pairingRequired:
            return ColorTokens.Semantic.warning
        }
    }
}

struct DeviceSelectTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let osVersion: String
    let status: DeviceSelectTargetStatus

    init(
        id: String,
        name: String,
        osVersion: String,
        status: DeviceSelectTargetStatus
    ) {
        self.id = id
        self.name = name
        self.osVersion = osVersion
        self.status = status
    }

    init(device: DeviceInfo) {
        self.init(
            id: device.id,
            name: device.name,
            osVersion: device.osVersion,
            status: device.isPaired
                ? (device.isAvailable ? .connected : .offline)
                : .pairingRequired
        )
    }

    init(unavailableDevice: UnavailableDeviceInfo) {
        let pairingState = unavailableDevice.pairingState?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let needsPairing = pairingState.contains("unpaired")
            || pairingState.contains("not paired")
            || pairingState.contains("trust")
            || pairingState.contains("未配对")
            || pairingState.contains("信任")

        self.init(
            id: unavailableDevice.id,
            name: unavailableDevice.name,
            osVersion: unavailableDevice.osVersion,
            status: needsPairing ? .pairingRequired : .offline
        )
    }

    static func selectableTargets(
        devices: [DeviceInfo],
        unavailableDevices: [UnavailableDeviceInfo],
        matcher: DeviceMatcher = DeviceMatcher()
    ) -> [DeviceSelectTarget] {
        var targetsByID: [String: DeviceSelectTarget] = [:]

        for device in unavailableDevices {
            guard !device.id.isEmpty else { continue }
            targetsByID[device.id] = DeviceSelectTarget(
                unavailableDevice: device
            )
        }
        for device in devices {
            guard !device.id.isEmpty else { continue }
            targetsByID[device.id] = DeviceSelectTarget(device: device)
        }

        let targets = Array(targetsByID.values)
        let matchingDevices = targets.map { target in
            DeviceInfo(
                id: target.id,
                name: target.name,
                platform: "com.apple.platform.iphoneos",
                osVersion: target.osVersion,
                isAvailable: target.status == .connected,
                isPaired: target.status != .pairingRequired
            )
        }

        return targets
            .filter { target in
                guard case .matched(let matchedDevice) = matcher.match(
                    preferredDeviceID: nil,
                    preferredDeviceName: target.name,
                    devices: matchingDevices
                ) else {
                    return false
                }
                return matchedDevice.id == target.id
            }
            .sorted { lhs, rhs in
                if lhs.status == .connected, rhs.status != .connected {
                    return true
                }
                if lhs.status != .connected, rhs.status == .connected {
                    return false
                }
                return lhs.name.localizedStandardCompare(rhs.name)
                    == .orderedAscending
            }
    }
}

struct DeviceSelectField: View {
    let targets: [DeviceSelectTarget]
    @Binding var selectedID: String?
    var automaticTarget: DeviceSelectTarget?
    var selectedFallback: DeviceSelectTarget?
    var onRescan: () -> Void
    var onManage: () -> Void
    var isDisabled: Bool

    @State private var isPresented = false
    @State private var isHovered = false
    @State private var fieldWidth: CGFloat = 360
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard !isDisabled else { return }
            isPresented.toggle()
        } label: {
            HStack(spacing: 12) {
                DeviceSelectIcon(size: 36, symbolSize: 18)

                triggerSummary
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(
                        isPresented
                            ? ColorTokens.Accent.renew
                            : ColorTokens.Text.tertiary
                    )
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
                    .animation(
                        reduceMotion ? nil : MotionTokens.easeOut(0.22),
                        value: isPresented
                    )
                    .accessibilityHidden(true)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
            .background(triggerBackground)
            .overlay(triggerBorder)
            .overlay(focusHalo)
            .contentShape(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .opacity(isDisabled ? 0.55 : 1)
        .allowsHitTesting(!isDisabled)
        .accessibilityLabel("目标设备")
        .accessibilityValue(triggerAccessibilityValue)
        .accessibilityHint(isDisabled ? "当前不可更改" : "打开可用设备列表")
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { fieldWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        fieldWidth = width
                    }
            }
        }
        .popover(
            isPresented: $isPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            DeviceSelectPopoverContent(
                targets: popoverTargets,
                observedTargetCount: targets.count,
                selectedID: selectedID,
                onSelect: selectTarget,
                onRescan: performRescan,
                onManage: performManage
            )
            .frame(width: min(max(fieldWidth, 360), 520))
        }
        .onChange(of: isDisabled) { _, disabled in
            if disabled {
                isPresented = false
                isFocused = false
            }
        }
    }

    @ViewBuilder
    private var triggerSummary: some View {
        if let target = displayedTarget {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(target.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ColorTokens.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !target.osVersion.isEmpty {
                        Text("iOS \(target.osVersion)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ColorTokens.Text.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(target.status.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(target.status.title)
                        .foregroundStyle(target.status.color)

                    if !target.id.isEmpty {
                        Text("·")
                            .foregroundStyle(ColorTokens.Text.tertiary)
                        Text(target.id)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ColorTokens.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 11))
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(targets.isEmpty ? "未检测到设备" : "请选择目标设备")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ColorTokens.Text.secondary)

                HStack(spacing: 7) {
                    Circle()
                        .fill(ColorTokens.Semantic.warning)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(
                        targets.isEmpty
                            ? "检查 USB / Wi-Fi 配对"
                            : "发现 \(targets.count) 台设备，请明确选择"
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(ColorTokens.Semantic.warning)
                }
            }
        }
    }

    private var displayedTarget: DeviceSelectTarget? {
        if let selectedID {
            return targets.first { $0.id == selectedID }
                ?? selectedFallback.flatMap { $0.id == selectedID ? $0 : nil }
        }
        return automaticTarget
    }

    private var popoverTargets: [DeviceSelectTarget] {
        guard let selectedID,
              !targets.contains(where: { $0.id == selectedID }),
              let selectedFallback,
              selectedFallback.id == selectedID else {
            return targets
        }
        return [selectedFallback] + targets
    }

    private var triggerBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isDisabled || (isHovered && !isPresented)
                    ? ColorTokens.BG.surfaceEmphasis
                    : ColorTokens.BG.surface
            )
            .animation(
                reduceMotion ? nil : MotionTokens.easeOut(0.18),
                value: isHovered
            )
    }

    private var triggerBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isPresented || isFocused
                    ? ColorTokens.Accent.renew
                    : (isHovered
                        ? ColorTokens.Border.strong
                        : ColorTokens.Border.subtle),
                lineWidth: isPresented || isFocused ? 1.5 : 1
            )
            .animation(
                reduceMotion ? nil : MotionTokens.easeOut(0.18),
                value: isPresented || isFocused
            )
    }

    @ViewBuilder
    private var focusHalo: some View {
        if (isPresented || isFocused) && !isDisabled {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(ColorTokens.Accent.renew.opacity(0.16), lineWidth: 3)
                .padding(-3)
                .allowsHitTesting(false)
        }
    }

    private var triggerAccessibilityValue: String {
        guard let target = displayedTarget else {
            return targets.isEmpty ? "未检测到设备" : "尚未选择目标设备"
        }
        return "\(target.name)，\(target.status.title)"
    }

    private func selectTarget(_ id: String?) {
        selectedID = id
        isPresented = false
        isFocused = true
    }

    private func performRescan() {
        isPresented = false
        onRescan()
    }

    private func performManage() {
        isPresented = false
        onManage()
    }
}

private struct DeviceSelectPopoverContent: View {
    let targets: [DeviceSelectTarget]
    let observedTargetCount: Int
    let selectedID: String?
    let onSelect: (String?) -> Void
    let onRescan: () -> Void
    let onManage: () -> Void

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("可用设备")
                    .textCase(.uppercase)
                Text("· \(observedTargetCount) 台")
                    .fontWeight(.medium)
                    .foregroundStyle(ColorTokens.Text.secondary)
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(ColorTokens.Text.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if targets.isEmpty {
                VStack(spacing: 2) {
                    Text("未检测到设备")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ColorTokens.Text.secondary)
                    Text("连接并解锁 iPhone 后重新扫描")
                        .font(.system(size: 11))
                        .foregroundStyle(ColorTokens.Text.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                DeviceSelectAutomaticRow(
                    isSelected: selectedID == nil,
                    onSelect: { onSelect(nil) }
                )

                ForEach(targets) { target in
                    DeviceSelectTargetRow(
                        target: target,
                        isSelected: selectedID == target.id,
                        onSelect: { onSelect(target.id) }
                    )
                }
            }

            Divider()
                .overlay(ColorTokens.Border.subtle)
                .padding(.top, 4)

            HStack(spacing: 6) {
                DeviceSelectFooterButton(
                    title: "重新扫描",
                    systemImage: "arrow.clockwise",
                    action: onRescan
                )
                DeviceSelectFooterButton(
                    title: "设备管理",
                    systemImage: "gearshape",
                    action: onManage
                )
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .padding(6)
        .background(ColorTokens.BG.surface)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : -4)
        .scaleEffect(hasAppeared ? 1 : 0.985, anchor: .top)
        .onAppear {
            guard !reduceMotion else {
                hasAppeared = true
                return
            }
            withAnimation(MotionTokens.easeOut(0.18)) {
                hasAppeared = true
            }
        }
    }
}

private struct DeviceSelectTargetRow: View {
    let target: DeviceSelectTarget
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                DeviceSelectIcon(
                    size: 28,
                    symbolSize: 14,
                    isSelected: isSelected
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(target.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ColorTokens.Text.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !target.osVersion.isEmpty {
                            Text("iOS \(target.osVersion)")
                                .font(.system(size: 11))
                                .foregroundStyle(ColorTokens.Text.secondary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(target.status.color)
                            .frame(width: 6, height: 6)
                        Text(target.status.title)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(ColorTokens.Text.secondary)

                    Text(target.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ColorTokens.Text.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .allowsTightening(true)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorTokens.Accent.renew)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if isSelected {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 2,
                        topTrailingRadius: 2
                    )
                    .fill(ColorTokens.Accent.renew)
                    .frame(width: 2.5)
                    .padding(.vertical, 8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(target.name)，\(target.status.title)")
        .accessibilityValue(
            "\(isSelected ? "已选择" : "未选择")，UDID \(target.id)"
        )
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                isSelected
                    ? ColorTokens.Accent.renew.opacity(0.10)
                    : (isHovered
                        ? ColorTokens.BG.surfaceEmphasis
                        : Color.clear)
            )
    }
}

private struct DeviceSelectAutomaticRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ColorTokens.Accent.renew.opacity(isSelected ? 0.18 : 0.10))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ColorTokens.Accent.renew)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("自动匹配")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ColorTokens.Text.primary)
                    Text("安全使用当前唯一在线的 iPhone")
                        .font(.system(size: 11))
                        .foregroundStyle(ColorTokens.Text.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorTokens.Accent.renew)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? ColorTokens.Accent.renew.opacity(0.10)
                            : (isHovered
                                ? ColorTokens.BG.surfaceEmphasis
                                : Color.clear)
                    )
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(ColorTokens.Accent.renew)
                        .frame(width: 2.5)
                        .padding(.vertical, 8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("自动匹配")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct DeviceSelectFooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ColorTokens.Accent.renew)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isHovered
                                ? ColorTokens.BG.surfaceEmphasis
                                : Color.clear
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct DeviceSelectIcon: View {
    let size: CGFloat
    let symbolSize: CGFloat
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: size == 36 ? 8 : 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        ColorTokens.Accent.renew.opacity(isSelected ? 0.18 : 0.10),
                        ColorTokens.Accent.renewEnd.opacity(isSelected ? 0.18 : 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "iphone")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(ColorTokens.Accent.renew)
            }
            .accessibilityHidden(true)
    }
}
