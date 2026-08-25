import Foundation

struct VerificationTimePresentation: Equatable {
    let absoluteText: String
    let relativeText: String
    let timeText: String

    var compactSummary: String {
        absoluteText
    }

    var fullVerificationSummary: String {
        "上次核验 \(timeText)"
    }

    static func make(
        date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> VerificationTimePresentation {
        let timeText = timeText(
            for: date,
            calendar: calendar
        )
        return VerificationTimePresentation(
            absoluteText: absoluteText(
                for: date,
                now: now,
                calendar: calendar,
                timeText: timeText
            ),
            relativeText: relativeText(for: date, now: now),
            timeText: timeText
        )
    }

    private static func absoluteText(
        for date: Date,
        now: Date,
        calendar: Calendar,
        timeText: String
    ) -> String {
        let dayPrefix: String
        if calendar.isDate(date, inSameDayAs: now) {
            dayPrefix = "今天"
        } else if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            dayPrefix = "昨天"
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.calendar = calendar
            dateFormatter.locale = Locale(identifier: "zh_CN")
            dateFormatter.timeZone = calendar.timeZone
            dateFormatter.dateFormat = calendar.component(
                .year,
                from: date
            ) == calendar.component(.year, from: now)
                ? "MM-dd"
                : "yyyy-MM-dd"
            dayPrefix = dateFormatter.string(from: date)
        }

        return "\(dayPrefix) \(timeText)"
    }

    private static func timeText(
        for date: Date,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func relativeText(
        for date: Date,
        now: Date
    ) -> String {
        let interval = now.timeIntervalSince(date)
        let magnitude = abs(interval)
        guard magnitude >= 60 else {
            return "刚刚"
        }

        let value: Int
        let unit: String
        if magnitude >= 24 * 60 * 60 {
            value = max(Int(magnitude / (24 * 60 * 60)), 1)
            unit = "天"
        } else if magnitude >= 60 * 60 {
            value = max(Int(magnitude / (60 * 60)), 1)
            unit = "小时"
        } else {
            value = max(Int(magnitude / 60), 1)
            unit = "分钟"
        }

        return "\(value) \(unit)\(interval >= 0 ? "前" : "后")"
    }
}
