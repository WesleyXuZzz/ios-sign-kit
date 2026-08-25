import Foundation
import Testing
@testable import IOSSignKit

struct PrimaryJourneyPresentationTests {
    @Test
    @MainActor
    func checkingDisablesBothHeaderActions() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.isReloadingEnvironment = true

        let presentation = viewModel.primaryJourneyPresentation
        let actions = presentation.headerActions
        let recheck = actions.first { $0.id == .recheck }
        let renew = actions.first { $0.id == .requestRefresh }

        #expect(presentation.phase == .checking)
        #expect(presentation.currentTask?.kind == .checking)
        #expect(presentation.header.title == "正在检查设备与安装状态")
        #expect(presentation.renewalIcon.motion == .checking)
        #expect(recheck?.title == "重新检查")
        #expect(renew?.title == "立即续签")
        #expect(recheck?.isEnabled == false)
        #expect(renew?.isEnabled == false)
    }

    @Test
    @MainActor
    func processRecoveryBlockerWinsOverEveryActiveTask() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.isReloadingEnvironment = true
        viewModel.pendingAutoRefreshCountdown = 4
        viewModel.state.isDeployRunning = true
        viewModel.state.deploymentRecoveryBlocked = true

        let presentation = viewModel.primaryJourneyPresentation

        #expect(presentation.phase == .blocked)
        #expect(presentation.currentTask?.kind == .processRecoveryBlocked)
        #expect(!presentation.deviceSelectionIsEnabled)
        #expect(
            presentation.headerActions.allSatisfy {
                if case .disabled(let reason) = $0.availability {
                    return !reason.isEmpty
                }
                return false
            }
        )
    }

    @Test
    @MainActor
    func historicalFailureIsPreviousResultAndNeverOffersRetry() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.state.lastResult = .failure
        viewModel.state.lastErrorSummary = "上次签名失败。"

        let presentation = viewModel.primaryJourneyPresentation
        let actionIDs = presentation.headerActions.map(\.id)
            + (presentation.currentTask?.actions.map(\.id) ?? [])

        #expect(presentation.phase == .waitingForDevice)
        #expect(presentation.header.title == "先重新确认设备状态")
        #expect(!presentation.header.title.contains("失败"))
        #expect(presentation.currentTask == nil)
        #expect(presentation.previousResult?.outcome == .failure)
        #expect(actionIDs.contains(.recheck))
        #expect(!actionIDs.contains(.retryCurrentRefresh))
    }

    @Test
    @MainActor
    func environmentFailureTakesAttentionWithoutReusingHistoricalFailure() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let device = DeviceInfo(
            id: "primary-device",
            name: "测试 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = makeResolvedPrimaryJourneyConfig()
        config.preferredDeviceID = device.id
        config.preferredDeviceName = device.name
        viewModel.config = config
        viewModel.environmentStatus = EnvironmentStatus(
            isXcodebuildAvailable: false,
            isXcrunAvailable: true,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "未找到 xcodebuild。"
        )
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device
        viewModel.state.lastResult = .failure
        viewModel.state.lastErrorSummary = "旧续签签名失败。"

        let presentation = viewModel.primaryJourneyPresentation

        #expect(presentation.phase == .attention)
        #expect(presentation.header.title == "运行环境需要处理")
        #expect(presentation.header.detail == "未找到 xcodebuild。")
        #expect(!presentation.header.detail.contains("旧续签"))
        #expect(presentation.previousResult?.outcome == .failure)
    }

    @Test
    @MainActor
    func transientCheckingCopyDoesNotPromoteHistoricalFailureToCurrentTask() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.deployMessage = "正在检查设备与安装状态..."
        viewModel.state.lastResult = .failure
        viewModel.state.lastErrorSummary = "上次签名失败。"

        let presentation = viewModel.primaryJourneyPresentation
        let actionIDs = presentation.headerActions.map(\.id)
            + (presentation.currentTask?.actions.map(\.id) ?? [])

        #expect(presentation.header.title == "先重新确认设备状态")
        #expect(presentation.currentTask == nil)
        #expect(presentation.previousResult?.outcome == .failure)
        #expect(!actionIDs.contains(.retryCurrentRefresh))
    }

    @Test
    @MainActor
    func informationalFeedbackKeepsStableOfflineHeaderSemantics() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.deployMessage = "无线配对成功，正在重新检查。"

        let presentation = viewModel.primaryJourneyPresentation

        #expect(presentation.phase == .waitingForDevice)
        #expect(presentation.header.title == "先重新确认设备状态")
        #expect(presentation.header.tone == .warning)
        #expect(presentation.currentTask?.kind == .currentFeedback)
        #expect(presentation.currentTask?.tone == .info)
        #expect(presentation.heroActions == presentation.headerActions)
    }

    @Test
    @MainActor
    func deployingRoutesItsControlsOnlyToTheActivityFocus() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.state.isDeployRunning = true

        let presentation = viewModel.primaryJourneyPresentation
        let taskActions = presentation.currentTask?.actions ?? []

        #expect(presentation.phase == .deploying)
        #expect(presentation.currentTask?.kind == .deploying)
        #expect(taskActions.map(\.id) == [.showDeployLog, .cancelRefresh])
        #expect(taskActions.allSatisfy { $0.placement == .task })
        #expect(presentation.heroActions.isEmpty)
        #expect(
            ActivityFocusCard.showsLiveOutput(
                for: presentation.currentTask
            )
        )
        #expect(
            ActivityFocusCard.taskCardActions(taskActions).map(\.id)
                == [.cancelRefresh]
        )
        #expect(
            presentation.currentTask.flatMap {
                ActivityFocusCard.liveOutputAction(for: $0)?.id
            } == .showDeployLog
        )
    }

    @Test
    @MainActor
    func readyJourneyUsesThreeMilestonesAndCurrentStatusHeader() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let device = DeviceInfo(
            id: "primary-device",
            name: "测试 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = makeResolvedPrimaryJourneyConfig()
        config.preferredDeviceID = device.id
        config.preferredDeviceName = device.name
        viewModel.config = config
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device

        let presentation = viewModel.primaryJourneyPresentation

        #expect(presentation.phase == .monitoring)
        #expect(presentation.header.title == "当前无需续期")
        #expect(presentation.verificationSteps.count == 3)
        #expect(
            presentation.verificationSteps.first {
                $0.id == .environment
            }?.value == "4 项检查已通过"
        )
        #expect(
            presentation.verificationSteps.first {
                $0.id == .environment
            }?.title == "环境已就绪"
        )
        #expect(
            presentation.verificationSteps.first {
                $0.id == .environment
            }?.systemImage == "checkmark"
        )
        #expect(
            presentation.verificationSteps.first {
                $0.id == .device
            }?.systemImage == "iphone"
        )
        #expect(
            presentation.verificationSteps.first {
                $0.id == .environment
            }?.detail == nil
        )
        #expect(presentation.targetDevice.detail == "固定设备 · 在线")
        #expect(presentation.targetDevice.badgeSystemImage == "wifi")

        let recheckAction = presentation.headerActions.first {
            $0.id == .recheck
        }
        let refreshAction = presentation.headerActions.first {
            $0.id == .requestRefresh
        }
        #expect(recheckAction?.style == .primary)
        #expect(refreshAction?.style == .secondary)
    }

    @Test
    @MainActor
    func expiredJourneyPromotesRefreshWithoutMakingItTheDefaultKeyAction() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let now = Date(timeIntervalSinceReferenceDate: 500_000)
        let device = DeviceInfo(
            id: "primary-device",
            name: "测试 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = makeResolvedPrimaryJourneyConfig()
        config.preferredDeviceID = device.id
        config.preferredDeviceName = device.name
        viewModel.config = config
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device
        viewModel.freezeVisualQAClock(at: now)
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: now.addingTimeInterval(-60),
            source: .storedEstimate,
            detectedAt: now,
            isFallbackValue: false
        )

        let presentation = viewModel.primaryJourneyPresentation
        let recheckAction = presentation.headerActions.first {
            $0.id == .recheck
        }
        let refreshAction = presentation.headerActions.first {
            $0.id == .requestRefresh
        }

        #expect(presentation.phase == .renewalRequired)
        #expect(recheckAction?.style == .secondary)
        #expect(refreshAction?.style == .primary)
    }

    @Test
    @MainActor
    func offlineJourneyUsesCompactDecisionOrientedMilestones() throws {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let calendar = Calendar.current
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 6,
                    hour: 14,
                    minute: 13
                )
            )
        )
        let lastDeviceSeenAt = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 6,
                    hour: 8,
                    minute: 13
                )
            )
        )
        let estimatedExpiryAt = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 8,
                    hour: 12,
                    minute: 5
                )
            )
        )

        var config = makeResolvedPrimaryJourneyConfig()
        config.preferredDeviceID = "primary-device"
        config.preferredDeviceName = "测试 iPhone"
        viewModel.config = config
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.state.currentDeviceStatus = .offline
        viewModel.state.currentDeviceName = "测试 iPhone"
        viewModel.state.lastDeviceSeenAt = lastDeviceSeenAt
        viewModel.freezeVisualQAClock(at: now)
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: estimatedExpiryAt,
            source: .storedEstimate,
            detectedAt: now,
            isFallbackValue: false
        )

        let presentation = viewModel.primaryJourneyPresentation
        let deviceStep = presentation.verificationSteps.first {
            $0.id == .device
        }
        let signingStep = presentation.verificationSteps.first {
            $0.id == .signing
        }

        #expect(deviceStep?.title == "设备离线")
        #expect(deviceStep?.value == "未检测到目标设备")
        #expect(deviceStep?.tone == .neutral)
        #expect(presentation.targetDevice.value == "测试 iPhone")
        #expect(signingStep?.title == "签名状态")
        #expect(signingStep?.value == "等待设备后可确认")
        #expect(signingStep?.tone == .neutral)
        #expect(deviceStep?.systemImage == "minus")
        #expect(signingStep?.systemImage == "minus")
        #expect(presentation.targetDevice.detail == "固定设备 · 离线")
        #expect(
            presentation.targetDevice.cardDetail
                == "最后在线：今天 08:13\nApp 已安装 · 到期 8/8 12:05"
        )
        #expect(
            presentation.header.detail
                == "签名剩余 1 天，设备连接后可立即续签\n请确认 iPhone 已解锁，并与 Mac 处于同一网络"
        )
        #expect(
            presentation.header.detail
                .components(separatedBy: "\n").count == 2
        )
        #expect(
            presentation.targetDevice.cardDetail?
                .components(separatedBy: "\n").count == 2
        )
        #expect(presentation.targetDevice.badgeSystemImage == "wifi.slash")
        #expect(presentation.verificationSteps.allSatisfy { $0.detail == nil })

        let pairingAction = presentation.headerActions.first {
            $0.id == .pairDevice
        }
        #expect(
            pairingAction?.title == "尝试配对"
        )
        #expect(
            pairingAction?.availability == .enabled
        )
    }

    @Test
    @MainActor
    func unpinnedOfflineJourneyStillAsksForADeviceSelection() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.state.currentDeviceStatus = .offline

        let refreshAction = viewModel.primaryJourneyPresentation.headerActions
            .first { $0.id == .requestRefresh }

        #expect(
            refreshAction?.availability
                == .disabled(
                    reason: "请先连接并选择一台可用的目标 iPhone。"
                )
        )
    }

    @Test
    @MainActor
    func stableHeaderUsesLatestFullVerificationEvidenceWithExpiryPriority() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let device = DeviceInfo(
            id: "primary-device",
            name: "测试 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = makeResolvedPrimaryJourneyConfig()
        config.preferredDeviceID = device.id
        config.preferredDeviceName = device.name
        viewModel.config = config
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device

        let appInspectionAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiryVerifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        viewModel.freezeVisualQAClock(at: now)
        viewModel.state.lastAppInspectionAt = appInspectionAt
        viewModel.state.lastExpiryVerifiedAt = expiryVerifiedAt

        let presentation = viewModel.primaryJourneyPresentation
        let expirySummary = VerificationTimePresentation.make(
            date: expiryVerifiedAt,
            now: now
        ).fullVerificationSummary
        let appSummary = VerificationTimePresentation.make(
            date: appInspectionAt,
            now: now
        ).fullVerificationSummary

        #expect(presentation.phase == .monitoring)
        #expect(
            presentation.header.detail
                == presentation.header.lastFullVerificationSummary
        )
        #expect(
            presentation.header.lastFullVerificationSummary
                == expirySummary
        )
        #expect(
            !presentation.header.lastFullVerificationSummary
                .contains(appSummary)
        )
    }

    @Test
    @MainActor
    func disabledActionRejectsWithItsConcretePresentationReason() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let action = viewModel.primaryJourneyPresentation.headerActions
            .first { $0.id == .requestRefresh }
        guard case .disabled(let reason) = action?.availability else {
            Issue.record("续签动作应携带不可用原因。")
            return
        }

        #expect(!reason.isEmpty)
        #expect(
            viewModel.performPrimaryJourneyAction(.requestRefresh)
                == .rejected(reason: reason)
        )
    }

    @Test
    @MainActor
    func requestRefreshKeepsManualSigningChoiceInTheExistingBusinessFlow() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        let device = DeviceInfo(
            id: "primary-device",
            name: "测试 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = makeResolvedPrimaryJourneyConfig()
        config.preferredDeviceID = device.id
        config.preferredDeviceName = device.name
        viewModel.config = config
        viewModel.environmentStatus = EnvironmentStatus(
            isXcodebuildAvailable: true,
            isXcrunAvailable: true,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "测试环境已就绪"
        )
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device

        #expect(
            viewModel.performPrimaryJourneyAction(.requestRefresh)
                == .manualSigningChoiceRequired
        )
        #expect(viewModel.manualRefreshPrompt != nil)
    }

    @Test
    @MainActor
    func historicalRetryCannotBeDispatched() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.state.lastResult = .failure
        viewModel.state.lastErrorSummary = "上次签名失败。"

        let outcome = viewModel.performPrimaryJourneyAction(
            .retryCurrentRefresh
        )

        #expect(
            outcome
                == .rejected(reason: "当前界面没有提供此操作。")
        )
        #expect(viewModel.manualRefreshPrompt == nil)
    }

    @Test
    @MainActor
    func previousResultAllowsSyntheticOpenHistoryAction() {
        let viewModel = makePrimaryJourneyViewModel()
        defer { viewModel.stopPolling() }

        viewModel.config = makeResolvedPrimaryJourneyConfig()
        viewModel.environmentStatus = makeReadyPrimaryJourneyEnvironment()
        viewModel.state.lastResult = .failure
        viewModel.state.lastErrorSummary = "上次签名失败。"

        #expect(viewModel.primaryJourneyPresentation.previousResult != nil)
        #expect(
            viewModel.performPrimaryJourneyAction(.openHistory)
                == .openHistory
        )
    }
}

