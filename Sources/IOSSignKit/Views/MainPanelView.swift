import AppKit
import SwiftUI

@MainActor
final class MainPanelVisibilityState: ObservableObject {
    @Published private(set) var isVisible: Bool

    init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }

    func setVisible(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
}

struct MainPanelView: View {
    enum Layout {
        static let minimumWindowWidth: CGFloat = 860
        static let sidebarWidth: CGFloat = 200
    }

    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var panelVisibility: MainPanelVisibilityState
    @State private var navigationState = NavigationState()
    @State private var isDiagnosticsPresented = false
    @State private var isDeployLogPresented = false
    private let settingsInitialScrollAnchor: UnitPoint
    private let applicationVersionPresentation =
        ApplicationVersionPresentation.current

    init(
        viewModel: MenuBarViewModel,
        panelVisibility: MainPanelVisibilityState,
        initialTab: PanelTab = .status,
        settingsInitialScrollAnchor: UnitPoint = .top
    ) {
        self.viewModel = viewModel
        self.panelVisibility = panelVisibility
        self.settingsInitialScrollAnchor = settingsInitialScrollAnchor
        _navigationState = State(
            initialValue: NavigationState(selectedTab: initialTab)
        )
    }

    enum PanelTab: String, CaseIterable, Identifiable {
        case status = "状态"
        case history = "历史"
        case settings = "设置"

        var id: String { rawValue }

        private var preferredSystemImage: String {
            switch self {
            case .status:
                "waveform.path.ecg.rectangle"
            case .history:
                "list.bullet.rectangle"
            case .settings:
                "gearshape.fill"
            }
        }

        private var fallbackSystemImage: String {
            switch self {
            case .status:
                "waveform.path.ecg"
            case .history:
                "list.bullet"
            case .settings:
                "gearshape"
            }
        }

        var systemImage: String {
            if NSImage(
                systemSymbolName: preferredSystemImage,
                accessibilityDescription: nil
            ) != nil {
                return preferredSystemImage
            }

            if NSImage(
                systemSymbolName: fallbackSystemImage,
                accessibilityDescription: nil
            ) != nil {
                return fallbackSystemImage
            }

            return "circle"
        }
    }

    enum SidebarTabIconStyle {
        static let slotSize: CGFloat = 20
    }

    enum SidebarBrandIconStyle {
        static let size = SidebarBrandIcon.Layout.defaultSize
        static let reservedHeight: CGFloat = 140
    }

    struct NavigationState: Equatable {
        var selectedTab: PanelTab
        var settingsCategory: SettingsPanelCategory

        init(
            selectedTab: PanelTab = .status,
            settingsCategory: SettingsPanelCategory = .target
        ) {
            self.selectedTab = selectedTab
            self.settingsCategory = settingsCategory
        }

        mutating func showSettings(
            category: SettingsPanelCategory = .target
        ) {
            settingsCategory = category
            selectedTab = .settings
        }
    }

    private var selectedTab: PanelTab {
        get { navigationState.selectedTab }
        nonmutating set { navigationState.selectedTab = newValue }
    }

