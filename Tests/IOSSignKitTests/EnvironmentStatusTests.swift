import Testing
@testable import IOSSignKit

struct EnvironmentStatusTests {
    @Test
    func unknownStatusMarksEveryCheckAsUncertain() {
        let status = EnvironmentStatus.unknown

        #expect(status.isValidationComplete == false)
        #expect(status.areAllChecksPassing == false)
        #expect(status.checkItems.map(\.result) == [
            .uncertain,
            .uncertain,
            .uncertain,
            .uncertain
        ])
    }

    @Test
    func completedStatusMapsEachBooleanToItsResult() {
        let status = EnvironmentStatus(
            isXcodebuildAvailable: true,
            isXcrunAvailable: false,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "部分检查未通过"
        )

        #expect(status.isValidationComplete)
        #expect(status.areAllChecksPassing == false)
        #expect(status.checkItems.map(\.title) == [
            "Xcode 命令行工具",
            "xcrun",
            "项目目录",
            "App 目标"
        ])
        #expect(status.checkItems.map(\.result) == [
            .passed,
            .failed,
            .passed,
            .passed
        ])
    }
}
