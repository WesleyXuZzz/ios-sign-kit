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
        static let commandBarHeight: CGFloat = 56
        static let brandIconSize: CGFloat = 30
    }

    @ObservedObject var viewModel: MenuBarViewModel
    @ObservedObject var panelVisibility: MainPanelVisibilityState
    @State private var navigationState = NavigationState()
    @State private var isDiagnosticsPresented = false
    @State private var isDeployLogPresented = false
    @State private var selectedHistoryID: String?
    @AppStorage(InterfaceStyle.preferenceKey) private var storedInterfaceStyle = InterfaceStyle
        .native.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedEntry: PanelTab?
    @FocusState private var historyEntryFocused: Bool
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

        mutating func closeContentPage() {
            selectedTab = .status
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

    private var interfaceStyle: InterfaceStyle {
        InterfaceStyle(storedValue: storedInterfaceStyle)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            InterfaceCanvas()
            VStack(spacing: 0) {
                commandBar
                statusPage
            }
            .opacity(selectedTab == .status ? 1 : 0)
            .disabled(selectedTab != .status)
            .accessibilityHidden(selectedTab != .status)

            if selectedTab != .status {
                selectedTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { InterfaceCanvas() }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(minWidth: Layout.minimumWindowWidth, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : MotionTokens.easeOut(), value: selectedTab)
        .environment(\.interfaceStyle, interfaceStyle)
        .popover(isPresented: $isDiagnosticsPresented) {
            diagnosticsPopover.environment(\.interfaceStyle, interfaceStyle)
        }
        .alert("选择本次签名方式", isPresented: manualRefreshPromptIsPresented) {
            Button("更新签名描述文件并安装") {
                viewModel.confirmManualRefresh(profileRefreshMode: .force)
            }

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
            .environment(\.interfaceStyle, interfaceStyle)
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

    private var commandBar: some View {
        HStack(spacing: 10) {
            SidebarBrandIcon(
                presentation: viewModel.primaryJourneyPresentation.renewalIcon,
                statusDescription: viewModel.primaryJourneyPresentation.header.title,
                isAnimationActive: panelVisibility.isVisible && selectedTab == .status,
                size: Layout.brandIconSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("iOSSignKit")
                    .font(TypeTokens.cardTitle.bold())
                    .foregroundStyle(ColorTokens.Text.primary)
                Text(commandBarStatusText)
                    .font(TypeTokens.auxiliary)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .lineLimit(1)
                    .help(commandBarStatusText)
            }
            .frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 8)
            Text(statusPageDetail)
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)
                .lineLimit(1)
                .help(statusPageDetail)
            Button("诊断", systemImage: "stethoscope") {
                isDiagnosticsPresented.toggle()
            }
            .buttonStyle(RenewalButtonStyle(kind: .text))
            Button {
                showSettings(category: selectedSettingsCategory)
            } label: {
                Label("设置", systemImage: "gearshape")
                if viewModel.setupViewModel.hasUnsavedChanges {
                    Circle().fill(ColorTokens.Semantic.warning)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("有未保存更改")
                }
            }
            .buttonStyle(RenewalButtonStyle(kind: .text))
            .focused($focusedEntry, equals: .settings)
            Text(applicationVersionPresentation.sidebarText)
                .font(TypeTokens.auxiliary)
                .foregroundStyle(ColorTokens.Text.secondary)
                .help(applicationVersionPresentation.detailText)
                .accessibilityLabel(applicationVersionPresentation.detailText)
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.commandBarHeight)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            ColorTokens.Border.subtle.frame(height: 1)
        }
    }

    private func closeContentPage() {
        let previousPage = selectedTab
        navigationState.closeContentPage()
        if previousPage == .history {
            historyEntryFocused = true
        } else {
            focusedEntry = .settings
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .status:
            statusPage
        case .history:
            HistoryPanelView(
                viewModel: viewModel,
                onBackToStatus: closeContentPage,
                selectedEntryID: selectedHistoryID
            )
        case .settings:
            SettingsPanelView(
                viewModel: viewModel,
                setupViewModel: viewModel.setupViewModel,
                selectedCategory: Binding(
                    get: { selectedSettingsCategory },
                    set: { selectedSettingsCategory = $0 }
                ),
                onOpenDiagnostics: { isDiagnosticsPresented = true },
                initialScrollAnchor: settingsInitialScrollAnchor,
                interfaceStyle: Binding(
                    get: { interfaceStyle },
                    set: { storedInterfaceStyle = $0.rawValue }
                ),
                onClose: closeContentPage
            )
        }
    }

    private var statusPage: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                ScrollView {
                    ExpiryCommandCenterView(
                        presentation: viewModel.primaryJourneyPresentation,
                        deployLogText: viewModel.deployLogText,
                        onAction: handlePrimaryJourneyAction,
                        onDeviceSelectionRequested: { showSettings(category: .target) },
                        isAnimationActive: panelVisibility.isVisible && selectedTab == .status,
                        config: viewModel.config,
                        availableWidth: max(geometry.size.width - 40, 0),
                        minimumHeight: max(geometry.size.height - 90, 440)
                    )
                    .padding(.vertical, 2)
                }
                RecentHistoryStrip(
                    entries: viewModel.historyEntries, allHistoryFocus: $historyEntryFocused
                ) { entryID in
                    selectedHistoryID = entryID
                    selectedTab = .history
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
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

            if let automaticRefreshAuthorizationSummary =
                viewModel.automaticRefreshAuthorizationSummary {
                KeyValueRowView(
                    label: "自动续期判定",
                    value: automaticRefreshAuthorizationSummary
                )
            }

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

    private var commandBarStatusText: String {
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
            selectedHistoryID = nil
            selectedTab = .history
        case .showDeployLog:
            isDeployLogPresented = true
        case .rejected:
            break
        }
    }

    private func showSettings(category: SettingsPanelCategory) {
        navigationState.showSettings(category: category)
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
