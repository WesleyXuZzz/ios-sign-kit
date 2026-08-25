import Foundation

struct DeviceSourceScanner: Sendable {
    typealias RunCommand = @Sendable (
        String,
        [String],
        TimeInterval?
    ) async throws -> CommandResult

    private let runCommand: RunCommand

    init(runCommand: @escaping RunCommand) {
        self.runCommand = runCommand
    }

    func scanXCDevice(
        timeoutSeconds: TimeInterval
    ) async throws -> SourceScanOutcome {
        let result: CommandResult
        do {
            result = try await runCommand(
                "/usr/bin/xcrun",
                ["xcdevice", "list"],
                timeoutSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(diagnosticDescription(for: error))
        }
        guard result.completedSuccessfullyAndFullyTerminated else {
            return .failed(commandFailureMessage(result))
        }
        guard !result.standardOutputWasTruncated else {
            return .failed(
                "xcdevice 返回的设备 JSON 过大，已停止解析不完整结果。"
            )
        }
        do {
            return try DeviceSourceParser.parseXCDevice(
                result.standardOutput
            )
        } catch {
            return .failed(diagnosticDescription(for: error))
        }
    }

    func scanDeviceCtl(
        timeoutSeconds: TimeInterval
    ) async throws -> SourceScanOutcome {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "ios-sign-kit-devicectl-\(UUID().uuidString).json"
            )
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let result: CommandResult
        do {
            result = try await runCommand(
                "/usr/bin/xcrun",
                [
                    "devicectl", "list", "devices",
                    "--timeout", "\(Int(ceil(timeoutSeconds)))",
                    "--json-output", outputURL.path,
                    "--quiet"
                ],
                timeoutSeconds + 1
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(diagnosticDescription(for: error))
        }

        guard result.completedSuccessfullyAndFullyTerminated else {
            let outputMessage = (
                try? BoundedFileReader().utf8String(
                    at: outputURL,
                    maximumBytes:
                        BoundedFileReader.structuredOutputMaximumBytes
                )
            ) ?? ""
            return .failed(
                commandFailureMessage(
                    result,
                    fallbackOutput: outputMessage
                )
            )
        }
        do {
            let data = try BoundedFileReader().data(
                at: outputURL,
                maximumBytes: BoundedFileReader.structuredOutputMaximumBytes
            )
            return try DeviceSourceParser.parseDeviceCtl(data)
        } catch {
            return .failed(diagnosticDescription(for: error))
        }
    }

    private func commandFailureMessage(
        _ result: CommandResult,
        fallbackOutput: String = ""
    ) -> String {
        let candidates = [
            result.standardError,
            result.standardOutput,
            fallbackOutput
        ]
        let message = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "命令退出码 \(result.terminationStatus)。"
        return compactDiagnostic(message)
    }

    private func diagnosticDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return compactDiagnostic(description)
        }
        return compactDiagnostic(error.localizedDescription)
    }

    private func compactDiagnostic(_ value: String) -> String {
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map {
                String($0).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
        return DiagnosticText.bounded(
            lines.prefix(3).joined(separator: " ")
        )
    }
}
