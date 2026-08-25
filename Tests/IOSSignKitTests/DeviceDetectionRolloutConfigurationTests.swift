import Testing
@testable import IOSSignKit

struct DeviceDetectionRolloutConfigurationTests {
    @Test
    func missingConfigurationDefaultsToProduction() {
        let configuration = DeviceDetectionRolloutConfiguration(
            processEnvironment: [:]
        )
        let decision = DeviceDetectionRolloutController().decision(
            for: configuration.mode
        )

        #expect(configuration.mode == .production)
        #expect(decision.primaryEngine == .canonical)
        #expect(decision.comparison == nil)
        #expect(decision.allowsCriticalActions)
        #expect(configuration.resolution.diagnostic == nil)
    }

    @Test
    func acceptsSupportedRolloutModes() {
        let acceptedValues: [
            (configuredValue: String, expected: DeviceDetectionRolloutMode)
        ] = [
            ("fallback", .fallback),
            ("shadow", .shadow),
            ("readOnly", .readOnly),
            ("production", .production)
        ]

        for acceptedValue in acceptedValues {
            let configuration = DeviceDetectionRolloutConfiguration(
                processEnvironment: [
                    DeviceDetectionRolloutConfiguration.environmentKey:
                        acceptedValue.configuredValue
                ]
            )

            #expect(configuration.mode == acceptedValue.expected)
            #expect(configuration.resolution.diagnostic == nil)
        }
    }

    @Test
    func invalidConfigurationFailsClosedToReadOnlyWithDiagnostic() {
        for invalidValue in [
            "",
            "Shadow",
            "read-only",
            " readOnly ",
            "unknown",
            "legacy",
            "v2ReadOnly",
            "v2"
        ] {
            let configuration = DeviceDetectionRolloutConfiguration(
                processEnvironment: [
                    DeviceDetectionRolloutConfiguration.environmentKey:
                        invalidValue
                ]
            )

            #expect(configuration.mode == .readOnly)
            #expect(
                configuration.resolution.diagnostic?.message.isEmpty == false
            )
        }
    }

    @Test
    func productionConfigurationCanBeSelectedExplicitly() {
        let configuration = DeviceDetectionRolloutConfiguration(
            processEnvironment: [
                DeviceDetectionRolloutConfiguration.environmentKey: "production"
            ]
        )

        #expect(configuration.mode == .production)
    }
}
