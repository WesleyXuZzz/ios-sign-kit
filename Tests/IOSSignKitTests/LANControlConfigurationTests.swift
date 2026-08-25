import Foundation
import Network
import Testing
@testable import IOSSignKit

struct LANControlConfigurationTests {
    @Test
    func validatesHostNamesIPv4AndPortRange() {
        #expect(
            LANControlConfiguration.validationMessage(
                host: "my-mac.local",
                port: 51_888
            ) == nil
        )
        #expect(
            LANControlConfiguration.validationMessage(
                host: "192.168.1.42",
                port: 51_888
            ) == nil
        )
        #expect(
            LANControlConfiguration.validationMessage(
                host: "http://my-mac.local",
                port: 51_888
            )?.contains("协议") == true
        )
        #expect(
            LANControlConfiguration.validationMessage(
                host: "my-mac.local:51888",
                port: 51_888
            ) != nil
        )
        #expect(
            LANControlConfiguration.validationMessage(
                host: "999.1.1.1",
                port: 51_888
            ) != nil
        )
        #expect(
            LANControlConfiguration.validationMessage(
                host: "my-mac.local",
                port: 80
            )?.contains("1024") == true
        )
    }

    @Test
    func passwordCredentialVerifiesWithoutPersistingPlaintext() throws {
        let credential = try LANControlPasswordCredential.make(
            password: "secret-pass",
            salt: Data(repeating: 7, count: 16),
            rounds: 4
        )

        #expect(credential.verifies("secret-pass"))
        #expect(!credential.verifies("wrong-pass"))

        let encoded = try JSONEncoder().encode(credential)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret-pass"))
    }

    @Test
    func legacyConfigDecodesWithLANControlDisabled() throws {
        let data = Data(
            #"{"checkIntervalMinutes":5,"reminderCooldownHours":24}"#.utf8
        )

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(!config.lanControl.isEnabled)
        #expect(config.lanControl.port == 51_888)
        #expect(config.lanControl.passwordCredential == nil)
        #expect(config.lanControl.accessURL != nil)
    }

    @Test
    func listenerAcceptsPrivateAddressesAndRejectsPublicAddresses() throws {
        let port = try #require(NWEndpoint.Port(rawValue: 51_888))
        #expect(
            LANControlServerController.isLocalNetworkEndpoint(
                .hostPort(host: "192.168.1.42", port: port)
            )
        )
        #expect(
            LANControlServerController.isLocalNetworkEndpoint(
                .hostPort(host: "fe80::1", port: port)
            )
        )
        #expect(
            !LANControlServerController.isLocalNetworkEndpoint(
                .hostPort(host: "8.8.8.8", port: port)
            )
        )
    }
}

@MainActor
struct LANControlSetupDraftTests {
    @Test
    func enablingRequiresMatchingPasswordAndBuildsDraftURL() {
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )

        viewModel.lanControlEnabled = true
        viewModel.lanControlHost = "192.168.1.42"
        viewModel.lanControlPortText = "51888"
        #expect(viewModel.lanControlValidationMessage?.contains("密码") == true)

        viewModel.lanControlPassword = "secret-pass"
        viewModel.lanControlPasswordConfirmation = "different"
        #expect(viewModel.lanControlValidationMessage?.contains("不一致") == true)

        viewModel.lanControlPasswordConfirmation = "secret-pass"
        #expect(viewModel.lanControlValidationMessage == nil)
        #expect(
            viewModel.lanControlDraftURL?.absoluteString
                == "http://192.168.1.42:51888"
        )
        #expect(viewModel.hasUnsavedLANControlChanges)
    }
}