    private var selectedSettingsCategory: SettingsPanelCategory {
        get { navigationState.settingsCategory }
        nonmutating set { navigationState.settingsCategory = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(ColorTokens.Border.subtle)
                .frame(width: 1)
                .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
                selectedTabContent
                    .id(selectedTab)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(MotionTokens.easeOut(), value: selectedTab)
        }
        .background(ColorTokens.BG.canvas.ignoresSafeArea())
        .frame(
            minWidth: Layout.minimumWindowWidth,
            maxHeight: .infinity,
            alignment: .top
        )
        .onAppear {
            routeToSetupIfNeeded(for: viewModel.primaryJourneyPresentation.phase)
        }
        .onChange(of: viewModel.primaryJourneyPresentation.phase) { _, phase in
            routeToSetupIfNeeded(for: phase)
        }
        .alert("选择本次签名方式", isPresented: manualRefreshPromptIsPresented) {
            Button("更新签名描述文件并安装") {
                viewModel.confirmManualRefresh(profileRefreshMode: .force)
            }
            .keyboardShortcut(.defaultAction)

            Button("优先复用现有描述文件并安装") {
                viewModel.confirmManualRefresh(profileRefreshMode: .automatic)
            }

            Button("取消", role: .cancel) {
                viewModel.cancelManualRefreshProfileChoice()
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(viewModel.manualRefreshPromptMessage)
        }
        .sheet(isPresented: $isDeployLogPresented) {
            DeployLogPopover(
                logText: viewModel.deployLogText,
                onClose: { isDeployLogPresented = false }
            )
        }
    }

    private var manualRefreshPromptIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.manualRefreshPrompt != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelManualRefreshProfileChoice()
                }
            }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandArea

            VStack(spacing: 2) {
                ForEach(PanelTab.allCases) { tab in
                    tabButton(for: tab)
                }
            }

            Spacer(minLength: SpacingTokens.md)

            Button {
                isDiagnosticsPresented.toggle()
            } label: {
                sidebarUtilityLabel(systemName: "stethoscope", title: "诊断")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isDiagnosticsPresented, arrowEdge: .leading) {
                diagnosticsPopover
            }
            .help("显示诊断信息")
            .accessibilityLabel("诊断信息")

            Text(applicationVersionPresentation.sidebarText)
                .font(.system(size: 10))
                .foregroundStyle(ColorTokens.Text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 36)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .help(applicationVersionPresentation.detailText)
                .accessibilityLabel(applicationVersionPresentation.detailText)
        }
        .padding(.horizontal, 10)
        .frame(width: Layout.sidebarWidth, alignment: .leading)
        .background(.regularMaterial)
    }

    private var brandArea: some View {
        VStack(spacing: 6) {
            SidebarBrandIcon(
                presentation: viewModel.primaryJourneyPresentation.renewalIcon,
                statusDescription: viewModel.primaryJourneyPresentation.header.title,
                isAnimationActive: panelVisibility.isVisible,
                size: SidebarBrandIconStyle.size
            )

            Text("iOSSignKit")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ColorTokens.Text.primary)

            Text(sidebarStatusText)
                .font(.system(size: 11))
                .foregroundStyle(ColorTokens.Text.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: SidebarBrandIconStyle.reservedHeight, alignment: .top)
        .padding(.top, 8)
    }

    private func sidebarUtilityLabel(
        systemName: String,
        title: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(title)
                .font(TypeTokens.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ColorTokens.Text.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: SpacingTokens.ControlHeight.sidebarItem, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func tabButton(for tab: PanelTab) -> some View {
        Button {
            withAnimation(MotionTokens.easeOut()) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: SidebarTabIconStyle.slotSize, height: SidebarTabIconStyle.slotSize)
                    .foregroundStyle(
                        selectedTab == tab
                            ? ColorTokens.Accent.renew
                            : ColorTokens.Text.secondary
                    )
                    .accessibilityHidden(true)

                Text(tab.rawValue)
                    .font(TypeTokens.body.weight(selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(
                        selectedTab == tab
                            ? ColorTokens.Text.primary
                            : ColorTokens.Text.secondary
                    )

                Spacer(minLength: 0)

                if tab == .settings && viewModel.setupViewModel.hasUnsavedChanges {
                    Circle()
                        .fill(ColorTokens.Semantic.warning)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("有未保存更改")
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: SpacingTokens.ControlHeight.sidebarItem, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: SpacingTokens.Radius.control,
                    style: .continuous
                )
                .fill(
                    selectedTab == tab
                        ? ColorTokens.Accent.renew.opacity(0.14)
                        : Color.clear
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .status:
            statusPage
        case .history:
            ScrollView {
                HistoryPanelView(
                    viewModel: viewModel,
                    onBackToStatus: { selectedTab = .status }
                )
            }
            .scrollIndicators(.hidden)
        case .settings:
            SettingsPanelView(
                viewModel: viewModel,
                setupViewModel: viewModel.setupViewModel,
                selectedCategory: Binding(
                    get: { selectedSettingsCategory },
                    set: { selectedSettingsCategory = $0 }
                ),
                onOpenDiagnostics: { isDiagnosticsPresented = true },
                initialScrollAnchor: settingsInitialScrollAnchor
            )
        }
    }

    private var statusPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                pageHeader(
                    title: "状态",
                    detail: statusPageDetail
                )

                ExpiryCommandCenterView(
                    presentation: viewModel.primaryJourneyPresentation,
                    deployLogText: viewModel.deployLogText,
                    onAction: handlePrimaryJourneyAction,
                    onDeviceSelectionRequested: {
                        showSettings(category: .target)
                    },
                    isAnimationActive: panelVisibility.isVisible
                )
            }
            .padding(SpacingTokens.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private func pageHeader(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(TypeTokens.pageTitle)
                .foregroundStyle(ColorTokens.Text.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Text(detail)
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(ColorTokens.Accent.renew)
                Text("诊断")
                    .font(TypeTokens.cardTitle)
                    .foregroundStyle(ColorTokens.Text.primary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewModel.environmentStatus.checkItems.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Image(systemName: environmentCheckSystemImage(item.result))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(environmentCheckTone(item.result).color)
                            .frame(width: 16)
                        Text(item.title)
                            .font(TypeTokens.caption)
                            .foregroundStyle(ColorTokens.Text.primary)
                        Spacer(minLength: 8)
                        Text(environmentCheckAccessibilityText(item.result))
                            .font(TypeTokens.caption)
                            .foregroundStyle(ColorTokens.Text.secondary)
                    }
                }
            }

            Divider()

            KeyValueRowView(
                label: "应用版本",
                value: applicationVersionPresentation.marketingVersion ?? "不可用",
                detail: applicationVersionPresentation.buildVersion.map {
                    "构建 \($0)"
                }
            )

            KeyValueRowView(
                label: "设备检测来源",
                value: viewModel.deviceScanSourceSummary,
                detail: viewModel.deviceScanDiagnosticSummary
            )

            if shouldShowLastError {
                KeyValueRowView(
                    label: "最近错误",
                    value: viewModel.lastErrorSummary,
                    emphasizeValue: true,
                    valueTone: .critical
                )
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(ColorTokens.BG.surface)
    }

    private var statusPageDetail: String {
        if let task = viewModel.primaryJourneyPresentation.currentTask,
           task.kind != .currentFeedback
        {
            switch task.kind {
            case .checking:
                return "正在检查…"
            case .deploying:
                return "正在续签…"
            case .countdown:
                return "自动续期倒计时"
            case .recovering:
                return "等待设备恢复"
            case .processRecoveryBlocked:
                return "续签已阻止"
            case .currentFeedback:
                break
            }
        }
        return viewModel.primaryJourneyPresentation.header.lastFullVerificationSummary
    }

    private var sidebarStatusText: String {
        let presentation = viewModel.primaryJourneyPresentation
        let expiryText = presentation.header.remainingExpiryText
        switch presentation.phase {
        case .monitoring:
            return expiryText == "--"
                ? "签名有效"
                : "签名有效 · 还剩 \(expiryText)"
        case .renewalRequired:
            return "签名已过期"
        case .waitingForDevice:
            return "设备离线"
        case .needsSetup:
            return "待配置"
        case .checking:
            return "正在检查…"
        case .countdown:
            return "自动续期倒计时"
        case .recovering:
            return "等待设备恢复"
        case .deploying:
            return "正在续签…"
        case .completed:
            return "续签成功"
        case .attention:
            return "需要处理"
        case .blocked:
            return "已阻止"
        }
    }

    private func handlePrimaryJourneyAction(_ action: PrimaryJourneyAction) {
        switch viewModel.performPrimaryJourneyAction(action) {
        case .performed, .manualSigningChoiceRequired:
            break
        case .openHistory:
            withAnimation(MotionTokens.easeOut()) {
                selectedTab = .history
            }
        case .showDeployLog:
            isDeployLogPresented = true
        case .rejected:
            break
        }
    }

    private func routeToSetupIfNeeded(for phase: PrimaryJourneyPhase) {
        if phase == .needsSetup {
            navigationState.showSettings(category: .target)
        }
    }

    private func showSettings(category: SettingsPanelCategory) {
        withAnimation(MotionTokens.easeOut()) {
            navigationState.showSettings(category: category)
        }
    }

    private func environmentCheckSystemImage(
        _ result: EnvironmentCheckResult
    ) -> String {
        switch result {
        case .passed:
            "checkmark"
        case .failed:
            "xmark"
        case .uncertain:
            "questionmark"
        }
    }

    private func environmentCheckTone(
        _ result: EnvironmentCheckResult
    ) -> StatusTone {
        switch result {
        case .passed:
            .good
        case .failed:
            .critical
        case .uncertain:
            .neutral
        }
    }

    private func environmentCheckAccessibilityText(
        _ result: EnvironmentCheckResult
    ) -> String {
        switch result {
        case .passed:
            "已通过"
        case .failed:
            "未通过"
        case .uncertain:
            "待确认"
        }
    }

    private var shouldShowLastError: Bool {
        let value = viewModel.lastErrorSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "无"
    }
}

struct DeployLogPopover: View {
    let logText: String
    let onClose: (() -> Void)?
    let title: String

    init(
        logText: String,
        title: String = "续签日志 · 构建与安装",
        onClose: (() -> Void)? = nil
    ) {
        self.logText = logText
        self.title = title
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: "terminal")
                    .font(.headline.weight(.bold))

                Spacer(minLength: 0)

                Text("实时输出")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if let onClose {
                    Button("关闭", action: onClose)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                }
            }

            Divider()

            ScrollView {
                Text(displayedLogText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ColorTokens.Log.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(12)
            .background(ColorTokens.Log.background)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        ColorTokens.Log.border,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .frame(width: 560, height: 360)
    }

    private var displayedLogText: String {
        let trimmed = logText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "等待续签日志输出…" : trimmed
    }
}
