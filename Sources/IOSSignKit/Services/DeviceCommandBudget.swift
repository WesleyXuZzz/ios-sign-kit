import Foundation

enum DeviceCommandPurpose: CaseIterable, Hashable, Sendable {
    case backgroundObservation
    case interactiveObservation
    case recoveryObservation
    case deploymentVerification
    case installedAppInspection
    case lockStateInspection
    case wirelessPairing
}

struct DeviceCommandBudget: Equatable, Sendable {
    let commandTimeout: Duration
    let outerTimeout: Duration
    let attempts: Int
    let retryDelay: Duration

    var commandTimeoutSeconds: TimeInterval {
        commandTimeout.timeInterval
    }

    var outerTimeoutSeconds: TimeInterval {
        outerTimeout.timeInterval
    }
}

struct DeviceCommandBudgetCatalog: Sendable {
    static let production = DeviceCommandBudgetCatalog(
        budgets: [
            .backgroundObservation: DeviceCommandBudget(
                commandTimeout: .seconds(6),
                outerTimeout: .seconds(6),
                attempts: 1,
                retryDelay: .zero
            ),
            .interactiveObservation: DeviceCommandBudget(
                commandTimeout: .seconds(8),
                outerTimeout: .seconds(8),
                attempts: 3,
                retryDelay: .seconds(1)
            ),
            .recoveryObservation: DeviceCommandBudget(
                commandTimeout: .seconds(12),
                outerTimeout: .seconds(12),
                attempts: 1,
                retryDelay: .zero
            ),
            .deploymentVerification: DeviceCommandBudget(
                commandTimeout: .seconds(18),
                outerTimeout: .seconds(18),
                attempts: 1,
                retryDelay: .zero
            ),
            .installedAppInspection: DeviceCommandBudget(
                commandTimeout: .seconds(8),
                outerTimeout: .seconds(9),
                attempts: 4,
                retryDelay: .seconds(1)
            ),
            .lockStateInspection: DeviceCommandBudget(
                commandTimeout: .seconds(5),
                outerTimeout: .seconds(6),
                attempts: 2,
                retryDelay: .milliseconds(200)
            ),
            .wirelessPairing: DeviceCommandBudget(
                commandTimeout: .seconds(60),
                outerTimeout: .seconds(61),
                attempts: 1,
                retryDelay: .zero
            ),
        ]
    )

    private let budgets: [DeviceCommandPurpose: DeviceCommandBudget]

    init(budgets: [DeviceCommandPurpose: DeviceCommandBudget]) {
        precondition(
            Set(budgets.keys) == Set(DeviceCommandPurpose.allCases),
            "Every device command purpose must have a budget."
        )
        self.budgets = budgets
    }

    func budget(for purpose: DeviceCommandPurpose) -> DeviceCommandBudget {
        guard let budget = budgets[purpose] else {
            preconditionFailure("Missing device command budget for \(purpose).")
        }
        return budget
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
