import Foundation
import SwiftUI
import Testing

@testable import IOSSignKit

struct WorkspaceInterfaceTests {
    @Test
    @MainActor
    func elapsedTimeOnlyDescribesRunningWork() {
        #expect(!ActivityFocusCard.showsElapsedTime(for: .processRecoveryBlocked))
        #expect(!ActivityFocusCard.showsElapsedTime(for: .currentFeedback))
        #expect(ActivityFocusCard.showsElapsedTime(for: .deploying))
        #expect(ActivityFocusCard.showsElapsedTime(for: .checking))
    }

    @Test
    @MainActor
    func stylePreferenceRestoresAcrossReadersAndFallsBackForUnknownValues() throws {
        let suiteName = "interface-style-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preference = AppStorage(
            wrappedValue: InterfaceStyle.native.rawValue, InterfaceStyle.preferenceKey,
            store: defaults)
        #expect(InterfaceStyle(storedValue: preference.wrappedValue) == .native)
        for style in InterfaceStyle.allCases {
            preference.wrappedValue = style.rawValue
            let restored = AppStorage(
                wrappedValue: InterfaceStyle.native.rawValue, InterfaceStyle.preferenceKey,
                store: defaults)
            #expect(InterfaceStyle(storedValue: restored.wrappedValue) == style)
        }
        preference.wrappedValue = "unsupported-style"
        #expect(InterfaceStyle(storedValue: preference.wrappedValue) == .native)
        #expect(InterfaceStyle(storedValue: "") == .native)
    }

    @Test
    func transparencyPreferenceAlwaysWinsOverGlassStyle() {
        #expect(!InterfaceStyle.native.usesTransparency(reduceTransparency: false))
        #expect(!InterfaceStyle.native.usesTransparency(reduceTransparency: true))
        #expect(InterfaceStyle.glass.usesTransparency(reduceTransparency: false))
        #expect(!InterfaceStyle.glass.usesTransparency(reduceTransparency: true))
    }

    @Test
    func contentPageDismissalPreservesSettingsCategory() {
        var navigation = MainPanelView.NavigationState()
        #expect(navigation.selectedTab == .status)
        navigation.showSettings(category: .general)
        navigation.closeContentPage()
        #expect(navigation.selectedTab == .status)
        #expect(navigation.settingsCategory == .general)
        navigation.selectedTab = .history
        navigation.closeContentPage()
        #expect(navigation.settingsCategory == .general)
    }

    @Test(arguments: [CGFloat(820), 872, 1160])
    func bothColumnsFitTheAvailableWidth(_ width: CGFloat) {
        let layout = DashboardLayout(availableWidth: width)
        #expect(
            abs(layout.mainWidth + layout.sideWidth + DashboardLayout.columnGap - width) < 0.001)
        #expect(abs(layout.mainWidth / layout.sideWidth - 1.25) < 0.001)
        #expect(layout.sideWidth >= 350)
    }

    @Test
    @MainActor
    func idleDockSummarizesSavedPolicyAndBothCheckIntervals() {
        var config = AppConfig.default
        config.checkIntervalMinutes = 17
        config.expiredCheckIntervalMinutes = 3
        config.reminderCooldownHours = 48
        let reminder = RenewalPolicySummaryCard.summary(for: config)
        #expect(reminder.contains("到期时提醒"))
        #expect(reminder.contains("到期前每 17 分钟"))
        #expect(reminder.contains("到期后每 3 分钟"))
        #expect(reminder.contains("48 小时"))
        config.autoRefreshPolicy = .autoRefreshWhenExpired
        #expect(RenewalPolicySummaryCard.summary(for: config).contains("到期时自动刷新"))
    }
    @Test
    @MainActor
    func feedbackKeepsItsLogActionWhenTheLiveDockIsHidden() {
        let actions = [
            PrimaryJourneyAction(
                id: .showDeployLog, title: "查看日志", systemImage: "terminal", placement: .task,
                style: .quiet, availability: .enabled),
            PrimaryJourneyAction(
                id: .dismissFeedback, title: "关闭", systemImage: "xmark", placement: .task,
                style: .quiet, availability: .enabled),
        ]
        #expect(ActivityFocusCard.taskCardActions(actions, showsLiveOutput: false) == actions)
        #expect(
            ActivityFocusCard.taskCardActions(actions, showsLiveOutput: true).map(\.id) == [
                .dismissFeedback
            ])
    }

    @Test
    @MainActor
    func activityControlsPreserveRecoveryActionsAndDisabledAuthorization() {
        let actions = [
            PrimaryJourneyAction(
                id: .recoveryPreservingRecheck, title: "重新检查", systemImage: "arrow.clockwise",
                placement: .task, style: .primary, availability: .disabled(reason: "正在检查")),
            PrimaryJourneyAction(
                id: .cancelRecovery, title: "取消重试", systemImage: "xmark", placement: .task,
                style: .quiet, availability: .enabled),
        ]
        let displayed = ActivityFocusCard.taskCardActions(actions, showsLiveOutput: false)
        #expect(displayed == actions)
        #expect(!displayed[0].isEnabled)
        #expect(displayed[1].isEnabled)
    }

}
