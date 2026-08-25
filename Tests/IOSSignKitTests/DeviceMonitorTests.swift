import Foundation
import Testing
@testable import IOSSignKit

struct DeviceMonitorTests {
    @Test
    func observationKeepsTrustedMatchWhenWirelessTunnelIsDisconnected() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Nearby iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Nearby iPhone",
                    udid: "iphone-1",
                    connectionState: nil,
                    tunnelState: "disconnected",
                    pairingState: "paired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        let observation = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Nearby iPhone"),
            purpose: .interactive
        )

        guard case .matched(let device) = observation.evidence else {
            Issue.record("可信正向证据不应被无线隧道未建立降级为冲突")
            return
        }
        #expect(device.id == "iphone-1")
        #expect(observation.diagnostics.quality == .degraded)
        #expect(observation.diagnostics.source == .xcdevice)
        #expect(observation.diagnostics.summary?.contains("tunnelState=disconnected") == true)
        #expect(runner.invocations.map(\.arguments.first) == ["xcdevice", "devicectl"])
    }

    @Test
    func observationKeepsExplicitDeviceUnavailabilityAsHardConflict() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(id: "iphone-1", name: "Nearby iPhone")
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Nearby iPhone",
                    udid: "iphone-1",
                    available: false,
                    connectionState: nil,
                    tunnelState: "disconnected",
                    pairingState: "paired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        let observation = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Nearby iPhone"),
            purpose: .interactive
        )

        #expect(observation.evidence == .conflict)
        #expect(observation.diagnostics.quality == .complete)
    }

    @Test
    func failedSourceCannotConfirmAbsence() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(result: .failure(stderr: "CoreDevice service unavailable"))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        let observation = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Nearby iPhone"),
            purpose: .interactive
        )

        #expect(observation.evidence == .inconclusive)
        #expect(observation.diagnostics.quality == .degraded)
    }

    @Test
    func thrownDeviceCtlFailureDegradesTrustedXCDeviceMatch() async throws {
        let monitor = DeviceMonitor(runCommand: { _, arguments, _ in
            if arguments.first == "xcdevice" {
                return .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Nearby iPhone"
                    )
                )
            }
            throw DeviceMonitorError.commandFailed(
                "CoreDevice service unavailable"
            )
        })
        let targetID = try #require(StableDeviceID("iphone-1"))

        let observation = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Nearby iPhone"),
            purpose: .interactive
        )

        guard case .matched(let device) = observation.evidence else {
            Issue.record("devicectl 抛错不应抹除 xcdevice 的可信正向证据")
            return
        }
        #expect(device.id == targetID.value)
        #expect(observation.diagnostics.quality == .degraded)
        #expect(
            observation.diagnostics.summary?
                .contains("CoreDevice service unavailable") == true
        )
    }

    @Test
    func partialSourceCannotAuthorizeDeployment() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(id: "iphone-1", name: "Nearby iPhone")
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSONWithoutCanonicalID(
                    id: "coredevice-1",
                    name: "Nearby iPhone"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        do {
            _ = try await monitor.verifyDeploymentTarget(
                .stableID(targetID, displayName: "Nearby iPhone")
            )
            Issue.record("部分来源结果不得构造续签目标")
        } catch let error as DeviceMonitorError {
            #expect(error.localizedDescription.contains("未全部返回完整结果"))
        }
    }

    @Test
    func deploymentStartTargetAuthorizationSeparatesVerifiedAndCompatibilityEvidence()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Nearby iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Nearby iPhone",
                    udid: "iphone-1",
                    connectionState: "connected",
                    tunnelState: "connected",
                    pairingState: "paired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))
        let verifiedTarget = try await monitor.verifyDeploymentTarget(
            .stableID(targetID, displayName: "Nearby iPhone")
        )
        let compatibilityTarget = try CompatibilityDeploymentTarget(
            device: verifiedTarget.device,
            availableDevices: [verifiedTarget.device]
        )
        let verifiedStart = DeploymentStartTarget.verified(
            verifiedTarget
        )
        let compatibilityStart = DeploymentStartTarget.compatibility(compatibilityTarget)

        #expect(verifiedStart.isAuthorized(for: .production))
        #expect(!verifiedStart.isAuthorized(for: .fallback))
        #expect(!verifiedStart.isAuthorized(for: .shadow))
        #expect(!verifiedStart.isAuthorized(for: .readOnly))
        #expect(!compatibilityStart.isAuthorized(for: .production))
        #expect(compatibilityStart.isAuthorized(for: .fallback))
        #expect(compatibilityStart.isAuthorized(for: .shadow))
        #expect(!compatibilityStart.isAuthorized(for: .readOnly))
    }

    @Test
    func uncertainSameNameDifferentIDBlocksDeploymentTarget() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Shared iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-2",
                    name: "Shared iPhone",
                    udid: "iphone-2",
                    osVersion: "27.0",
                    connectionState: nil,
                    tunnelState: "disconnected",
                    pairingState: "paired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        do {
            _ = try await monitor.verifyDeploymentTarget(
                .stableID(targetID, displayName: "Shared iPhone")
            )
            Issue.record("同名不同 ID 的不确定记录必须阻断续签")
        } catch let error as DeploymentTargetError {
            #expect(error == .ambiguousDeviceName("Shared iPhone"))
            #expect(
                error.localizedDescription
                    == "检测到多台名为“Shared iPhone”的 iPhone。为避免续签到错误设备，本次续签已停止；请断开或重命名同名设备，或在项目配置中重新选择并固定目标设备。"
            )
        }
    }

    @Test
    func cancellationStopsTheActiveCommandWithoutRetryingFallbacks() async throws {
        let recorder = AsyncCommandInvocationRecorder()
        let monitor = DeviceMonitor(runCommandAsync: { _, _, _ in
            recorder.record()
            try await Task.sleep(for: .seconds(30))
            return CommandResult(standardOutput: "[]", standardError: "", terminationStatus: 0)
        })
        let task = Task {
            try await monitor.scanAvailableIPhones(
                options: .reliable(preferredDeviceID: "iphone-1", preferredDeviceName: nil)
            )
        }

        while recorder.callCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("取消后的扫描不应返回成功结果")
        } catch is CancellationError {
            // Expected.
        }
        #expect(recorder.callCount == 1)
    }

    @Test
    func usesXCDeviceWhenItFindsAnAvailableIPhone() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: xcdeviceJSON(id: "iphone-1", name: "Example iPhone")))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .polling(preferredDeviceID: "iphone-1")
        )

        #expect(result.source == .xcdevice)
        #expect(result.devices.map(\.id) == ["iphone-1"])
        #expect(runner.invocations.map(\.arguments.first) == ["xcdevice"])
    }

    @Test
    func inventoryMarksXCDeviceRecordsWithoutStableIdentityAsIncomplete() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: """
                    [
                      {
                        "simulator": false,
                        "available": true,
                        "platform": "com.apple.platform.iphoneos",
                        "identifier": " ",
                        "name": "Example iPhone",
                        "operatingSystemVersion": "27.0"
                      },
                      {
                        "simulator": false,
                        "available": true,
                        "platform": "com.apple.platform.iphoneos",
                        "identifier": "iphone-2",
                        "name": " ",
                        "operatingSystemVersion": "27.0"
                      }
                    ]
                    """
                )
            ),
            .init(result: .success(), outputFileContents: #"{"result":{"devices":[]}}"#)
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanInventory(purpose: .backgroundDiscovery)

        #expect(result.devices.isEmpty)
        #expect(result.identityResolution == .incomplete)
        #expect(result.diagnostics.quality == .degraded)
    }

    @Test
    func completeUniqueInventoryExposesCanonicalIdentityPersistenceCandidate()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Nearby iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Nearby iPhone",
                    udid: "iphone-1",
                    connectionState: nil,
                    tunnelState: "disconnected",
                    pairingState: "paired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let inventory = try await monitor.scanInventory(
            purpose: .backgroundDiscovery
        )

        #expect(inventory.identityResolution == .complete)
        #expect(
            inventory.identityPersistenceCandidate?.deviceID.value
                == "iphone-1"
        )
        #expect(
            inventory.identityPersistenceCandidate?.displayName
                == "Nearby iPhone"
        )
    }

    @Test
    func partialInventoryNeverExposesIdentityPersistenceCandidate()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Nearby iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSONWithoutCanonicalID(
                    id: "coredevice-1",
                    name: "Nearby iPhone"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let inventory = try await monitor.scanInventory(
            purpose: .backgroundDiscovery
        )

        #expect(inventory.identityResolution == .incomplete)
        #expect(inventory.identityPersistenceCandidate == nil)
    }

    @Test
    func multipleDistinctCanonicalInventoryIdentitiesRemainCompleteWithoutPersistence()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "First iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-2",
                    name: "Second iPhone",
                    udid: "iphone-2"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let inventory = try await monitor.scanInventory(
            purpose: .backgroundDiscovery
        )

        #expect(inventory.identityResolution == .complete)
        #expect(inventory.identityPersistenceCandidate == nil)
    }

    @Test
    func conflictingNamesForOneCanonicalIdentityBlockAutomaticPersistence()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Old iPhone Name"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "New iPhone Name",
                    udid: "iphone-1"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let inventory = try await monitor.scanInventory(
            purpose: .backgroundDiscovery
        )

        #expect(inventory.identityResolution == .ambiguous)
        #expect(inventory.identityPersistenceCandidate == nil)
    }

    @Test
    func completeCompatibilityNameObservationExposesCanonicalMigrationCandidate()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Compatibility iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Compatibility iPhone",
                    udid: "iphone-1"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let observation = try await monitor.observeTarget(
            .compatibilityName("Compatibility iPhone"),
            purpose: .background
        )

        #expect(
            observation.identityPersistenceCandidate?.deviceID.value
                == "iphone-1"
        )
        #expect(
            runner.invocations.map(\.arguments.first)
                == ["xcdevice", "devicectl"]
        )
    }

    @Test
    func degradedCompatibilityNameObservationNeverExposesMigrationCandidate()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Compatibility iPhone"
                    )
                )
            ),
            .init(
                result: .failure(
                    stderr: "CoreDevice service unavailable"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let observation = try await monitor.observeTarget(
            .compatibilityName("Compatibility iPhone"),
            purpose: .interactive
        )

        guard case .matched = observation.evidence else {
            Issue.record("单来源正向证据仍应维持降级在线展示")
            return
        }
        #expect(observation.diagnostics.quality == .degraded)
        #expect(observation.identityPersistenceCandidate == nil)
    }

    @Test
    func fallsBackToDeviceCtlWhenXCDeviceDoesNotFindTarget() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(result: .success(), outputFileContents: devicectlJSON(id: "iphone-2", name: "Wi-Fi iPhone"))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .reliable(preferredDeviceID: "iphone-2")
        )

        #expect(result.source == .devicectl)
        #expect(result.devices.map(\.id) == ["iphone-2"])
        #expect(runner.invocations.map(\.arguments.first) == ["xcdevice", "devicectl"])
        #expect(result.diagnostics.sourceOutcomes.map(\.result) == [.completedWithoutTarget, .matchedTarget])
    }

    @Test
    func compatibilityInventoryConflictAndCanonicalMatchShareTheSameSourceSnapshot()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Example iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Example iPhone",
                    udid: "iphone-1",
                    connectionState: nil,
                    tunnelState: "disconnected",
                    pairingState: "paired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let options = DeviceScanOptions(
            preferredDeviceID: "iphone-1",
            preferredDeviceName: nil,
            attemptCount: 1,
            retryDelaySeconds: 0,
            commandTimeoutSeconds: 1,
            usesDevicectlFallback: true,
            requiresCompleteInventory: true
        )

        let compared = try await monitor
            .scanAvailableIPhonesWithCanonicalComparison(
            options: options
        )
        let result = compared.primary

        #expect(result.devices.isEmpty)
        #expect(result.unavailableTarget?.id == "iphone-1")
        #expect(result.conflictingDeviceIDs == ["iphone-1"])
        #expect(
            result.hasAvailabilityConflict(
                preferredDeviceID: "iphone-1"
            )
        )
        #expect(
            compared.projections.compatibility.classification == .conflict
        )
        #expect(
            compared.projections.canonical.classification == .matched
        )
        #expect(compared.projections.sourceCommandCount == 2)
    }

    @Test
    func compatibilityProjectionRejectsPartialXCDeviceMatchWhileCanonicalUsesItAsDegradedEvidence()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: partialXCDeviceJSON(
                        id: "iphone-1",
                        name: "Example iPhone"
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: #"{"result":{"devices":[]}}"#
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        let compared = try await monitor
            .observeTargetWithCompatibilityComparison(
                .stableID(
                    targetID,
                    displayName: "Example iPhone"
                ),
                purpose: .interactive,
                compatibilityOptions: .polling(
                    preferredDeviceID: targetID.value
                )
            )

        #expect(
            compared.projections.compatibility.classification
                == .inconclusive
        )
        #expect(
            compared.projections.canonical.classification == .matched
        )
        #expect(compared.projections.compatibility.quality == .degraded)
        #expect(compared.projections.canonical.quality == .degraded)
        #expect(compared.projections.sourceCommandCount == 2)
    }

    @Test
    func compatibilityProjectionPreservesSecondSourceEarlyMatch()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Example iPhone",
                        available: false
                    )
                )
            ),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Example iPhone",
                    udid: "iphone-1"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        let compared = try await monitor
            .observeTargetWithCompatibilityComparison(
                .stableID(
                    targetID,
                    displayName: "Example iPhone"
                ),
                purpose: .interactive,
                compatibilityOptions: .polling(
                    preferredDeviceID: targetID.value
                )
            )

        #expect(
            compared.projections.compatibility.classification == .matched
        )
        #expect(
            compared.projections.canonical.classification == .conflict
        )
        #expect(compared.projections.sourceCommandCount == 2)
    }

    @Test
    func compatibilityNonInventoryMissRemainsInconclusive()
        async throws
    {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(
                result: .success(),
                outputFileContents: #"{"result":{"devices":[]}}"#
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let targetID = try #require(StableDeviceID("iphone-1"))

        let compared = try await monitor
            .observeTargetWithCompatibilityComparison(
                .stableID(
                    targetID,
                    displayName: "Example iPhone"
                ),
                purpose: .interactive,
                compatibilityOptions: .polling(
                    preferredDeviceID: targetID.value
                )
            )

        #expect(
            compared.projections.compatibility.classification
                == .inconclusive
        )
        #expect(
            compared.projections.canonical.classification
                == .confirmedAbsent
        )
        #expect(compared.projections.sourceCommandCount == 2)
    }

    @Test
    func nameOnlyConflictIsScopedToThePreferredDevice() {
        let unavailableDevice = UnavailableDeviceInfo(
            id: "conflicting-iphone",
            name: "Conflicting iPhone",
            osVersion: "18.5",
            pairingState: "paired",
            connectionState: "connected",
            tunnelState: "disconnected",
            developerModeStatus: "enabled",
            diagnosticMessage: "tunnelState=disconnected"
        )
        let result = DeviceScanResult(
            devices: [],
            source: .none,
            unavailableTarget: unavailableDevice,
            unavailableDevices: [unavailableDevice],
            conflictingDeviceIDs: ["conflicting-iphone"],
            isCompleteInventory: true,
            diagnostics: DeviceScanDiagnostics(
                attempts: 1,
                message: nil,
                sourceOutcomes: []
            )
        )

        #expect(
            result.hasAvailabilityConflict(
                preferredDeviceID: nil,
                preferredDeviceName: "Conflicting iPhone"
            )
        )
        #expect(
            !result.hasAvailabilityConflict(
                preferredDeviceID: nil,
                preferredDeviceName: "Other iPhone"
            )
        )
        #expect(
            result.hasAvailabilityConflict(
                preferredDeviceID: nil,
                preferredDeviceName: nil
            )
        )
    }

    @Test
    func pollingFallsBackToDeviceCtlWhenXCDeviceTimesOut() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .failure(stderr: "Command timed out after 6.0 seconds.")),
            .init(result: .success(), outputFileContents: devicectlJSON(id: "iphone-1", name: "Example iPhone"))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .polling(preferredDeviceID: "iphone-1")
        )

        #expect(result.source == .devicectl)
        #expect(result.devices.map(\.id) == ["iphone-1"])
        #expect(result.diagnostics.sourceOutcomes.map(\.result) == [.failed, .matchedTarget])
        #expect(runner.invocations.map(\.arguments.first) == ["xcdevice", "devicectl"])
    }

    @Test
    func deviceCtlKeepsConnectedDeviceWhenTunnelIsUnavailable() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "USB iPhone",
                    udid: "iphone-udid-1",
                    tunnelState: "unavailable"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .reliable(preferredDeviceID: "iphone-udid-1")
        )

        #expect(result.source == .devicectl)
        #expect(result.devices.map(\.id) == ["iphone-udid-1"])
    }

    @Test
    func pollingRetainsMatchedUnavailableXCDevice() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: .success(
                    stdout: xcdeviceJSON(
                        id: "iphone-1",
                        name: "Updated iPhone",
                        available: false,
                        osVersion: "26.5.2 (23F84)",
                        recoverySuggestion: "Ensure the device is unlocked and attached with a cable."
                    )
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .polling(preferredDeviceID: "iphone-1")
        )

        #expect(result.devices.isEmpty)
        #expect(result.source == .xcdevice)
        #expect(result.unavailableTarget?.id == "iphone-1")
        #expect(result.unavailableTarget?.osMajorVersion == 26)
        #expect(result.unavailableTarget?.diagnosticMessage?.contains("attached with a cable") == true)
    }

    @Test
    func deviceCtlTreatsUnavailableWirelessTunnelWithoutGlobalEvidenceAsInconclusive() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Wireless iPhone",
                    udid: "iphone-udid-1",
                    osVersion: "27.0",
                    connectionState: nil,
                    tunnelState: "unavailable"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let targetID = try #require(StableDeviceID("iphone-udid-1"))
        let result = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Wireless iPhone"),
            purpose: .recovery
        )

        #expect(result.evidence == .inconclusive)
        #expect(result.recoveryCandidate?.deviceID == targetID)
        #expect(result.recoveryCandidate?.reason == .wirelessTransportUnavailable)
        #expect(result.diagnostics.source == .devicectl)
    }

    @Test
    func deviceCtlTreatsExplicitlyUnpairedDeviceAsUnavailable() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-1",
                    name: "Nearby iPhone",
                    udid: "iphone-udid-1",
                    osVersion: "27.0",
                    connectionState: "connected",
                    tunnelState: "connected",
                    pairingState: "unpaired"
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .automaticRecovery(preferredDeviceID: "iphone-udid-1")
        )

        #expect(result.devices.isEmpty)
        #expect(result.unavailableTarget?.pairingState == "unpaired")
    }

    @Test
    func deviceCtlRequiresPositiveAvailabilityEvidence() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-unknown",
                    name: "Unknown iPhone",
                    connectionState: nil,
                    tunnelState: nil,
                    pairingState: nil
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let targetID = try #require(
            StableDeviceID("coredevice-unknown")
        )
        let result = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Unknown iPhone"),
            purpose: .recovery
        )

        #expect(result.evidence == .inconclusive)
    }

    @Test
    func deviceCtlDoesNotTreatConnectingAsConnected() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(
                result: .success(),
                outputFileContents: devicectlJSON(
                    id: "coredevice-connecting",
                    name: "Connecting iPhone",
                    connectionState: "connecting",
                    tunnelState: nil,
                    pairingState: nil
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let targetID = try #require(
            StableDeviceID("coredevice-connecting")
        )
        let result = try await monitor.observeTarget(
            .stableID(targetID, displayName: "Connecting iPhone"),
            purpose: .recovery
        )

        #expect(result.evidence == .inconclusive)
    }

    @Test
    func refusesToDecodeTruncatedXCDeviceJSON() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(
                result: CommandResult(
                    standardOutput: xcdeviceJSON(id: "iphone-1", name: "Example iPhone"),
                    standardError: "",
                    terminationStatus: 0,
                    standardOutputWasTruncated: true
                )
            )
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let options = DeviceScanOptions(
            preferredDeviceID: "iphone-1",
            preferredDeviceName: nil,
            attemptCount: 1,
            retryDelaySeconds: 0,
            commandTimeoutSeconds: 1,
            usesDevicectlFallback: false
        )

        do {
            _ = try await monitor.scanAvailableIPhones(options: options)
            Issue.record("截断的结构化结果不应被当作完整设备列表。")
        } catch let error as DeviceMonitorError {
            #expect(error.localizedDescription.contains("JSON 过大"))
        }
    }

    @Test
    func pollingFallsBackToDeviceCtlWhenXCDeviceDoesNotFindTarget() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(result: .success(), outputFileContents: devicectlJSON(id: "iphone-2", name: "Wi-Fi iPhone"))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)

        let result = try await monitor.scanAvailableIPhones(
            options: .polling(preferredDeviceID: "iphone-2")
        )

        #expect(result.source == .devicectl)
        #expect(result.devices.map(\.id) == ["iphone-2"])
        #expect(runner.invocations.map(\.arguments.first) == ["xcdevice", "devicectl"])
    }

    @Test
    func retriesAfterATransientMiss() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(result: .success(stdout: xcdeviceJSON(id: "iphone-1", name: "Example iPhone")))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let options = DeviceScanOptions(
            preferredDeviceID: "iphone-1",
            preferredDeviceName: nil,
            attemptCount: 2,
            retryDelaySeconds: 0,
            commandTimeoutSeconds: 1,
            usesDevicectlFallback: false
        )

        let result = try await monitor.scanAvailableIPhones(options: options)

        #expect(result.source == .xcdevice)
        #expect(result.devices.map(\.id) == ["iphone-1"])
        #expect(result.diagnostics.attempts == 2)
    }

    @Test
    func returnsEmptyResultWhenRepeatedScansFindNoDevice() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .success(stdout: "[]")),
            .init(result: .success(stdout: "[]"))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let options = DeviceScanOptions(
            preferredDeviceID: "iphone-1",
            preferredDeviceName: nil,
            attemptCount: 2,
            retryDelaySeconds: 0,
            commandTimeoutSeconds: 1,
            usesDevicectlFallback: false
        )

        let result = try await monitor.scanAvailableIPhones(options: options)

        #expect(result.source == .none)
        #expect(result.devices.isEmpty)
        #expect(result.diagnostics.message == "未发现可用 iPhone。")
    }

    @Test
    func reportsDiagnosticWhenAllDeviceSourcesFail() async throws {
        let runner = ScriptedDeviceCommandRunner(responses: [
            .init(result: .failure(stderr: "xcdevice failed")),
            .init(result: .failure(stderr: "devicectl timed out"))
        ])
        let monitor = DeviceMonitor(runCommand: runner.run)
        let options = DeviceScanOptions(
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            attemptCount: 1,
            retryDelaySeconds: 0,
            commandTimeoutSeconds: 1,
            usesDevicectlFallback: true
        )

        do {
            _ = try await monitor.scanAvailableIPhones(options: options)
            Issue.record("Expected device scan to fail.")
        } catch let error as DeviceMonitorError {
            #expect(error.errorDescription?.contains("xcdevice failed") == true)
            #expect(error.errorDescription?.contains("devicectl timed out") == true)
        }
    }
}

