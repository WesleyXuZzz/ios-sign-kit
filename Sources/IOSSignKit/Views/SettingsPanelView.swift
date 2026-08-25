import AppKit
import SwiftUI

struct SettingsSaveControlPresentation: Equatable {
    let hasUnsavedChanges: Bool

    var isEnabled: Bool {
        hasUnsavedChanges
    }

    var isProminent: Bool {
        hasUnsavedChanges
    }

    var showsConfirmationIcon: Bool {
        hasUnsavedChanges
    }
}

enum SettingsPanelCategory: String, CaseIterable, Identifiable {
    case target = "目标"
    case renewal = "续期"
    case localNetwork = "局域网"
    case general = "通用"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .target:
            "iphone"
        case .renewal:
            "arrow.triangle.2.circlepath"
        case .localNetwork:
            "wifi"
        case .general:
            "slider.horizontal.3"
        }
    }

    static func categoryForSaveFailure(
        canSaveProjectConfiguration: Bool,
        lanControlValidationMessage: String?
    ) -> SettingsPanelCategory? {
        if !canSaveProjectConfiguration {
            return .target
        }
        if lanControlValidationMessage != nil {
            return .localNetwork
        }
        return nil
    }
}

enum SettingsCategoryControlLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 52
    static let headerSpacing: CGFloat = 16
    static let segmentSpacing: CGFloat = 4
    static let selectedCornerRadius: CGFloat = 8
    static let iconSize: CGFloat = 18
    static let itemHorizontalPadding: CGFloat = 4
    static let itemVerticalSpacing: CGFloat = 3
    static let selectionOpacity: Double = 0.12
    static let errorDotSize: CGFloat = 6
    static let errorDotHorizontalOffset: CGFloat = 6
    static let errorDotVerticalOffset: CGFloat = -2
    static let focusOutlineWidth: CGFloat = 2
    static let focusOutlineOffset: CGFloat = 2
}

