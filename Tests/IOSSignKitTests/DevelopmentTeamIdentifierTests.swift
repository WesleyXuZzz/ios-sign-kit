import Testing
@testable import IOSSignKit

struct DevelopmentTeamIdentifierTests {
    @Test
    func acceptsExactlyTenUppercaseASCIILettersOrDigits() {
        #expect(
            DevelopmentTeamIdentifier(rawValue: "TEAM123456")?.rawValue
                == "TEAM123456"
        )
        #expect(
            DevelopmentTeamIdentifier(rawValue: "1234567890")?.rawValue
                == "1234567890"
        )
    }

    @Test(arguments: [
        "TEAM12345",
        "TEAM1234567",
        "team123456",
        "TEAM-23456",
        "TEAM 23456",
        "团队12345678"
    ])
    func rejectsValuesOutsideTheXcodeDevelopmentTeamContract(
        value: String
    ) {
        #expect(DevelopmentTeamIdentifier(rawValue: value) == nil)
    }
}