private final class AsyncCommandInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct DeviceConnectionStabilizerTests {
    @Test
    func holdsRecentMissAsConfirming() {
        let stabilizer = DeviceConnectionStabilizer(confirmationInterval: 30, requiredAbsenceCount: 2)
        let now = Date(timeIntervalSinceReferenceDate: 120)

        let status = stabilizer.resolve(
            evidence: .targetAbsent,
            lastSeenAt: now.addingTimeInterval(-20),
            confirmationStartedAt: now.addingTimeInterval(-5),
            confirmedAbsenceCount: 1,
            now: now
        )

        #expect(status == .confirming)
    }

    @Test
    func marksOfflineOnlyAfterConfirmedAbsencesSpanWindow() {
        let stabilizer = DeviceConnectionStabilizer(confirmationInterval: 30, requiredAbsenceCount: 2)
        let now = Date(timeIntervalSinceReferenceDate: 120)

        let status = stabilizer.resolve(
            evidence: .targetAbsent,
            lastSeenAt: now.addingTimeInterval(-20),
            confirmationStartedAt: now.addingTimeInterval(-30),
            confirmedAbsenceCount: 2,
            now: now
        )

        #expect(status == .offline)
    }

    @Test
    func scanFailuresNeverBecomeOffline() {
        let stabilizer = DeviceConnectionStabilizer(confirmationInterval: 30, requiredAbsenceCount: 2)
        let now = Date(timeIntervalSinceReferenceDate: 120)

        let status = stabilizer.resolve(
            evidence: .scanFailed,
            lastSeenAt: now.addingTimeInterval(-120),
            confirmationStartedAt: now.addingTimeInterval(-30),
            confirmedAbsenceCount: 0,
            now: now
        )

        #expect(status == .scanFailed)
    }

