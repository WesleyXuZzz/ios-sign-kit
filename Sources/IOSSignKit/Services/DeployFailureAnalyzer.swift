import Foundation

struct DeployFailureAnalysis: Equatable, Sendable {
    let reason: DeployFailureReason
    let summary: String
}

struct DeployFailureAnalyzer: Sendable {
    static let devicePreparationMarker =
        "IOS_SIGN_KIT_FAILURE_REASON=device_preparation_required"

    func analyze(
        exitStatus: Int,
        standardOutput: String,
        standardError: String,
        targetDeviceID: String? = nil
    ) -> DeployFailureAnalysis {
        analyze(
            exitStatus: exitStatus,
            standardOutputLines: Self.lines(from: standardOutput),
            standardErrorLines: Self.lines(from: standardError),
            targetDeviceID: targetDeviceID
        )
    }

    func analyze(_ log: ParsedDeployLog) -> DeployFailureAnalysis {
        if let persistedReason = log.failureReason {
            switch persistedReason {
            case .devicePreparationRequired where log.exitStatus == 70:
                return DeployFailureAnalysis(
                    reason: persistedReason,
                    summary: Self.devicePreparationSummary
                )
            case .devicePreparationRequired:
                return DeployFailureAnalysis(
                    reason: .generic,
                    summary: Self.bestFailureLine(
                        standardOutputLines: log.standardOutputLines,
                        standardErrorLines: log.standardErrorLines
                    )
                )
            case .generic, .unknown(_):
                return DeployFailureAnalysis(
                    reason: persistedReason,
                    summary: Self.bestFailureLine(
                        standardOutputLines: log.standardOutputLines,
                        standardErrorLines: log.standardErrorLines
                    )
                )
            }
        }
        let allLines = log.standardOutputLines + log.standardErrorLines
        return analyze(
            exitStatus: log.exitStatus,
            standardOutputLines: log.standardOutputLines,
            standardErrorLines: log.standardErrorLines,
            targetDeviceID: Self.inferredTargetDeviceID(from: allLines)
        )
    }

    func analyze(
        exitStatus: Int?,
        standardOutputLines: [String],
        standardErrorLines: [String],
        targetDeviceID: String? = nil
    ) -> DeployFailureAnalysis {
        let allLines = standardOutputLines + standardErrorLines
        if isDevicePreparationFailure(
            exitStatus: exitStatus,
            lines: allLines,
            targetDeviceID: targetDeviceID
        ) {
            return DeployFailureAnalysis(
                reason: .devicePreparationRequired,
                summary: Self.devicePreparationSummary
            )
        }

        return DeployFailureAnalysis(
            reason: .generic,
            summary: Self.bestFailureLine(
                standardOutputLines: standardOutputLines,
                standardErrorLines: standardErrorLines
            )
        )
    }

