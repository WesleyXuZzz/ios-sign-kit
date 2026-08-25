import Foundation

struct ParsedDeployLog: Equatable, Sendable {
    let exitStatus: Int?
    let trigger: RefreshHistoryTrigger?
    let failureReason: DeployFailureReason?
    let processGroupTerminationWasConfirmed: Bool?
    let standardOutputLines: [String]
    let standardErrorLines: [String]

    var meaningfulLines: [String] {
        standardOutputLines + standardErrorLines
    }

    var isCancelled: Bool {
        exitStatus == 130 || exitStatus == 143
    }
}

struct DeployLogParser: Sendable {
    func parse(_ content: String) -> ParsedDeployLog {
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            == DeployLogFormat.currentVersionHeader {
            return parseEscapedSections(lines.dropFirst())
        }
        return parseLegacySections(lines)
    }

    private func parseEscapedSections(_ lines: ArraySlice<String>) -> ParsedDeployLog {
        enum Section {
            case header
            case standardOutput
            case standardError
        }

        var section = Section.header
        var exitStatus: Int?
        var trigger: RefreshHistoryTrigger?
        var failureReason: DeployFailureReason?
        var processGroupTerminationWasConfirmed: Bool?
        var standardOutputLines: [String] = []
        var standardErrorLines: [String] = []

        for rawLine in lines {
            let marker = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (section, marker) {
            case (.header, let value) where value.hasPrefix("exit_status=") && exitStatus == nil:
                exitStatus = value.split(separator: "=", maxSplits: 1).last.flatMap { Int($0) }
            case (.header, let value)
                where value.hasPrefix("trigger=") && trigger == nil:
                trigger = value
                    .split(separator: "=", maxSplits: 1)
                    .last
                    .flatMap { RefreshHistoryTrigger(rawValue: String($0)) }
            case (.header, let value)
                where value.hasPrefix("failure_reason=")
                    && failureReason == nil:
                let rawValue = value
                    .dropFirst("failure_reason=".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawValue.isEmpty {
                    failureReason = DeployFailureReason(rawValue: rawValue)
                }
            case (.header, let value)
                where value.hasPrefix("process_group_termination_confirmed="):
                processGroupTerminationWasConfirmed = value
                    .split(separator: "=", maxSplits: 1)
                    .last
                    .flatMap { Bool(String($0)) }
            case (.header, let value)
                where value.hasPrefix("stdout_truncated=")
                    || value.hasPrefix("stderr_truncated="):
                continue
            case (.header, "[stdout]"):
                section = .standardOutput
            case (.standardOutput, "[stderr]"):
                section = .standardError
            default:
                guard rawLine.hasPrefix("| ") else {
                    if !marker.isEmpty {
                        standardErrorLines.append("日志格式损坏：\(marker)")
                    }
                    continue
                }
                let decodedLine = String(rawLine.dropFirst(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !decodedLine.isEmpty else {
                    continue
                }
                switch section {
                case .standardOutput:
                    standardOutputLines.append(decodedLine)
                case .standardError, .header:
                    standardErrorLines.append(decodedLine)
                }
            }
        }

        return ParsedDeployLog(
            exitStatus: exitStatus,
            trigger: trigger,
            failureReason: failureReason,
            processGroupTerminationWasConfirmed:
                processGroupTerminationWasConfirmed,
            standardOutputLines: standardOutputLines,
            standardErrorLines: standardErrorLines
        )
    }

    private func parseLegacySections(_ lines: [String]) -> ParsedDeployLog {
        enum Section {
            case none
            case standardOutput
            case standardError
        }

        var section = Section.none
        var exitStatus: Int?
        var standardOutputLines: [String] = []
        var standardErrorLines: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if section == .none, exitStatus == nil, line.hasPrefix("exit_status=") {
                exitStatus = line.split(separator: "=", maxSplits: 1).last.flatMap { Int($0) }
                continue
            }
            switch (section, line) {
            case (.none, "[stdout]"):
                section = .standardOutput
                continue
            case (.standardOutput, "[stderr]"):
                section = .standardError
                continue
            default:
                break
            }
            guard !line.isEmpty else {
                continue
            }
            switch section {
            case .standardOutput:
                standardOutputLines.append(line)
            case .standardError:
                standardErrorLines.append(line)
            case .none:
                standardErrorLines.append(line)
            }
        }

        return ParsedDeployLog(
            exitStatus: exitStatus,
            trigger: nil,
            failureReason: nil,
            processGroupTerminationWasConfirmed: nil,
            standardOutputLines: standardOutputLines,
            standardErrorLines: standardErrorLines
        )
    }
}