    @Test
    func onlineEvidenceImmediatelyWins() {
        let stabilizer = DeviceConnectionStabilizer(confirmationInterval: 30, requiredAbsenceCount: 2)

        let status = stabilizer.resolve(
            evidence: .online,
            lastSeenAt: nil,
            confirmationStartedAt: nil,
            confirmedAbsenceCount: 4
        )

        #expect(status == .online)
    }
}

private final class ScriptedDeviceCommandRunner: @unchecked Sendable {
    struct Invocation: Sendable {
        let launchPath: String
        let arguments: [String]
        let timeoutSeconds: TimeInterval?
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var invocations: [Invocation] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        let response: Response
        lock.lock()
        invocations.append(Invocation(launchPath: launchPath, arguments: arguments, timeoutSeconds: timeoutSeconds))
        response = responses.isEmpty ? .init(result: .success(stdout: "[]")) : responses.removeFirst()
        lock.unlock()

        if let outputFileContents = response.outputFileContents,
           let outputPath = jsonOutputPath(from: arguments) {
            try outputFileContents.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }

        return response.result
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }
}

private struct Response: Sendable {
    let result: CommandResult
    let outputFileContents: String?

    init(result: CommandResult, outputFileContents: String? = nil) {
        self.result = result
        self.outputFileContents = outputFileContents
    }
}

