import CoreFoundation
import Foundation

enum DeviceLockState: Equatable, Sendable {
    case locked
    case unlocked
    case unknown
}

enum DeviceLockStateEvidence: Equatable, Sendable {
    case passcodeRequired
    case compatibilityField
}

enum DeviceLockStateInspectionFailure: Error, Equatable, LocalizedError, Sendable {
    case commandTimedOut
    case commandCancelled
    case commandFailed(exitStatus: Int32?)
    case commandReportedFailure
    case processTerminationUnconfirmed
    case outputUnavailable
    case malformedOutput
    case unsupportedSchema(jsonVersion: Int?, toolVersion: String?)
    case conflictingEvidence

    var isTransient: Bool {
        switch self {
        case .commandTimedOut,
             .commandFailed,
             .commandReportedFailure,
             .outputUnavailable:
            return true
        case .commandCancelled,
             .processTerminationUnconfirmed,
             .malformedOutput,
             .unsupportedSchema,
             .conflictingEvidence:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .commandTimedOut:
            return "CoreDevice 锁屏状态查询超时。"
        case .commandCancelled:
            return "CoreDevice 锁屏状态查询已取消。"
        case .commandFailed(let exitStatus):
            if let exitStatus {
                return "CoreDevice 锁屏状态查询失败（退出状态 \(exitStatus)）。"
            }
            return "无法启动 CoreDevice 锁屏状态查询。"
        case .commandReportedFailure:
            return "CoreDevice 未能完成锁屏状态查询。"
        case .processTerminationUnconfirmed:
            return "无法确认锁屏状态查询进程已经完整退出。"
        case .outputUnavailable:
            return "CoreDevice 未返回锁屏状态结果。"
        case .malformedOutput:
            return "CoreDevice 返回的锁屏状态结果格式无效。"
        case .unsupportedSchema(let jsonVersion, let toolVersion):
            let details = [
                jsonVersion.map { "JSON \($0)" },
                toolVersion.map { "工具 \($0)" }
            ].compactMap { $0 }
            guard !details.isEmpty else {
                return "当前 Xcode 的 CoreDevice 锁屏状态格式暂不受支持。"
            }
            return "当前 Xcode 的 CoreDevice 锁屏状态格式暂不受支持（\(details.joined(separator: "，"))）。"
        case .conflictingEvidence:
            return "CoreDevice 返回了互相冲突的锁屏状态。"
        }
    }
}

enum DeviceLockStateObservation: Equatable, Sendable {
    case determined(DeviceLockState, evidence: DeviceLockStateEvidence)
    case indeterminate(DeviceLockStateInspectionFailure)

    var state: DeviceLockState {
        switch self {
        case .determined(let state, _):
            return state
        case .indeterminate:
            return .unknown
        }
    }

    var failure: DeviceLockStateInspectionFailure? {
        guard case .indeterminate(let failure) = self else {
            return nil
        }
        return failure
    }
}

struct DeviceLockStateInspector: Sendable {
    private let runCommand: @Sendable (String, [String], TimeInterval?) async throws -> CommandResult
    private let commandBudget: DeviceCommandBudget

