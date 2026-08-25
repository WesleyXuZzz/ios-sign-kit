import Foundation

enum RemainingExpiryUrgency: Equatable {
    case unknown
    case healthy
    case warning
    case critical
}

struct RemainingExpiryMetricComponent: Equatable, Identifiable {
    let value: String
    let unit: String?

    var id: String {
        "\(value)-\(unit ?? "value")"
    }

    var text: String {
        [value, unit]
            .compactMap { $0 }
            .joined()
    }
}

struct RemainingExpiryPresentation: Equatable {
    var panelText: String
    var metricComponents: [RemainingExpiryMetricComponent]
    var menuBarText: String?
    var isExpired: Bool
    var remainingSeconds: Int?
    var expiredDurationText: String?

    init(
        panelText: String,
        metricComponents: [RemainingExpiryMetricComponent],
        menuBarText: String?,
        isExpired: Bool,
        remainingSeconds: Int?,
        expiredDurationText: String? = nil
    ) {
        self.panelText = panelText
        self.metricComponents = metricComponents
        self.menuBarText = menuBarText
        self.isExpired = isExpired
        self.remainingSeconds = remainingSeconds
        self.expiredDurationText = expiredDurationText
    }

    static let unknown = RemainingExpiryPresentation(
        panelText: "--",
        metricComponents: [],
        menuBarText: nil,
        isExpired: false,
        remainingSeconds: nil
    )

    static func make(expiryDate: Date?, now: Date = Date()) -> RemainingExpiryPresentation {
        guard let expiryDate else {
            return .unknown
        }

        let remaining = expiryDate.timeIntervalSince(now)
        guard remaining > 0 else {
            let elapsedSeconds = max(Int((-remaining).rounded(.down)), 0)
            return RemainingExpiryPresentation(
                panelText: "到期",
                metricComponents: [
                    RemainingExpiryMetricComponent(
                        value: "到期",
                        unit: nil
                    )
                ],
                menuBarText: "到期",
                isExpired: true,
                remainingSeconds: 0,
                expiredDurationText: expiredDurationText(
                    for: elapsedSeconds
                )
            )
        }

        let totalSeconds = max(Int(remaining.rounded(.down)), 1)
        let metricComponents = metricComponents(for: totalSeconds)
        return RemainingExpiryPresentation(
            panelText: metricComponents.map(\.text).joined(separator: " "),
            metricComponents: metricComponents,
            menuBarText: menuBarText(for: totalSeconds),
            isExpired: false,
            remainingSeconds: totalSeconds
        )
    }

    var nextUpdateInterval: TimeInterval? {
        guard let remainingSeconds, remainingSeconds > 0 else {
            return nil
        }

        if remainingSeconds < Self.minute {
            return 1
        }

        if remainingSeconds < Self.day {
            return TimeInterval((remainingSeconds % Self.minute) + 1)
        }

        return TimeInterval((remainingSeconds % Self.hour) + 1)
    }

    var progressFraction: Double? {
        guard let remainingSeconds else {
            return nil
        }

        return min(
            max(Double(remainingSeconds) / Double(Self.maximumValiditySeconds), 0),
            1
        )
    }

    /// 续期环展示七天签名周期中已经消耗的比例；越接近到期，弧越接近满圈。
    var consumedFraction: Double? {
        progressFraction.map { 1 - $0 }
    }

    var urgency: RemainingExpiryUrgency {
        guard let remainingSeconds else {
            return .unknown
        }

        if remainingSeconds < Self.day {
            return .critical
        }

        if remainingSeconds <= 3 * Self.day {
            return .warning
        }

        return .healthy
    }

    private static let minute = 60
    private static let hour = minute * 60
    private static let day = hour * 24
    private static let maximumValiditySeconds = 7 * day

    private static func expiredDurationText(
        for elapsedSeconds: Int
    ) -> String {
        if elapsedSeconds >= day {
            return "\(elapsedSeconds / day) 天前"
        }
        if elapsedSeconds >= hour {
            return "\(elapsedSeconds / hour) 小时前"
        }
        if elapsedSeconds >= minute {
            return "\(elapsedSeconds / minute) 分钟前"
        }
        return "刚刚到期"
    }

    private static func metricComponents(
        for totalSeconds: Int
    ) -> [RemainingExpiryMetricComponent] {
        if totalSeconds >= day {
            let days = totalSeconds / day
            let hours = (totalSeconds % day) / hour
            var components = [
                RemainingExpiryMetricComponent(
                    value: "\(days)",
                    unit: "天"
                )
            ]
            if hours > 0 {
                components.append(
                    RemainingExpiryMetricComponent(
                        value: "\(hours)",
                        unit: "小时"
                    )
                )
            }
            return components
        }

        if totalSeconds >= hour {
            let hours = totalSeconds / hour
            let minutes = (totalSeconds % hour) / minute
            var components = [
                RemainingExpiryMetricComponent(
                    value: "\(hours)",
                    unit: "小时"
                )
            ]
            if minutes > 0 {
                components.append(
                    RemainingExpiryMetricComponent(
                        value: "\(minutes)",
                        unit: "分钟"
                    )
                )
            }
            return components
        }

        if totalSeconds >= minute {
            return [
                RemainingExpiryMetricComponent(
                    value: "\(totalSeconds / minute)",
                    unit: "分钟"
                )
            ]
        }

        return [
            RemainingExpiryMetricComponent(
                value: "\(totalSeconds)",
                unit: "秒"
            )
        ]
    }

    private static func menuBarText(for totalSeconds: Int) -> String {
        if totalSeconds >= day {
            let days = totalSeconds / day
            let hours = (totalSeconds % day) / hour
            return "\(days)d\(hours)h"
        }

        if totalSeconds >= hour {
            let hours = totalSeconds / hour
            let minutes = (totalSeconds % hour) / minute
            return "\(hours)h\(minutes)m"
        }

        if totalSeconds >= minute {
            let minutes = totalSeconds / minute
            return "\(minutes)m"
        }

        return "1m"
    }
}