private extension CommandResult {
    static func success(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 0)
    }

    static func failure(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 1)
    }
}

private func xcdeviceJSON(
    id: String,
    name: String,
    available: Bool = true,
    osVersion: String = "18.4",
    recoverySuggestion: String? = nil
) -> String {
    let errorLine = recoverySuggestion.map {
        #", "error": {"description": "Browsing for device", "recoverySuggestion": "\#($0)"}"#
    } ?? ""
    return """
    [
      {
        "ignored": false,
        "simulator": false,
        "platform": "com.apple.platform.iphoneos",
        "available": \(available),
        "identifier": "\(id)",
        "name": "\(name)",
        "modelCode": "iPhone17,1",
        "modelName": "iPhone",
        "operatingSystemVersion": "\(osVersion)"\(errorLine)
      }
    ]
    """
}

private func partialXCDeviceJSON(
    id: String,
    name: String
) -> String {
    """
    [
      {
        "ignored": false,
        "simulator": false,
        "platform": "com.apple.platform.iphoneos",
        "available": true,
        "identifier": "\(id)",
        "name": "\(name)",
        "modelCode": "iPhone17,1",
        "modelName": "iPhone",
        "operatingSystemVersion": "18.4"
      },
      {
        "ignored": false,
        "simulator": false,
        "platform": "com.apple.platform.iphoneos",
        "available": false,
        "identifier": "unclassified-device",
        "name": "Unclassified Device",
        "modelCode": "Unknown1,1",
        "modelName": "Unknown",
        "operatingSystemVersion": "18.4"
      }
    ]
    """
}

