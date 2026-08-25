import Testing
@testable import IOSSignKit

struct ApplicationVersionPresentationTests {
    @Test
    func keepsBuildNumberOutOfThePersistentSidebarLabel() {
        let presentation = ApplicationVersionPresentation.make(
            infoDictionary: [
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
            ]
        )

        #expect(presentation.sidebarText == "版本 1.0.0")
        #expect(presentation.detailText == "版本 1.0.0（构建 1）")
    }

    @Test
    func doesNotInventAReleaseVersionWhenBundleMetadataIsUnavailable() {
        let presentation = ApplicationVersionPresentation.make(
            infoDictionary: nil
        )

        #expect(presentation.sidebarText == "版本 —")
        #expect(presentation.detailText == "版本信息不可用")
    }

    @Test
    func normalizesBlankBundleValues() {
        let presentation = ApplicationVersionPresentation.make(
            infoDictionary: [
                "CFBundleShortVersionString": "  \n",
                "CFBundleVersion": " 2 ",
            ]
        )

        #expect(presentation.sidebarText == "版本 —")
        #expect(presentation.detailText == "构建 2")
    }
}
