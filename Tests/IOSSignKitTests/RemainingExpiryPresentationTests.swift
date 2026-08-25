import Foundation
import Testing
@testable import IOSSignKit

struct RemainingExpiryPresentationTests {
    @Test
    func formatsPanelWithDaysAndHours() {
        let presentation = makePresentation(seconds: 6 * day + 12 * hour + 12 * minute)

        #expect(presentation.panelText == "6天 12小时")
        #expect(
            presentation.metricComponents == [
                RemainingExpiryMetricComponent(value: "6", unit: "天"),
                RemainingExpiryMetricComponent(value: "12", unit: "小时")
            ]
        )
        #expect(presentation.menuBarText == "6d12h")
        #expect(presentation.isExpired == false)
    }

    @Test
    func formatsPanelWithHoursAndMinutesUnderOneDay() {
        let presentation = makePresentation(seconds: 10 * hour + 40 * minute + 10)

        #expect(presentation.panelText == "10小时 40分钟")
        #expect(presentation.menuBarText == "10h40m")
        #expect(presentation.isExpired == false)
    }

    @Test
    func formatsMinutesUnderOneHour() {
        let presentation = makePresentation(seconds: 59 * minute + 12)

        #expect(presentation.panelText == "59分钟")
        #expect(presentation.menuBarText == "59m")
        #expect(presentation.isExpired == false)
    }

    @Test
    func formatsSecondsUnderOneMinute() {
        let presentation = makePresentation(seconds: 42)

        #expect(presentation.panelText == "42秒")
        #expect(presentation.menuBarText == "1m")
        #expect(presentation.isExpired == false)
        #expect(presentation.nextUpdateInterval == 1)
    }

    @Test
    func formatsExpiredState() {
        let presentation = makePresentation(seconds: 0)

        #expect(presentation.panelText == "到期")
        #expect(
            presentation.metricComponents == [
                RemainingExpiryMetricComponent(value: "到期", unit: nil)
            ]
        )
        #expect(presentation.menuBarText == "到期")
        #expect(presentation.isExpired == true)
        #expect(presentation.expiredDurationText == "刚刚到期")
        #expect(presentation.nextUpdateInterval == nil)
    }

    @Test
    func formatsElapsedTimeForAnExpiredSignature() {
        #expect(
            makePresentation(seconds: -(2 * hour + 10 * minute))
                .expiredDurationText == "2 小时前"
        )
        #expect(
            makePresentation(seconds: -(3 * day + hour))
                .expiredDurationText == "3 天前"
        )
    }

    @Test
    func formatsUnknownState() {
        let presentation = RemainingExpiryPresentation.make(expiryDate: nil, now: testNow)

        #expect(presentation.panelText == "--")
        #expect(presentation.metricComponents.isEmpty)
        #expect(presentation.menuBarText == nil)
        #expect(presentation.isExpired == false)
        #expect(presentation.nextUpdateInterval == nil)
        #expect(presentation.progressFraction == nil)
        #expect(presentation.urgency == .unknown)
    }

    @Test
    func schedulesMinuteLevelUpdatesUnderOneDay() {
        let presentation = makePresentation(seconds: 2 * hour + 15 * minute + 20)

        #expect(presentation.nextUpdateInterval == 21)
    }

    @Test
    func schedulesHourLevelUpdatesWhenDaysAreVisible() {
        let presentation = makePresentation(
            seconds: 6 * day + 12 * hour + 34 * minute + 20
        )

        #expect(presentation.nextUpdateInterval == 34 * minute + 21)
    }

    @Test
    func schedulesMinuteLevelUpdatesWhenOnlyMinutesAreVisible() {
        let presentation = makePresentation(seconds: 59 * minute + 12)

        #expect(presentation.nextUpdateInterval == 13)
    }

    @Test
    func formatsMenuBarBoundaryValues() {
        let cases: [(TimeInterval, String)] = [
            (day, "1d0h"),
            (day - 1, "23h59m"),
            (hour, "1h0m"),
            (hour - 1, "59m"),
            (minute, "1m"),
            (minute - 1, "1m"),
            (1, "1m"),
            (0, "到期")
        ]

        for (seconds, expected) in cases {
            #expect(makePresentation(seconds: seconds).menuBarText == expected)
        }
    }

    @Test
    func floorsFractionalSecondsBeforeFormatting() {
        let presentation = makePresentation(
            seconds: 10 * hour + 40 * minute + 59.9
        )

        #expect(presentation.remainingSeconds == Int(10 * hour + 40 * minute + 59))
        #expect(presentation.menuBarText == "10h40m")
    }

    @Test
    func calculatesSevenDayProgressAndClampsValues() {
        let full = makePresentation(seconds: 7 * day)
        let partial = makePresentation(seconds: 2 * day + 10 * hour)
        let beyondFull = makePresentation(seconds: 8 * day)
        let expired = makePresentation(seconds: 0)

        #expect(full.progressFraction == 1)
        #expect(abs((partial.progressFraction ?? 0) - (58.0 / 168.0)) < 0.000_001)
        #expect(beyondFull.progressFraction == 1)
        #expect(expired.progressFraction == 0)

        let oneDayRemaining = makePresentation(seconds: day)
        let threeDaysRemaining = makePresentation(seconds: 3 * day)
        #expect(abs((oneDayRemaining.consumedFraction ?? 0) - (6.0 / 7.0)) < 0.000_001)
        #expect(abs((threeDaysRemaining.consumedFraction ?? 0) - (4.0 / 7.0)) < 0.000_001)
        #expect(expired.consumedFraction == 1)
    }

    @Test
    func assignsSemanticUrgencyAtConfiguredThresholds() {
        #expect(makePresentation(seconds: 3 * day + 1).urgency == .healthy)
        #expect(makePresentation(seconds: 3 * day).urgency == .warning)
        #expect(makePresentation(seconds: day).urgency == .warning)
        #expect(makePresentation(seconds: day - 1).urgency == .critical)
        #expect(makePresentation(seconds: 0).urgency == .critical)
    }

    private func makePresentation(seconds: TimeInterval) -> RemainingExpiryPresentation {
        RemainingExpiryPresentation.make(
            expiryDate: testNow.addingTimeInterval(seconds),
            now: testNow
        )
    }
}

private let testNow = Date(timeIntervalSinceReferenceDate: 0)
private let minute: TimeInterval = 60
private let hour = minute * 60
private let day = hour * 24
