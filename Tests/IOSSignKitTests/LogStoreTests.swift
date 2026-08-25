import Foundation
import Testing
@testable import IOSSignKit

struct LogStoreTests {
    @Test
    func generatesFilenameUsingUTCPlusEight() throws {
        let date = try referenceDate()

        #expect(
            DeployLogFilename.make(for: date)
                == "deploy-2026-07-11-00-56-20.371-T+08-00.log"
        )
    }

    @Test
    func parsesUTCPlusEightFilename() throws {
        let expectedDate = try referenceDate()
        let parsedDate = try #require(
            DeployLogFilename.date(
                from: "deploy-2026-07-11-00-56-20.371-T+08-00.log"
            )
        )

        #expect(parsedDate == expectedDate)
    }

    @Test
    func rejectsLegacyUTCFilename() {
        #expect(
            DeployLogFilename.date(
                from: "deploy-2026-07-10T16-56-20.371Z.log"
            ) == nil
        )
    }

    private func referenceDate() throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: "2026-07-10T16:56:20.371Z"))
    }
}