private func devicectlJSON(
    id: String,
    name: String,
    udid: String? = nil,
    osVersion: String = "18.4",
    available: Bool? = nil,
    connectionState: String? = "connected",
    tunnelState: String? = "connected",
    pairingState: String? = "paired"
) -> String {
    let resolvedUDID = udid ?? id
    let udidLine = #""udid": "\#(resolvedUDID)","#
    let availableLine = available.map { #""available": \#($0),"# } ?? ""
    let connectionStateLine = connectionState.map { #""connectionState": "\#($0)","# } ?? ""
    let pairingStateLine = pairingState.map { #""pairingState": "\#($0)","# } ?? ""
    let tunnelStateLine = tunnelState.map { #""tunnelState": "\#($0)","# } ?? ""
    return """
    {
      "result": {
        "devices": [
          {
            "identifier": "\(id)",
            \(availableLine)
            "deviceProperties": {
              "name": "\(name)",
              "osVersionNumber": "\(osVersion)",
              "deviceClass": "iPhone"
            },
            "hardwareProperties": {
              \(udidLine)
              "platform": "iOS",
              "deviceType": "iPhone"
            },
            "connectionProperties": {
              \(connectionStateLine)
              \(pairingStateLine)
              "transportType": "localNetwork",
              \(tunnelStateLine)
              "transportProtocol": "tcp"
            }
          }
        ]
      }
    }
    """
}

private func devicectlJSONWithoutCanonicalID(
    id: String,
    name: String
) -> String {
    """
    {
      "result": {
        "devices": [
          {
            "identifier": "\(id)",
            "deviceProperties": {
              "name": "\(name)",
              "osVersionNumber": "18.4",
              "deviceClass": "iPhone"
            },
            "hardwareProperties": {
              "platform": "iOS",
              "deviceType": "iPhone"
            },
            "connectionProperties": {
              "connectionState": "connected",
              "pairingState": "paired",
              "transportType": "localNetwork",
              "tunnelState": "connected"
            }
          }
        ]
      }
    }
    """
}