    init(
        commandRunner: CommandRunner = CommandRunner(),
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudget = commandBudgets.budget(
            for: .lockStateInspection
        )
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try await commandRunner.runAsync(launchPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    init(
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult,
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudget = commandBudgets.budget(
            for: .lockStateInspection
        )
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
    }

    func inspect(device: DeviceInfo) async -> DeviceLockState {
        await inspectObservation(device: device).state
    }

    func inspectObservation(
        device: DeviceInfo
    ) async -> DeviceLockStateObservation {
        let attempts = max(commandBudget.attempts, 1)
        for attempt in 0..<attempts {
            let observation = await inspectOnce(device: device)
            guard case .indeterminate(let failure) = observation,
                  failure.isTransient,
                  attempt + 1 < attempts else {
                return observation
            }
            do {
                try await Task.sleep(for: commandBudget.retryDelay)
            } catch {
                return .indeterminate(.commandCancelled)
            }
        }
        return .indeterminate(.commandFailed(exitStatus: nil))
    }

    private func inspectOnce(
        device: DeviceInfo
    ) async -> DeviceLockStateObservation {
        let commandTimeoutSeconds = commandBudget.commandTimeoutSeconds
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ios-sign-kit-lockstate-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let result: CommandResult
        do {
            result = try await runCommand(
                "/usr/bin/xcrun",
                [
                    "devicectl", "device", "info", "lockState",
                    "--device", device.id,
                    "--timeout", "\(Int(ceil(commandTimeoutSeconds)))",
                    "--json-output", outputURL.path,
                    "--quiet"
                ],
                commandBudget.outerTimeoutSeconds
            )
        } catch is CancellationError {
            return .indeterminate(.commandCancelled)
        } catch {
            return .indeterminate(.commandFailed(exitStatus: nil))
        }

        guard result.processGroupTerminationWasConfirmed else {
            return .indeterminate(.processTerminationUnconfirmed)
        }
        if result.terminationStatus == 124 {
            return .indeterminate(.commandTimedOut)
        }
        if result.terminationStatus == 130 {
            return .indeterminate(.commandCancelled)
        }
        guard result.terminationStatus == 0 else {
            return .indeterminate(
                .commandFailed(exitStatus: result.terminationStatus)
            )
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return .indeterminate(.outputUnavailable)
        }

        do {
            let data = try BoundedFileReader().data(
                at: outputURL,
                maximumBytes: BoundedFileReader.structuredOutputMaximumBytes
            )
            guard !data.isEmpty else {
                return .indeterminate(.outputUnavailable)
            }
            let object = try JSONSerialization.jsonObject(with: data)
            return Self.observation(from: object)
        } catch let error as BoundedFileReaderError {
            switch error {
            case .invalidLimit, .exceedsLimit:
                return .indeterminate(.malformedOutput)
            }
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile {
            return .indeterminate(.outputUnavailable)
        } catch {
            return .indeterminate(.malformedOutput)
        }
    }

    static func lockState(from object: Any) -> DeviceLockState? {
        guard case .determined(let state, _) = observation(from: object) else {
            return nil
        }
        return state
    }

    static func observation(from object: Any) -> DeviceLockStateObservation {
        let envelope = object as? [String: Any]
        let info = envelope?["info"] as? [String: Any]
        let jsonVersion = (info?["jsonVersion"] as? NSNumber)?.intValue
        let toolVersion = (info?["version"] as? String).map {
            DiagnosticText.bounded($0, maximumCharacters: 80)
        }

        if let rawOutcome = info?["outcome"] {
            guard let outcome = rawOutcome as? String else {
                return .indeterminate(.malformedOutput)
            }
            guard outcome
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "success" else {
                return .indeterminate(.commandReportedFailure)
            }
        }

        let root: Any
        if let envelope,
           let result = envelope["result"] {
            guard result is [String: Any] || result is [Any] else {
                return .indeterminate(.malformedOutput)
            }
            root = result
        } else {
            root = object
        }

        var candidates = Set<DeviceLockState>()
        collectLockStates(from: root, depth: 0, into: &candidates)

        // `unlockedSinceBoot` is historical boot evidence and is deliberately
        // ignored. In this schema, `passcodeRequired` is the current signal.
        if let result = root as? [String: Any],
           let rawPasscodeRequired = result["passcodeRequired"] {
            guard let passcodeRequired = strictBoolean(
                from: rawPasscodeRequired
            ) else {
                return .indeterminate(.malformedOutput)
            }
            let state: DeviceLockState = passcodeRequired
                ? .locked
                : .unlocked
            guard candidates.isEmpty || candidates == [state] else {
                return .indeterminate(.conflictingEvidence)
            }
            return .determined(state, evidence: .passcodeRequired)
        }

        if candidates.count > 1 {
            return .indeterminate(.conflictingEvidence)
        }
        if let state = candidates.first {
            return .determined(state, evidence: .compatibilityField)
        }
        return .indeterminate(
            .unsupportedSchema(
                jsonVersion: jsonVersion,
                toolVersion: toolVersion
            )
        )
    }

    private static func strictBoolean(from value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func collectLockStates(
        from object: Any,
        depth: Int,
        into candidates: inout Set<DeviceLockState>
    ) {
        guard depth <= 4, candidates.count <= 1 else {
            return
        }
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if let state = lockState(fromValue: value, key: key) {
                    candidates.insert(state)
                }
            }
            for value in dictionary.values {
                collectLockStates(
                    from: value,
                    depth: depth + 1,
                    into: &candidates
                )
            }
        } else if let array = object as? [Any], array.count <= 32 {
            for value in array {
                collectLockStates(
                    from: value,
                    depth: depth + 1,
                    into: &candidates
                )
            }
        }
    }

    private static func lockState(fromValue value: Any, key: String) -> DeviceLockState? {
        let normalizedKey = key
            .lowercased()
            .filter(\.isLetter)
        let lockedBooleanKeys = Set(["locked", "islocked"])
        let unlockedBooleanKeys = Set(["unlocked", "isunlocked"])
        let stringKeys = Set(["lockstate", "devicelockstate"])

        if let isUnlocked = value as? Bool,
           unlockedBooleanKeys.contains(normalizedKey) {
            return isUnlocked ? .unlocked : .locked
        }

        if let isLocked = value as? Bool,
           lockedBooleanKeys.contains(normalizedKey) {
            return isLocked ? .locked : .unlocked
        }

        guard stringKeys.contains(normalizedKey),
              let stringValue = value as? String else {
            return nil
        }

        let normalizedValue = stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedValue {
        case "locked", "lockstate.locked", "device_locked", "islocked":
            return .locked
        case "unlocked", "lockstate.unlocked", "device_unlocked", "notlocked", "not_locked":
            return .unlocked
        default:
            return nil
        }
    }
}
