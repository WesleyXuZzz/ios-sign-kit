import Testing
@testable import IOSSignKit

struct DeviceMatcherTests {
    @Test
    func prefersDeviceIDOverName() {
        let matcher = DeviceMatcher()
        let devices = [
            DeviceInfo(id: "1", name: "Phone A", platform: "com.apple.platform.iphoneos", osVersion: "18", isAvailable: true, isPaired: true),
            DeviceInfo(id: "2", name: "Phone B", platform: "com.apple.platform.iphoneos", osVersion: "18", isAvailable: true, isPaired: true)
        ]

        let matched = matcher.match(preferredDeviceID: "2", preferredDeviceName: "Phone A", devices: devices)
        #expect(matched.device?.id == "2")
    }

    @Test
    func fallsBackToSingleAvailableDevice() {
        let matcher = DeviceMatcher()
        let devices = [
            DeviceInfo(id: "1", name: "Only Phone", platform: "com.apple.platform.iphoneos", osVersion: "18", isAvailable: true, isPaired: true)
        ]

        let matched = matcher.match(preferredDeviceID: nil, preferredDeviceName: nil, devices: devices)
        #expect(matched.device?.id == "1")
    }

    @Test
    func pinnedIdentifierNeverFallsBackToAnotherDevice() {
        let matcher = DeviceMatcher()
        let devices = [
            DeviceInfo(id: "other", name: "Phone A", platform: "com.apple.platform.iphoneos", osVersion: "18", isAvailable: true, isPaired: true)
        ]

        let result = matcher.match(
            preferredDeviceID: "missing",
            preferredDeviceName: "Phone A",
            devices: devices
        )

        #expect(result == .preferredIdentifierUnavailable("missing"))
        #expect(result.device == nil)
    }

    @Test
    func duplicatePreferredNamesAreAmbiguous() {
        let matcher = DeviceMatcher()
        let devices = [
            DeviceInfo(id: "1", name: "Phone", platform: "com.apple.platform.iphoneos", osVersion: "18", isAvailable: true, isPaired: true),
            DeviceInfo(id: "2", name: "Phone", platform: "com.apple.platform.iphoneos", osVersion: "18", isAvailable: true, isPaired: true)
        ]

        let result = matcher.match(
            preferredDeviceID: nil,
            preferredDeviceName: "Phone",
            devices: devices
        )

        #expect(result == .ambiguousName("Phone", matchingDeviceIDs: ["1", "2"]))
        #expect(result.device == nil)
    }
}
