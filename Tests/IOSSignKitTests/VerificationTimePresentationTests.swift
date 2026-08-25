import Foundation
import Testing
@testable import IOSSignKit

struct VerificationTimePresentationTests {
    @Test
    func formatsSameDayEvidenceForTheCommandCenter() throws {
        let now = try makeDate(
            year: 2026,
            month: 7,
            day: 29,
            hour: 16,
            minute: 8
        )
        let verifiedAt = try makeDate(
            year: 2026,
            month: 7,
            day: 29,
            hour: 8,
            minute: 8
        )

        let presentation = VerificationTimePresentation.make(
            date: verifiedAt,
            now: now,
            calendar: testCalendar
        )

        #expect(presentation.absoluteText == "今天 08:08")
        #expect(presentation.relativeText == "8 小时前")
        #expect(presentation.compactSummary == "今天 08:08")
        #expect(
            presentation.fullVerificationSummary
                == "上次核验 08:08"
        )
    }

    @Test
    func clampsSmallClockSkewToJustNow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let slightlyFuture = now.addingTimeInterval(20)

        let presentation = VerificationTimePresentation.make(
            date: slightlyFuture,
            now: now,
            calendar: testCalendar
        )

        #expect(presentation.relativeText == "刚刚")
        #expect(!presentation.relativeText.contains("后"))
    }

    @Test
    func labelsYesterdayAndFutureEvidenceWithoutSeconds() throws {
        let now = try makeDate(
            year: 2026,
            month: 7,
            day: 29,
            hour: 10,
            minute: 30
        )
        let yesterday = try makeDate(
            year: 2026,
            month: 7,
            day: 28,
            hour: 9,
            minute: 5
        )
        let future = now.addingTimeInterval(2 * 60 * 60)

        let pastPresentation = VerificationTimePresentation.make(
            date: yesterday,
            now: now,
            calendar: testCalendar
        )
        let futurePresentation = VerificationTimePresentation.make(
            date: future,
            now: now,
            calendar: testCalendar
        )

        #expect(pastPresentation.absoluteText == "昨天 09:05")
        #expect(pastPresentation.relativeText == "1 天前")
        #expect(futurePresentation.relativeText == "2 小时后")
    }
}

private var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    return calendar
}

private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int
) throws -> Date {
    let components = DateComponents(
        calendar: testCalendar,
        timeZone: testCalendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )
    return try #require(testCalendar.date(from: components))
}