struct SettingsPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var setupViewModel: SetupWizardViewModel
    @Binding var selectedCategory: SettingsPanelCategory
    let onOpenDiagnostics: () -> Void
    let initialScrollAnchor: UnitPoint

    @State private var copiedDiagnosticReport = false
    @State private var isRestoreDefaultsConfirmationPresented = false
    @State private var hoveredCategory: SettingsPanelCategory?
    @FocusState private var focusedCategory: SettingsPanelCategory?

    init(
        viewModel: MenuBarViewModel,
        setupViewModel: SetupWizardViewModel,
        selectedCategory: Binding<SettingsPanelCategory>,
        onOpenDiagnostics: @escaping () -> Void,
        initialScrollAnchor: UnitPoint = .top
    ) {
        self.viewModel = viewModel
        self.setupViewModel = setupViewModel
        _selectedCategory = selectedCategory
        self.onOpenDiagnostics = onOpenDiagnostics
        self.initialScrollAnchor = initialScrollAnchor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(
                alignment: .leading,
                spacing: SettingsCategoryControlLayout.headerSpacing
            ) {
                header
                categoryPicker
            }
            .padding(.horizontal, SpacingTokens.lg)
            .padding(.top, SpacingTokens.lg)

            ZStack(alignment: .topLeading) {
                ForEach(SettingsPanelCategory.allCases) { category in
                    categoryScrollView(for: category)
                        .opacity(selectedCategory == category ? 1 : 0)
                        .allowsHitTesting(selectedCategory == category)
                        .accessibilityHidden(selectedCategory != category)
                        .zIndex(selectedCategory == category ? 1 : 0)
                }
            }
            .animation(
                reduceMotion ? nil : MotionTokens.easeOut(MotionTokens.fast),
                value: selectedCategory
            )

            saveBar
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .alert(
            "恢复默认设置？",
            isPresented: $isRestoreDefaultsConfirmationPresented
        ) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                setupViewModel.restoreSettingsDefaults()
            }
        } message: {
            Text(
                "此操作只恢复「续期」分类的策略与频率，以及「局域网」分类的服务开关、主机、端口与密码草稿。目标设备、项目和通用设置不受影响。恢复只更新草稿，仍需点击「存储更改」提交。"
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("设置")
                .font(TypeTokens.pageTitle)
                .foregroundStyle(ColorTokens.Text.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryPicker: some View {
        HStack(spacing: SettingsCategoryControlLayout.segmentSpacing) {
            ForEach(SettingsPanelCategory.allCases) { category in
                Button {
                    selectedCategory = category
                    focusedCategory = category
                } label: {
                    VStack(
                        spacing: SettingsCategoryControlLayout
                            .itemVerticalSpacing
                    ) {
                        Image(systemName: category.systemImage)
                            .font(TypeTokens.controlIcon)
                            .frame(
                                width: SettingsCategoryControlLayout.iconSize,
                                height: SettingsCategoryControlLayout.iconSize
                            )
                            .overlay(alignment: .topTrailing) {
                                if categoryHasError(category) {
                                    Circle()
                                        .fill(ColorTokens.Semantic.critical)
                                        .frame(
                                            width: SettingsCategoryControlLayout
                                                .errorDotSize,
                                            height: SettingsCategoryControlLayout
                                                .errorDotSize
                                        )
                                        .offset(
                                            x: SettingsCategoryControlLayout
                                                .errorDotHorizontalOffset,
                                            y: SettingsCategoryControlLayout
                                                .errorDotVerticalOffset
                                        )
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityHidden(true)

                        Text(category.rawValue)
                            .font(
                                selectedCategory == category
                                    ? TypeTokens.controlLabelEmphasized
                                    : TypeTokens.controlLabel
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .foregroundStyle(
                        selectedCategory == category
                            ? ColorTokens.Accent.renew
                            : ColorTokens.Text.secondary
                    )
                    .padding(
                        .horizontal,
                        SettingsCategoryControlLayout.itemHorizontalPadding
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(
                            cornerRadius:
                                SettingsCategoryControlLayout
                                    .selectedCornerRadius,
                            style: .continuous
                        )
                        .fill(
                            selectedCategory == category
                                ? ColorTokens.Accent.renew.opacity(
                                    SettingsCategoryControlLayout
                                        .selectionOpacity
                                )
                                : hoveredCategory == category
                                    ? ColorTokens.BG.surfaceEmphasis
                                    : Color.clear
                        )
                    )
                    .overlay {
                        if focusedCategory == category {
                            RoundedRectangle(
                                cornerRadius:
                                    SettingsCategoryControlLayout
                                        .selectedCornerRadius,
                                style: .continuous
                            )
                            .strokeBorder(
                                ColorTokens.Accent.renew,
                                lineWidth: SettingsCategoryControlLayout
                                    .focusOutlineWidth
                            )
                            .padding(
                                -SettingsCategoryControlLayout
                                    .focusOutlineOffset
                            )
                            .accessibilityHidden(true)
                        }
                    }
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: SettingsCategoryControlLayout
                                .selectedCornerRadius,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($focusedCategory, equals: category)
                .focusable(selectedCategory == category)
                .onHover { isHovered in
                    hoveredCategory = isHovered ? category : nil
                }
                .accessibilityLabel(categoryAccessibilityLabel(category))
                .accessibilityAddTraits(
                    selectedCategory == category ? .isSelected : []
                )
            }
        }
        .frame(
            width: SettingsCategoryControlLayout.width,
            height: SettingsCategoryControlLayout.height
        )
        .onKeyPress(.leftArrow) {
            moveCategoryFocus(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveCategoryFocus(by: 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分类")
        .accessibilityValue(categoryAccessibilityLabel(selectedCategory))
    }

    private func moveCategoryFocus(by offset: Int) {
        let categories = SettingsPanelCategory.allCases
        guard let currentIndex = categories.firstIndex(of: selectedCategory)
        else {
            return
        }

        let nextIndex = (currentIndex + offset + categories.count)
            % categories.count
        let nextCategory = categories[nextIndex]
        selectedCategory = nextCategory
        focusedCategory = nextCategory
    }

    private func categoryScrollView(
        for category: SettingsPanelCategory
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                categoryContent(for: category)
            }
            .padding(.horizontal, SpacingTokens.lg)
            .padding(.top, SpacingTokens.md)
            .padding(.bottom, SpacingTokens.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(initialScrollAnchor)
    }

    @ViewBuilder
    private func categoryContent(
        for category: SettingsPanelCategory
    ) -> some View {
        switch category {
        case .target:
            SettingsSectionCard(title: "目标设备", systemImage: "iphone") {
                deviceSection
            }

            SettingsSectionCard(
                title: "项目",
                systemImage: "folder.badge.gearshape"
            ) {
                projectSection
            }
        case .renewal:
            SettingsSectionCard(title: "策略", systemImage: "bell.badge") {
                renewalPolicySection
            }

            SettingsSectionCard(title: "频率", systemImage: "clock") {
                renewalFrequencySection
            }
        case .localNetwork:
            LANControlSettingsSection(
                setupViewModel: setupViewModel,
                server: viewModel.lanControlServer,
                issuePairingURL: viewModel.issueLANControlPairingURL
            )
        case .general:
            SettingsSectionCard(title: "启动", systemImage: "power") {
                launchAtLoginSection
            }

            SettingsSectionCard(title: "诊断", systemImage: "stethoscope") {
                diagnosticsSection
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("设备")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .frame(width: 110, alignment: .leading)

                DeviceSelectField(
                    targets: setupViewModel.deviceSelectionTargets,
                    selectedID: selectedDeviceBinding,
                    automaticTarget: automaticDeviceTarget,
                    selectedFallback: selectedDeviceFallback,
                    onRescan: setupViewModel.scanDevices,
                    onManage: setupViewModel.openXcodeProject,
                    isDisabled: settingsControlsDisabled
                )
                .frame(maxWidth: .infinity)

                Button("重新扫描", systemImage: "arrow.clockwise") {
                    setupViewModel.scanDevices()
                }
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
                .disabled(
                    settingsControlsDisabled
                        || setupViewModel.isScanningDevices
                )
            }

            HStack(spacing: 12) {
                Text("UDID")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .frame(width: 110, alignment: .leading)

                Text(setupViewModel.selectedDeviceID.isEmpty ? "未固定设备" : setupViewModel.selectedDeviceID)
                    .font(TypeTokens.mono)
                    .foregroundStyle(ColorTokens.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                StatusPill(
                    text: deviceStatusText,
                    tone: setupViewModel.selectedDevice?.isAvailable == true ? .good : .neutral
                )
            }

            if setupViewModel.hasPinnedDeviceSelection,
               setupViewModel.selectedDevice == nil
            {
                HStack(spacing: 12) {
                    Text("最后在线")
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(viewModel.lastDeviceSeenSummary)
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("尝试配对", systemImage: "link") {
                        if let action = pairingAction {
                            _ = viewModel.performPrimaryJourneyAction(action)
                        }
                    }
                    .buttonStyle(RenewalButtonStyle(kind: .text))
                    .disabled(pairingAction?.isEnabled != true)
                    .help(pairingActionHelp)
                }
            }

            if let error = setupViewModel.deviceSelectionErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Semantic.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairingAction: PrimaryJourneyAction? {
        viewModel.primaryJourneyPresentation.headerActions.first {
            $0.id == .pairDevice
        }
    }

    private var pairingActionHelp: String {
        guard let pairingAction else {
            return "尝试通过同一局域网恢复设备配对"
        }
        if case .disabled(let reason) = pairingAction.availability {
            return reason
        }
        return "尝试通过同一局域网恢复设备配对"
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("根目录")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .frame(width: 52, alignment: .leading)

                Text(
                    setupViewModel.projectRootPath.isEmpty
                        ? "未配置"
                        : setupViewModel.projectRootPath
                )
                    .font(TypeTokens.mono)
                    .foregroundStyle(
                        setupViewModel.projectRootPath.isEmpty
                            ? ColorTokens.Text.tertiary
                            : ColorTokens.Text.primary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("更改…", systemImage: "folder") {
                    setupViewModel.chooseProjectRootDirectory()
                }
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
            }

            HStack(spacing: SpacingTokens.xl) {
                projectValue(
                    title: "Scheme",
                    value: setupViewModel.scheme
                )
                projectValue(
                    title: "Target",
                    value: setupViewModel.targetName
                )
            }

            if setupViewModel.requiresExplicitProjectCandidateSelection {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("App 目标")
                            .font(TypeTokens.caption)
                            .foregroundStyle(ColorTokens.Text.secondary)
                            .frame(width: 62, alignment: .leading)

                        Picker(
                            "App 目标",
                            selection: Binding(
                                get: {
                                    setupViewModel
                                        .selectedProjectCandidateID
                                },
                                set: {
                                    setupViewModel
                                        .selectProjectCandidate(id: $0)
                                }
                            )
                        ) {
                            Text("请选择明确的 App 目标")
                                .tag("")
                            ForEach(setupViewModel.projectCandidates) {
                                candidate in
                                Text(candidate.pickerDisplayName)
                                .tag(candidate.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("App 目标")
                        .disabled(
                            !setupViewModel.projectCandidateSelectionIsAvailable
                        )
                    }

                    if !setupViewModel.projectCandidateSelectionIsAvailable {
                        Text("项目识别结果不完整，候选仅供诊断；请重新识别后再选择。")
                            .font(TypeTokens.caption)
                            .foregroundStyle(ColorTokens.Semantic.warningText)
                            .padding(.leading, 70)
                    }

                    if let candidate = setupViewModel.projectCandidates
                        .first(where: {
                            $0.id == setupViewModel
                                .selectedProjectCandidateID
                        }) {
                        Text(
                            "\(candidate.bundleID) · "
                                + candidate.projectPath
                        )
                        .font(TypeTokens.mono)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 70)
                        .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Bundle ID")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .frame(width: 62, alignment: .leading)

                Text(
                    setupViewModel.bundleID.isEmpty
                        ? "未识别"
                        : setupViewModel.bundleID
                )
                .font(TypeTokens.mono)
                .foregroundStyle(
                    setupViewModel.bundleID.isEmpty
                        ? ColorTokens.Text.tertiary
                        : ColorTokens.Text.primary
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("重新解析", systemImage: "arrow.clockwise") {
                    setupViewModel.autofillFromProjectRoot()
                }
                .buttonStyle(RenewalButtonStyle(kind: .text))
                .disabled(
                    setupViewModel.projectRootPath
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || setupViewModel.isInferringProject
                )

            }

            if setupViewModel.isInferringProject {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在识别 App 目标…")
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                }
            } else if !setupViewModel.projectValidationMessage.isEmpty {
                Text(setupViewModel.projectValidationMessage)
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var renewalPolicySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AutoRefreshPolicy.allCases) { policy in
                Button {
                    guard setupViewModel.autoRefreshPolicy != policy else { return }
                    setupViewModel.autoRefreshPolicy = policy
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(
                            systemName: setupViewModel.autoRefreshPolicy == policy
                                ? "largecircle.fill.circle"
                                : "circle"
                        )
                        .font(TypeTokens.optionIcon)
                        .foregroundStyle(
                            setupViewModel.autoRefreshPolicy == policy
                                ? ColorTokens.Accent.renew
                                : ColorTokens.Text.tertiary
                        )
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.title)
                                .font(TypeTokens.cardTitle)
                                .foregroundStyle(ColorTokens.Text.primary)

                            Text(policyHelpText(for: policy))
                                .font(TypeTokens.auxiliary)
                                .foregroundStyle(ColorTokens.Text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                        .fill(
                            setupViewModel.autoRefreshPolicy == policy
                                ? ColorTokens.Accent.renew.opacity(0.06)
                                : Color.clear
                        )
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                        .strokeBorder(
                            setupViewModel.autoRefreshPolicy == policy
                                ? ColorTokens.Accent.renew
                                : ColorTokens.Border.strong,
                            lineWidth: setupViewModel.autoRefreshPolicy == policy ? 1 : 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(policy.title)
                .accessibilityValue(
                    setupViewModel.autoRefreshPolicy == policy ? "已选择" : "未选择"
                )
            }
        }
    }

    private var renewalFrequencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                numberSettingRow(
                    title: "检查频率",
                    detail: "签名到期前主动检查设备与签名状态",
                    value: $setupViewModel.checkIntervalMinutes,
                    range: AppConfigConstraints.checkIntervalRange,
                    unit: "分钟"
                )

                Divider()
                    .overlay(ColorTokens.Border.subtle)

                numberSettingRow(
                    title: "到期检查频率",
                    detail: "确认签名到期后检查设备与续签条件",
                    value: $setupViewModel.expiredCheckIntervalMinutes,
                    range: AppConfigConstraints.expiredCheckIntervalRange,
                    unit: "分钟"
                )

                Divider()
                    .overlay(ColorTokens.Border.subtle)

                numberSettingRow(
                    title: "提醒冷却",
                    detail: "同一原因两次提醒之间的最小间隔",
                    value: $setupViewModel.reminderCooldownHours,
                    range: AppConfigConstraints.reminderCooldownRange,
                    unit: "小时"
                )
            }
            .padding(.top, 2)

            if case .failed(let message) = setupViewModel.reminderSettingsSaveState {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Semantic.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录时自动启动")
                        .font(TypeTokens.cardTitle)
                        .foregroundStyle(ColorTokens.Text.primary)
                    Text("登录 Mac 时在菜单栏保持监测")
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                }

                Spacer(minLength: 0)

                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { viewModel.launchAtLoginEnabled },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("登录时自动启动")
            }

            if let error = viewModel.launchAtLoginUpdateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Semantic.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("诊断")
                        .font(TypeTokens.cardTitle)
                        .foregroundStyle(ColorTokens.Text.primary)
                    Text(viewModel.environmentStatus.summary)
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button("查看诊断") {
                    onOpenDiagnostics()
                }
                .buttonStyle(RenewalButtonStyle(kind: .secondary))

                Button(copiedDiagnosticReport ? "已复制" : "复制诊断报告") {
                    copyDiagnosticReport()
                }
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var saveBar: some View {
        let presentation = SettingsSaveControlPresentation(
            hasUnsavedChanges: setupViewModel.hasUnsavedChanges
        )

        return HStack(spacing: 12) {
            Button("恢复默认设置…") {
                isRestoreDefaultsConfirmationPresented = true
            }
            .buttonStyle(RenewalButtonStyle(kind: .text))

            Spacer(minLength: 0)

            if setupViewModel.hasUnsavedChanges {
                HStack(spacing: 5) {
                    Circle()
                        .fill(ColorTokens.Semantic.warning)
                        .frame(width: 7, height: 7)
                    Text("有未存储的更改")
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Semantic.warning)
                }
                .accessibilityLabel("有未存储的更改")
            }

            Button {
                saveSettings()
            } label: {
                if presentation.showsConfirmationIcon {
                    Label("存储更改", systemImage: "checkmark")
                } else {
                    Text("存储更改")
                }
            }
            .buttonStyle(
                RenewalButtonStyle(
                    kind: presentation.isProminent
                        ? .primary
                        : .secondary,
                    height: 32
                )
            )
            .disabled(!presentation.isEnabled)
        }
        .padding(.horizontal, SpacingTokens.lg)
        .padding(.vertical, SpacingTokens.sm)
        .background(ColorTokens.BG.canvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ColorTokens.Border.subtle)
                .frame(height: 1)
        }
    }

    private func saveSettings() {
        guard !setupViewModel.saveSettings() else {
            return
        }

        if let category = SettingsPanelCategory.categoryForSaveFailure(
            canSaveProjectConfiguration:
                setupViewModel.canSaveProjectConfiguration,
            lanControlValidationMessage:
                setupViewModel.lanControlValidationMessage
        ) {
            selectedCategory = category
        } else if case .failed = setupViewModel.reminderSettingsSaveState {
            selectedCategory = .renewal
        }
    }

    private func categoryHasError(
        _ category: SettingsPanelCategory
    ) -> Bool {
        switch category {
        case .target:
            !setupViewModel.canSaveProjectConfiguration
        case .renewal:
            if case .failed = setupViewModel.reminderSettingsSaveState {
                true
            } else {
                false
            }
        case .localNetwork:
            setupViewModel.lanControlValidationMessage != nil
                || lanControlServerHasError
        case .general:
            viewModel.launchAtLoginUpdateError != nil
        }
    }

    private func categoryAccessibilityLabel(
        _ category: SettingsPanelCategory
    ) -> String {
        categoryHasError(category)
            ? "\(category.rawValue)，存在错误"
            : category.rawValue
    }

    private var lanControlServerHasError: Bool {
        if case .failed = viewModel.lanControlServer.status {
            return true
        }
        return false
    }

    private func projectValue(
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)
                .frame(width: 52, alignment: .leading)

            Text(value.isEmpty ? "未识别" : value)
                .font(TypeTokens.body)
                .foregroundStyle(
                    value.isEmpty ? ColorTokens.Text.tertiary : ColorTokens.Text.primary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberSettingRow(
        title: String,
        detail: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)

                Text(detail)
                    .font(TypeTokens.auxiliary)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NumberStepper(
                value: value,
                min: range.lowerBound,
                max: range.upperBound,
                step: 1,
                unit: unit,
                isDisabled: settingsControlsDisabled
            )
            .accessibilityLabel(title)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func policyHelpText(for policy: AutoRefreshPolicy) -> String {
        switch policy {
        case .reminderOnly:
            "到期前发送通知，由你手动触发续签"
        case .autoRefreshWhenExpired:
            "剩余不足 24 小时且设备已连接时，自动续期"
        }
    }

    private var deviceStatusText: String {
        setupViewModel.selectedDevice?.isAvailable == true ? "已连接" : "未连接"
    }

    private var selectedDeviceBinding: Binding<String?> {
        Binding(
            get: {
                setupViewModel.selectedDeviceID.isEmpty
                    ? nil
                    : setupViewModel.selectedDeviceID
            },
            set: { setupViewModel.selectDeviceDraft(id: $0) }
        )
    }

    private var automaticDeviceTarget: DeviceSelectTarget? {
        setupViewModel.detectedDevice.map(DeviceSelectTarget.init(device:))
    }

    private var selectedDeviceFallback: DeviceSelectTarget? {
        guard setupViewModel.hasPinnedDeviceSelection,
              !setupViewModel.deviceSelectionTargets.contains(where: {
                  $0.id == setupViewModel.selectedDeviceID
              }) else {
            return nil
        }

        return DeviceSelectTarget(
            id: setupViewModel.selectedDeviceID,
            name: setupViewModel.deviceSelectionPrimaryText,
            osVersion: viewModel.state.currentDeviceOS ?? "",
            status: .offline
        )
    }

    private var settingsControlsDisabled: Bool {
        setupViewModel.isDeviceDetectionReadOnly
            || !viewModel.environmentStatus.areAllChecksPassing
    }

    private func displayPath(_ path: String) -> String {
        guard !path.isEmpty else { return "选择 iOS 项目目录" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func copyDiagnosticReport() {
        let lines = [
            "iOSSignKit 诊断报告",
            "环境：\(viewModel.environmentStatus.summary)",
            "设备检测来源：\(viewModel.deviceScanSourceSummary)",
            "设备诊断：\(viewModel.deviceScanDiagnosticSummary ?? "无")",
            "最近错误：\(viewModel.lastErrorSummary)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedDiagnosticReport = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedDiagnosticReport = false
        }
    }
}