    private func isDevicePreparationFailure(
        exitStatus: Int?,
        lines: [String],
        targetDeviceID: String?
    ) -> Bool {
        guard exitStatus == 70 else {
            return false
        }
        if lines.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                == Self.devicePreparationMarker
        }) {
            return true
        }

        let normalized = lines.joined(separator: "\n").lowercased()
        guard normalized.contains("timed out waiting for all destinations") else {
            return false
        }

        let destinationRecords = lines.filter(Self.isDestinationRecord)
        let preparationRecords = destinationRecords.filter {
            $0.lowercased().contains(
                "may need to be unlocked to recover from previously reported preparation errors"
            )
        }
        guard !preparationRecords.isEmpty else {
            return false
        }

        if let targetDeviceID = Self.normalized(targetDeviceID) {
            return preparationRecords.contains {
                XcodeDestinationRecordParser.identifier(in: $0)
                    == .value(targetDeviceID)
            }
        }

        return destinationRecords.count == 1
            && preparationRecords.count == 1
            && {
                if case .value =
                    XcodeDestinationRecordParser.identifier(
                        in: preparationRecords[0]
                    ) {
                    return true
                }
                return false
            }()
    }

    private static func lines(from value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let devicePreparationSummary =
        "Xcode 无法准备目标 iPhone；请解锁设备，等待 Xcode 完成设备准备后重试。"

    private static func inferredTargetDeviceID(from lines: [String]) -> String? {
        let patterns = [
            #"^\s*设备 ID\s*:\s*(\S+)\s*$"#,
            #"^\s*IOS_SIGN_KIT_DEVICE_ID\s*=\s*(\S+)\s*$"#
        ]
        for line in lines {
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(
                    pattern: pattern
                ) else {
                    continue
                }
                let range = NSRange(line.startIndex..., in: line)
                guard let match = expression.firstMatch(
                    in: line,
                    range: range
                ),
                match.numberOfRanges > 1,
                let valueRange = Range(match.range(at: 1), in: line) else {
                    continue
                }
                return String(line[valueRange])
            }
        }
        return nil
    }

    private static func isDestinationRecord(_ line: String) -> Bool {
        XcodeDestinationRecordParser.isRecord(
            line,
            requiresPlatform: false
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func bestFailureLine(
        standardOutputLines: [String],
        standardErrorLines: [String]
    ) -> String {
        let standardErrorDiagnostic = bestDiagnostic(in: standardErrorLines)
        let standardOutputDiagnostic = bestDiagnostic(in: standardOutputLines)

        if let standardErrorDiagnostic {
            if standardErrorDiagnostic.isGenericXcodebuildExitWrapper,
               let standardOutputDiagnostic,
               standardOutputDiagnostic.isXcodebuildError {
                return DiagnosticText.bounded(standardOutputDiagnostic.line)
            }
            return DiagnosticText.bounded(standardErrorDiagnostic.line)
        }
        if let standardOutputDiagnostic {
            return DiagnosticText.bounded(standardOutputDiagnostic.line)
        }

        let fallback = standardErrorLines.first
            ?? standardOutputLines.first
            ?? "续签流程执行失败。"
        return DiagnosticText.bounded(fallback)
    }

    private static func bestDiagnostic(
        in lines: [String]
    ) -> FailureLineCandidate? {
        var best: FailureLineCandidate?
        for (index, line) in lines.enumerated()
            where line != devicePreparationMarker {
            let candidate = FailureLineCandidate(line: line, index: index)
            guard candidate.score > 0 else {
                continue
            }
            if let currentBest = best,
               currentBest.score >= candidate.score {
                continue
            }
            best = candidate
        }
        return best
    }
}

private struct FailureLineCandidate {
    let line: String
    let index: Int

    var isXcodebuildError: Bool {
        line.lowercased().contains("xcodebuild: error:")
    }

    var isGenericXcodebuildExitWrapper: Bool {
        let normalized = line.lowercased()
        guard normalized.contains("xcodebuild"),
              normalized.range(
                of: #"(?:退出码|exit (?:code|status)|termination status)\s*[:：]?\s*-?\d+"#,
                options: .regularExpression
              ) != nil,
              [
                "无法校验", "无法验证", "校验失败", "验证失败",
                "failed to validate", "unable to validate",
                "could not validate", "validation failed"
              ].contains(where: { normalized.contains($0) }) else {
            return false
        }

        let actionableTargetTerms = [
            "scheme", "target", "bundle id", "bundle identifier",
            "方案", "构建目标", "包标识符"
        ]
        return !actionableTargetTerms.contains {
            normalized.contains($0)
        }
    }

    var score: Int {
        let normalized = line.lowercased()
        var value = 0
        if normalized.contains("xcodebuild: error:") {
            value += 100
        } else if normalized.hasPrefix("error:")
                    || normalized.contains(" error:") {
            value += 90
        } else if normalized.hasPrefix("错误")
                    || normalized.contains("失败") {
            value += 80
        } else if normalized.contains("failed")
                    || normalized.contains("failure")
                    || normalized.contains("timed out")
                    || normalized.contains("timeout") {
            value += 70
        }
        return value
    }
}
