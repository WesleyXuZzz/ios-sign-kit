import Foundation
import Testing
@testable import IOSSignKit

struct StatusDetailsViewModelTests {
    @Test
    @MainActor
    func deviceIdentityDoesNotRepeatConnectionStatus() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }
        viewModel.state.currentDeviceName = "测试 iPhone"
        viewModel.state.currentDeviceOS = "26.4"
        viewModel.state.currentDeviceStatus = "wireless_pairing"
        viewModel.matchedDevice = nil

        #expect(viewModel.deviceIdentitySummary == "测试 iPhone · iOS 26.4")
        #expect(viewModel.deviceStatusRowValue == "测试 iPhone · iOS 26.4")
        #expect(viewModel.deviceStatusRowAnnotation == "正在无线配对")
        #expect(viewModel.deviceStatusSummary == "正在无线配对")
        #expect(viewModel.deviceStatusTone == .info)
        #expect(!(viewModel.deviceIdentitySummary?.contains("配对") ?? false))

        viewModel.matchedDevice = DeviceInfo(
            id: "iphone-1",
            name: "在线 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "26.5",
            isAvailable: true,
            isPaired: true
        )

        #expect(viewModel.deviceIdentitySummary == "在线 iPhone · iOS 26.5")
        #expect(viewModel.deviceStatusRowValue == "在线 iPhone · iOS 26.5")
        #expect(viewModel.deviceStatusRowAnnotation == "在线")
        #expect(viewModel.deviceStatusSummary == "在线")
        #expect(viewModel.deviceStatusTone == .good)
    }

    @Test
    @MainActor
    func deviceIdentityFallsBackToConfiguredNameWithoutInventingGenericTarget() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }
        viewModel.matchedDevice = nil
        viewModel.state.currentDeviceName = nil
        viewModel.state.currentDeviceOS = nil
        viewModel.state.currentDeviceStatus = "offline"
        viewModel.config.preferredDeviceName = "固定 iPhone"

        #expect(viewModel.deviceIdentitySummary == "固定 iPhone")
        #expect(viewModel.deviceStatusRowValue == "固定 iPhone")
        #expect(viewModel.deviceStatusRowAnnotation == "离线")

        viewModel.config.preferredDeviceName = "   "
        #expect(viewModel.deviceIdentitySummary == nil)
        #expect(viewModel.deviceStatusRowValue == "离线")
        #expect(viewModel.deviceStatusRowAnnotation == nil)
    }

    @Test
    @MainActor
    func deviceStatusBecomesPrimaryValueWhenScanFailsWithoutIdentity() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }
        viewModel.matchedDevice = nil
        viewModel.state.currentDeviceName = nil
        viewModel.state.currentDeviceOS = nil
        viewModel.config.preferredDeviceName = nil
        viewModel.state.currentDeviceStatus = "scan_failed"

        #expect(viewModel.deviceIdentitySummary == nil)
        #expect(viewModel.deviceStatusRowValue == "检测异常")
        #expect(viewModel.deviceStatusRowAnnotation == nil)
    }

    @Test
    @MainActor
    func deviceStatusesUseConciseCopyAndSemanticTones() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }
        viewModel.matchedDevice = nil
        let cases: [(DeviceStatus?, String, StatusTone)] = [
            (nil, "待检查", .neutral),
            ("unknown", "待检查", .neutral),
            ("confirming", "正在确认连接", .info),
            ("wireless_pairing", "正在无线配对", .info),
            ("wireless_pairing_confirmation_required", "等待 iPhone 确认", .warning),
            ("wireless_pairing_required", "等待无线连接恢复", .warning),
            ("xcode_update_required", "需升级 Xcode", .critical),
            ("wired_connection_required", "需用数据线重新配对", .warning),
            ("scan_failed", "检测异常", .critical),
            ("offline", "离线", .warning)
        ]

        for (status, expectedSummary, expectedTone) in cases {
            viewModel.state.currentDeviceStatus = status
            #expect(viewModel.deviceStatusSummary == expectedSummary)
            #expect(viewModel.deviceStatusTone == expectedTone)
        }
    }

    @Test
    @MainActor
    func scanPresentationSeparatesSourceAndPreservesDiagnostic() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }

        viewModel.state.lastDeviceScanSource = nil
        viewModel.state.lastDeviceScanFailure = nil
        #expect(viewModel.deviceScanSourceSummary == "尚未执行")
        #expect(viewModel.deviceScanDiagnosticSummary == nil)

        viewModel.state.lastDeviceScanSource = "xcdevice"
        #expect(viewModel.deviceScanSourceSummary == "xcdevice")
        #expect(viewModel.deviceScanDiagnosticSummary == "未发现异常")

        let completeDiagnostic = "Browsing on the local area network for Example iPhone. Ensure the device is unlocked and attached with a cable."
        viewModel.state.lastDeviceScanFailure = "  \(completeDiagnostic)  "
        #expect(viewModel.deviceScanDiagnosticSummary == completeDiagnostic)

        viewModel.state.lastDeviceScanSource = nil
        #expect(viewModel.deviceScanSourceSummary == "未知（扫描失败）")
        #expect(viewModel.deviceScanDiagnosticSummary == completeDiagnostic)

        viewModel.state.lastDeviceScanSource = "失败"
        #expect(viewModel.deviceScanSourceSummary == "未知（扫描失败）")
    }

    @Test
    @MainActor
    func expiryPresentationLabelsFallbackAndMetadataSources() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }
        let now = Date()

        viewModel.expiryInfo = nil
        #expect(viewModel.expirySummary == "尚未确认")
        #expect(viewModel.expiryDetailSummary == nil)
        #expect(viewModel.expiryStatusTone == .warning)

        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: nil,
            source: "deploy_time_estimate",
            detectedAt: now,
            isFallbackValue: true
        )
        #expect(viewModel.expirySummary == "尚未确认")
        #expect(viewModel.expiryDetailSummary == nil)

        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: now.addingTimeInterval(3_600),
            source: "deploy_time_estimate",
            detectedAt: now,
            isFallbackValue: true
        )
        #expect(viewModel.expiryDetailSummary == "来源：最近一次成功安装时间估算")
        #expect(viewModel.expiryStatusTone == .good)

        let metadata = AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: now,
            bundleIdentifier: "com.example.app",
            shortVersion: "1.0",
            buildVersion: "1",
            expectedExpiryAt: now.addingTimeInterval(3_600),
            profileSource: "embedded_mobileprovision"
        )
        viewModel.installedAppInfo = InstalledAppInfo(
            bundleIdentifier: "com.example.app",
            name: "Example App",
            version: "1.0",
            bundleVersion: "1",
            appURL: "Example.app",
            builtByDeveloper: true,
            installMetadata: metadata
        )
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: now.addingTimeInterval(3_600),
            source: .installMetadata(metadata.profileSource),
            detectedAt: now,
            isFallbackValue: false
        )
        #expect(viewModel.expiryDetailSummary == "来源：已安装 App 元信息 · embedded.mobileprovision")

        viewModel.expiryInfo?.estimatedExpiryAt = now.addingTimeInterval(-60)
        #expect(viewModel.expiryStatusTone == .critical)
    }

    @Test
    @MainActor
    func lastSeenUsesFormalEmptyState() {
        let viewModel = makeStatusDetailsViewModel()
        defer { viewModel.stopPolling() }
        viewModel.state.lastDeviceSeenAt = nil

        #expect(viewModel.lastDeviceSeenSummary == "暂无记录")
    }
}

@MainActor
private func makeStatusDetailsViewModel() -> MenuBarViewModel {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ios-sign-kit-status-details-tests-\(UUID().uuidString)", isDirectory: true)
    let stateStore = RefreshStateStore(appSupportDirectory: directoryURL)

    return MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
        bootstrapper: AppBootstrapper(stateStore: stateStore),
        stateStore: stateStore,
        notificationService: ScheduledNotificationStub()
    )
}
