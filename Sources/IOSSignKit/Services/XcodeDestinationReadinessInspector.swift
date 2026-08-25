import Foundation

enum XcodeDestinationReadiness: Equatable, Sendable {
    case ready
    case requiresUnlock(String)
    case unavailable(String)
    case unknown(String)
}

struct XcodeDestinationReadinessInspector: Sendable {
    private enum DestinationErrorField {
        case absent
        case value(String)
        case malformed
    }

    private static let commandTimeoutSeconds: TimeInterval = 8
    private static let maximumOutputBytesPerStream = 1_048_576
    private static let maximumDestinationLineBytes = 32_768
    private static let maximumDestinationLineCount = 4_096

    private let runCommand: @Sendable (
        String,
        [String],
        TimeInterval?
    ) async throws -> CommandResult

    init(commandExecutor: any CommandExecuting = CommandRunner()) {
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try await commandExecutor.runAsync(
                launchPath,
                arguments: arguments,
                currentDirectoryPath: nil,
                environmentOverrides: [:],
                onOutput: nil,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    init(
        runCommand: @escaping @Sendable (
            String,
            [String],
            TimeInterval?
        ) async throws -> CommandResult
    ) {
        self.runCommand = runCommand
    }

    func inspect(
        config: AppConfig,
        deviceID: String
    ) async -> XcodeDestinationReadiness {
        guard let projectPath = Self.normalized(config.xcodeprojPath),
              let container = XcodeContainer(path: projectPath),
              let scheme = Self.normalized(config.scheme) else {
            return .unknown("App 目标配置不完整，无法检查 destination。")
        }
        guard let deviceID = Self.normalized(deviceID) else {
            return .unknown("目标设备 ID 为空，无法检查 destination。")
        }

        do {
            try Task.checkCancellation()
            let result = try await runCommand(
                "/usr/bin/xcodebuild",
                container.xcodebuildArguments + [
                    "-scheme", scheme,
                    "-destination", "id=\(deviceID)",
                    "-destination-timeout", "5",
                    "-showdestinations"
                ],
                Self.commandTimeoutSeconds
            )
            try Task.checkCancellation()
            return Self.readiness(
                from: result,
                deviceID: deviceID
            )
        } catch is CancellationError {
            return .unknown("目标设备准备检查已取消。")
        } catch {
            return .unknown(
                "无法检查 Xcode destination：\(DiagnosticText.bounded(error.localizedDescription))"
            )
        }
    }

    static func readiness(
        from result: CommandResult,
        deviceID: String
    ) -> XcodeDestinationReadiness {
        guard result.completedSuccessfullyAndFullyTerminated else {
            if result.terminationStatus == 124 {
                return .unknown("Xcode destination 检查超时。")
            }
            if result.terminationStatus == 130 {
                return .unknown("Xcode destination 检查已取消。")
            }
            let diagnostic = normalized(result.standardError)
                ?? normalized(result.standardOutput)
                ?? "退出状态 \(result.terminationStatus)"
            return .unknown(
                "Xcode destination 检查失败：\(DiagnosticText.bounded(diagnostic))"
            )
        }

        guard !result.standardOutputWasTruncated,
              !result.standardErrorWasTruncated else {
            return .unknown("Xcode destination 输出不完整，无法安全判断设备状态。")
        }
        guard result.standardOutput.lengthOfBytes(using: .utf8)
                <= maximumOutputBytesPerStream,
              result.standardError.lengthOfBytes(using: .utf8)
                <= maximumOutputBytesPerStream else {
            return .unknown("Xcode destination 输出过大，无法安全判断设备状态。")
        }

        let lines = (result.standardOutput + "\n" + result.standardError)
            .components(separatedBy: .newlines)
        guard lines.count <= maximumDestinationLineCount,
              !lines.contains(where: {
                  $0.lengthOfBytes(using: .utf8) > maximumDestinationLineBytes
              }) else {
            return .unknown("Xcode destination 输出过大，无法安全判断设备状态。")
        }

        var recognizedRecordCount = 0
        var matchingRecordCount = 0
        var matchingErrors: [String] = []
        var hasMalformedMatchingError = false
        var hasMalformedIdentifier = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDestinationRecord(line) else {
                continue
            }
            recognizedRecordCount += 1
            switch XcodeDestinationRecordParser.identifier(in: line) {
            case .absent:
                continue
            case .malformed:
                hasMalformedIdentifier = true
                continue
            case .value(let identifier):
                guard identifier == deviceID else {
                    continue
                }
            }
            matchingRecordCount += 1
            switch destinationErrorField(in: line) {
            case .absent:
                break
            case .value(let error):
                matchingErrors.append(error)
            case .malformed:
                hasMalformedMatchingError = true
            }
        }

        guard recognizedRecordCount > 0 else {
            return .unknown("Xcode 未返回可识别的 destination 列表。")
        }
        guard !hasMalformedIdentifier else {
            return .unknown("Xcode destination 的设备 ID 字段格式无效，无法安全判断设备状态。")
        }
        guard matchingRecordCount > 0 else {
            return .unavailable("Xcode 的可用目标中没有找到该 iPhone。")
        }
        guard !hasMalformedMatchingError else {
            return .unknown("Xcode destination 的错误字段格式无效，无法安全判断设备状态。")
        }
        if let unlockError = matchingErrors.first(where: requiresUnlock) {
            return .requiresUnlock(DiagnosticText.bounded(unlockError))
        }
        if let error = matchingErrors.first {
            return .unavailable(DiagnosticText.bounded(error))
        }
        return .ready
    }

    private static func isDestinationRecord(_ line: String) -> Bool {
        line.lengthOfBytes(using: .utf8) <= maximumDestinationLineBytes
            && XcodeDestinationRecordParser.isRecord(
                line,
                requiresPlatform: true
            )
    }

    private static func destinationErrorField(
        in line: String
    ) -> DestinationErrorField {
        let pattern = #"(?:^|[,{])\s*error\s*:\s*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return .malformed
        }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = expression.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return .absent
        }
        guard matches.count == 1,
              let prefixRange = Range(matches[0].range, in: line) else {
            return .malformed
        }
        let suffix = line[prefixRange.upperBound...]
        let nextField = suffix.range(
            of: #",\s*(?:platform|arch|id|name|variant|OS|error)\s*:"#,
            options: .regularExpression
        )
        let rawValue: Substring
        if let nextField {
            rawValue = suffix[..<nextField.lowerBound]
        } else if let closingBrace = suffix.lastIndex(of: "}") {
            rawValue = suffix[..<closingBrace]
        } else {
            return .malformed
        }
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .malformed : .value(value)
    }

    private static func requiresUnlock(_ error: String) -> Bool {
        let normalized = error.lowercased()
        return normalized.contains("device is locked")
            || normalized.contains(
                "may need to be unlocked to recover from previously reported preparation errors"
            )
            || (
                normalized.contains("unlock")
                    && (
                        normalized.contains("preparation")
                            || normalized.contains("recover")
                    )
            )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
