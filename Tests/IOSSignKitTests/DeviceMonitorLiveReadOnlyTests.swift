import Foundation
import Testing
@testable import IOSSignKit

struct DeviceMonitorLiveReadOnlyTests {
    @Test
    func nearbyPhysicalDeviceCanBeObservedWithoutMutation() async throws {
        guard ProcessInfo.processInfo.environment[
            "IOS_SIGN_KIT_RUN_LIVE_DEVICE_READ_ONLY"
        ] == "1" else {
            return
        }

        let monitor = DeviceMonitor()
        let inventory = try await monitor.scanInventory(
            purpose: .interactive
        )
        let discoveredDevice = try #require(inventory.devices.first)
        let stableID = try #require(StableDeviceID(discoveredDevice.id))

        let observation = try await monitor.observeTarget(
            .stableID(stableID, displayName: discoveredDevice.name),
            purpose: .interactive
        )
        guard case .matched(let observedDevice) = observation.evidence else {
            Issue.record(
                "只读真机观察未返回 matched：\(observation.diagnostics.summary ?? "无诊断")"
            )
            return
        }

        #expect(observedDevice.id == stableID.value)
        #expect(observedDevice.isAvailable)
        #expect(observedDevice.isPaired)
    }

    @Test
    func nearbyPhysicalDeviceLockStateUsesSupportedSchema() async throws {
        guard ProcessInfo.processInfo.environment[
            "IOS_SIGN_KIT_RUN_LIVE_DEVICE_READ_ONLY"
        ] == "1" else {
            return
        }

        let monitor = DeviceMonitor()
        let inventory = try await monitor.scanInventory(
            purpose: .interactive
        )
        let discoveredDevice = try #require(inventory.devices.first)
        let observation = await DeviceLockStateInspector()
            .inspectObservation(device: discoveredDevice)

        guard case .determined(let state, let evidence) = observation else {
            let diagnostic = observation.failure?.localizedDescription
                ?? "无诊断"
            Issue.record("只读真机锁态查询无法识别：\(diagnostic)")
            return
        }

        #expect(state == .locked || state == .unlocked)
        #expect(evidence == .passcodeRequired)
    }
}
