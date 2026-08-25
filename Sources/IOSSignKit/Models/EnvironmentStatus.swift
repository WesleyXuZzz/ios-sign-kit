import Foundation

enum EnvironmentCheckResult: Equatable, Sendable {
    case passed
    case failed
    case uncertain
}

struct EnvironmentCheckItem: Equatable, Sendable {
    var title: String
    var result: EnvironmentCheckResult
}

struct EnvironmentStatus: Equatable, Sendable {
    var isXcodebuildAvailable: Bool
    var isXcrunAvailable: Bool
    var isProjectPathValid: Bool
    var isApplicationTargetResolved: Bool
    var summary: String
    var isValidationComplete: Bool = true

    var areAllChecksPassing: Bool {
        isValidationComplete
            && isXcodebuildAvailable
            && isXcrunAvailable
            && isProjectPathValid
            && isApplicationTargetResolved
    }

    var checkItems: [EnvironmentCheckItem] {
        [
            EnvironmentCheckItem(
                title: "Xcode 命令行工具",
                result: checkResult(isPassing: isXcodebuildAvailable)
            ),
            EnvironmentCheckItem(
                title: "xcrun",
                result: checkResult(isPassing: isXcrunAvailable)
            ),
            EnvironmentCheckItem(
                title: "项目目录",
                result: checkResult(isPassing: isProjectPathValid)
            ),
            EnvironmentCheckItem(
                title: "App 目标",
                result: checkResult(isPassing: isApplicationTargetResolved)
            )
        ]
    }

    static let unknown = EnvironmentStatus(
        isXcodebuildAvailable: false,
        isXcrunAvailable: false,
        isProjectPathValid: false,
        isApplicationTargetResolved: false,
        summary: "尚未检查",
        isValidationComplete: false
    )

    private func checkResult(isPassing: Bool) -> EnvironmentCheckResult {
        guard isValidationComplete else {
            return .uncertain
        }

        return isPassing ? .passed : .failed
    }
}