@MainActor
private func makePrimaryJourneyViewModel() -> MenuBarViewModel {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ios-sign-kit-primary-journey-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    let stateStore = RefreshStateStore(appSupportDirectory: directoryURL)
    let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
        bootstrapper: AppBootstrapper(stateStore: stateStore),
        stateStore: stateStore
    )
    viewModel.stopPolling()
    return viewModel
}

private func makeResolvedPrimaryJourneyConfig() -> AppConfig {
    AppConfig(
        projectRootPath: "/tmp/example",
        deployScriptPath: "/tmp/example/scripts/deploy/ios-device.command",
        xcodeprojPath: "/tmp/example/App.xcodeproj",
        scheme: "App",
        targetName: "App",
        bundleID: "com.example.App",
        preferredDeviceID: nil,
        preferredDeviceName: nil,
        checkIntervalMinutes: 5,
        reminderCooldownHours: 24,
        startAtLogin: false,
        autoRefreshPolicy: .reminderOnly
    )
}

private func makeReadyPrimaryJourneyEnvironment() -> EnvironmentStatus {
    EnvironmentStatus(
        isXcodebuildAvailable: true,
        isXcrunAvailable: true,
        isProjectPathValid: true,
        isApplicationTargetResolved: true,
        summary: "测试环境已就绪"
    )
}
