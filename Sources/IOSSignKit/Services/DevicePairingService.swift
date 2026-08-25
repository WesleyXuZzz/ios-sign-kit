import Foundation

enum DevicePairingResult: Equatable, Sendable {
    case success
    case confirmationRequired(String)
    case networkUnavailable(String)
    case toolchainUnsupported(String)
    case failed(String)
}

struct DevicePairingService: Sendable {
    private let runCommand: @Sendable (String, [String], TimeInterval?) async throws -> CommandResult
    private let commandBudget: DeviceCommandBudget

    init(
        commandRunner: CommandRunner = CommandRunner(),
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudget = commandBudgets.budget(for: .wirelessPairing)
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try await commandRunner.runAsync(launchPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    init(
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult,
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudget = commandBudgets.budget(for: .wirelessPairing)
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
    }

    func pairWirelessly(device: UnavailableDeviceInfo) async -> DevicePairingResult {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ios-sign-kit-pair-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            let result = try await runCommand(
                "/usr/bin/xcrun",
                [
                    "devicectl", "manage", "pair",
                    "--device", device.id,
                    "--timeout",
                    "\(Int(ceil(commandBudget.commandTimeoutSeconds)))",
                    "--json-output", outputURL.path,
                    "--quiet"
                ],
                commandBudget.outerTimeoutSeconds
            )

            if result.completedSuccessfullyAndFullyTerminated {
                return .success
            }

            let jsonOutput: String
            do {
                jsonOutput = try BoundedFileReader().utf8String(
                    at: outputURL,
                    maximumBytes: BoundedFileReader.structuredOutputMaximumBytes
                )
            } catch {
                jsonOutput = "无法读取配对工具 JSON：\(error.localizedDescription)"
            }
            return classifyFailure(
                combinedOutput: [result.standardError, result.standardOutput, jsonOutput]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
            )
        } catch {
            return .failed(compactMessage(error.localizedDescription, fallback: "无法启动无线配对命令。"))
        }
    }

    private func classifyFailure(combinedOutput: String) -> DevicePairingResult {
        let message = compactMessage(combinedOutput, fallback: "无线配对失败。")
        let normalized = combinedOutput.lowercased()

        if containsAny(
            normalized,
            terms: [
                "trust this computer", "trust", "confirmation", "confirm", "passcode",
                "developer mode", "unlock", "locked", "authentication"
            ]
        ) {
            return .confirmationRequired(message)
        }

        if containsAny(
            normalized,
            terms: [
                "unsupported", "not supported", "incompatible", "device support",
                "newer version of xcode", "upgrade xcode", "requires xcode"
            ]
        ) {
            return .toolchainUnsupported(message)
        }

        if containsAny(
            normalized,
            terms: [
                "local network", "same network", "wi-fi", "wifi", "discover", "nearby",
                "not found", "unavailable", "hostname", "timed out", "timeout"
            ]
        ) {
            return .networkUnavailable(message)
        }

        return .failed(message)
    }

    private func containsAny(_ value: String, terms: [String]) -> Bool {
        terms.contains { value.contains($0) }
    }

    private func compactMessage(_ value: String, fallback: String) -> String {
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let message = lines.prefix(3).joined(separator: " ")
        guard !message.isEmpty else {
            return fallback
        }

        return String(message.prefix(600))
    }
}
