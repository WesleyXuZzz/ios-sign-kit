import Foundation
import Testing
@testable import IOSSignKit

struct DeployResultTests {
    @Test
    func legacyPayloadDefaultsNewReceiptFieldsSafely() throws {
        let json = """
        {
          "startedAt": "2026-08-19T00:00:00Z",
          "finishedAt": "2026-08-19T00:01:00Z",
          "outcome": "success",
          "summary": "续签已完成。",
          "logPath": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let result = try decoder.decode(
            DeployResult.self,
            from: Data(json.utf8)
        )

        #expect(result.verifiedProfileExpirationDate == nil)
        #expect(result.processGroupTerminationWasConfirmed)
        #expect(result.profileCacheRecoveryWasConfirmed)
    }

    @Test
    func verifiedProfileExpirationDateSurvivesCodableRoundTrip() throws {
        let expirationDate = Date(timeIntervalSinceReferenceDate: 800_000)
        let original = DeployResult(
            startedAt: Date(timeIntervalSinceReferenceDate: 700_000),
            finishedAt: Date(timeIntervalSinceReferenceDate: 700_030),
            outcome: .success,
            summary: "续签已完成。",
            logPath: "/tmp/deployment.log",
            verifiedProfileExpirationDate: expirationDate
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            DeployResult.self,
            from: encoded
        )

        #expect(decoded == original)
        #expect(decoded.verifiedProfileExpirationDate == expirationDate)
    }

    @Test
    func profileCacheRecoveryEvidenceSurvivesCodableRoundTrip() throws {
        let original = DeployResult(
            startedAt: Date(timeIntervalSinceReferenceDate: 700_000),
            finishedAt: Date(timeIntervalSinceReferenceDate: 700_030),
            outcome: .failure,
            summary: "签名描述文件缓存恢复失败。",
            logPath: "/tmp/deployment.log",
            profileCacheRecoveryWasConfirmed: false
        )

        let decoded = try JSONDecoder().decode(
            DeployResult.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
        #expect(!decoded.profileCacheRecoveryWasConfirmed)
    }
}
