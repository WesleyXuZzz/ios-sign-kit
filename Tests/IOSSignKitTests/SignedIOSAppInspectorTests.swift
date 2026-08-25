import Foundation
import Testing
@testable import IOSSignKit

struct SignedIOSAppInspectorTests {
    @Test
    func acceptsContainedSignedApplicationWithMatchingProfile() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        let artifact = try await inspector.inspect(
            SignedIOSAppInspectionRequest(
                derivedDataRootURL: fixture.derivedDataRootURL,
                candidate: .application(fixture.applicationURL),
                expectedBundleIdentifier: "com.example.Sample",
                targetDeviceID: "DEVICE-123",
                profileRefreshMode: .automatic,
                previousProfileDigest: nil,
                now: fixture.now
            )
        )

        #expect(artifact.applicationURL == fixture.applicationURL)
        #expect(artifact.bundleIdentifier == "com.example.Sample")
        #expect(artifact.shortVersion == "1.2.3")
        #expect(artifact.buildVersion == "45")
        #expect(artifact.profileUUID == "12345678-1234-1234-1234-1234567890AB")
        #expect(artifact.profileExpirationDate == fixture.expirationDate)
        #expect(artifact.profileTeamIdentifier == "TEAM123456")
        #expect(artifact.profileDigest == "f083fbfe4665c2edbc9b55422c9d086c8f2e8cf91d7959154a1f70d9c0ff4ab0")
    }

    @Test
    func resolvesTheOnlyMatchingApplicationFromProductsDirectory() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        let artifact = try await inspector.inspect(
            fixture.request(candidate: .productsDirectory(fixture.productsDirectoryURL))
        )

        #expect(artifact.applicationURL == fixture.applicationURL)
        #expect(artifact.bundleIdentifier == "com.example.Sample")
    }

    @Test
    func rejectsMalformedProvisionedDevicesInsteadOfTreatingItAsAbsent() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let malformedProfile = try fixture.profileData(
            replacing: "DEVICE-123",
            forKey: "ProvisionedDevices"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in malformedProfile }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("存在但类型错误的 ProvisionedDevices 不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .invalidProvisioningProfile = error else {
                Issue.record("应返回 Profile 结构错误，实际为：\(error)")
                return
            }
        }
    }

    @Test
    func forceModeRejectsDigestMatchingAnyPreviouslyIsolatedProfile() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )
        let request = SignedIOSAppInspectionRequest(
            derivedDataRootURL: fixture.derivedDataRootURL,
            candidate: .application(fixture.applicationURL),
            expectedBundleIdentifier: "com.example.Sample",
            targetDeviceID: "DEVICE-123",
            profileRefreshMode: .force,
            previousProfileDigests: [
                String(repeating: "0", count: 64),
                "F083FBFE4665C2EDBC9B55422C9D086C8F2E8CF91D7959154A1F70D9C0FF4AB0"
            ],
            now: fixture.now
        )

        do {
            _ = try await inspector.inspect(request)
            Issue.record("强制刷新不得接受任一旧 Profile 指纹。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .profileWasNotRefreshed)
        }
    }

    @Test
    func productsDirectoryRejectsMultipleApplicationsWithTheSameBundleID() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let duplicateURL = fixture.productsDirectoryURL
            .appendingPathComponent("Archive/SampleCopy.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: duplicateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture.applicationURL,
            to: duplicateURL
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(
                    candidate: .productsDirectory(fixture.productsDirectoryURL)
                )
            )
            Issue.record("多个相同 Bundle ID 的 App 不得被自动猜测。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .multipleMatchingApplications)
        }
    }

    @Test
    func productsDirectoryStopsWhenEntryCountExceedsBound() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        for index in 0...SignedIOSAppInspector.maximumProductSearchEntryCount {
            try Data().write(
                to: fixture.productsDirectoryURL
                    .appendingPathComponent("decoy-\(index).txt")
            )
        }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(
                    candidate: .productsDirectory(fixture.productsDirectoryURL)
                )
            )
            Issue.record("产品目录超出数量上限时不得继续扫描。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .applicationSearchLimitExceeded)
        }
    }

    @Test
    func productsDirectoryDoesNotDescendPastDepthBound() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        var deepDirectoryURL = fixture.productsDirectoryURL
        for depth in 0...SignedIOSAppInspector.maximumProductSearchDepth {
            deepDirectoryURL.appendPathComponent("level-\(depth)", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: deepDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture.applicationURL,
            to: deepDirectoryURL.appendingPathComponent(
                "DeepSample.app",
                isDirectory: true
            )
        )
        try fixture.replaceInfoValue(
            "com.example.Other",
            forKey: "CFBundleIdentifier"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(
                    candidate: .productsDirectory(fixture.productsDirectoryURL)
                )
            )
            Issue.record("产品目录不得扫描超过声明上限的深层产物。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .applicationUnavailable)
        }
    }

    @Test
    func rejectsApplicationOutsideControlledDerivedData() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let outsideURL = fixture.derivedDataRootURL
            .deletingLastPathComponent()
            .appendingPathComponent("Outside.app", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.applicationURL, to: outsideURL)
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(candidate: .application(outsideURL))
            )
            Issue.record("DerivedData 外的 App 不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .artifactOutsideDerivedData)
        }
    }

    @Test
    func rejectsApplicationSymlinkEscapingControlledDerivedData() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let outsideURL = fixture.derivedDataRootURL
            .deletingLastPathComponent()
            .appendingPathComponent("Outside.app", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.applicationURL, to: outsideURL)
        let linkURL = fixture.productsDirectoryURL
            .appendingPathComponent("Escaped.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outsideURL
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(candidate: .application(linkURL))
            )
            Issue.record("逃逸 DerivedData 的 App 符号链接不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .artifactOutsideDerivedData)
        }
    }

    @Test
    func rejectsInfoPlistWithDifferentBundleIdentifier() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        try fixture.replaceInfoValue(
            "com.example.Other",
            forKey: "CFBundleIdentifier"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("Info.plist Bundle ID 不一致时不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .bundleIdentifierMismatch(
                expected: "com.example.Sample",
                actual: "com.example.Other"
            ))
        }
    }

    @Test
    func rejectsMainExecutableWithoutExecutePermission() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.applicationURL
                .appendingPathComponent("Sample").path
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("不可执行的主程序不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .invalidExecutable)
        }
    }

    @Test
    func rejectsExpiredProvisioningProfile() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let expiredProfile = try fixture.profileData(
            replacing: fixture.now,
            forKey: "ExpirationDate"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in expiredProfile }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("已过期的 Profile 不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .profileExpired(fixture.now))
        }
    }

    @Test
    func rejectsProfileForDifferentApplicationIdentifier() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let wrongProfile = try fixture.profileData(
            replacingEntitlement: "TEAM123456.com.example.Other",
            forKey: "application-identifier"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in wrongProfile }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("其他 Bundle ID 的 Profile 不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .profileApplicationIdentifierMismatch)
        }
    }

    @Test
    func rejectsProfileThatDoesNotContainTargetDevice() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let wrongDeviceProfile = try fixture.profileData(
            replacing: ["OTHER-DEVICE"],
            forKey: "ProvisionedDevices"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in wrongDeviceProfile }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("不包含目标设备的开发 Profile 不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .profileDoesNotIncludeDevice)
        }
    }

    @Test
    func rejectsProfileWithoutProvisionedDevicesField() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let distributionStyleProfile = try fixture.profileData(
            replacing: nil,
            forKey: "ProvisionedDevices"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in distributionStyleProfile }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("缺少 ProvisionedDevices 的分发 Profile 不得作为个人开发签名安装。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .invalidProvisioningProfile = error else {
                Issue.record("应返回开发 Profile 结构错误，实际为：\(error)")
                return
            }
        }
    }

    @Test
    func rejectsProfileFromDifferentXcodeDevelopmentTeam() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(expectedTeamIdentifier: "OTHER12345")
            )
            Issue.record("Profile Team 与 Xcode DEVELOPMENT_TEAM 不一致时不得安装。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .profileTeamIdentifierMismatch(
                expected: "OTHER12345",
                actual: "TEAM123456"
            ))
        }
    }

    @Test
    func rejectsApplicationIdentifierWithForgedTeamPrefix() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let forgedProfile = try fixture.profileData(
            replacingEntitlement: "OTHER12345.com.example.Sample",
            forKey: "application-identifier"
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in forgedProfile }
        )

        do {
            _ = try await inspector.inspect(
                fixture.request(expectedTeamIdentifier: "TEAM123456")
            )
            Issue.record("application-identifier 的 Team 前缀必须与 Profile Team 精确一致。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .profileApplicationIdentifierMismatch)
        }
    }

    @Test
    func rejectsDecodedProfileOutputAboveLimit() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in
                Data(
                    repeating: 0x41,
                    count: SignedIOSAppInspector.maximumDecodedProfileBytes + 1
                )
            }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("超出上限的 Profile 解码输出不得进入 plist 解析。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .invalidProvisioningProfile = error else {
                Issue.record("应返回 Profile 大小错误，实际为：\(error)")
                return
            }
        }
    }

    @Test
    func rejectsProvisioningProfileFileAboveLimit() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        try Data(
            repeating: 0x41,
            count: SignedIOSAppInspector.maximumProvisioningProfileBytes + 1
        ).write(
            to: fixture.applicationURL
                .appendingPathComponent("embedded.mobileprovision")
        )
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("超出上限的 embedded.mobileprovision 不得通过核验。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .invalidProvisioningProfile = error else {
                Issue.record("应返回 Profile 大小错误，实际为：\(error)")
                return
            }
        }
    }

    @Test
    func reportsInjectedCodeSignatureFailure() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in
                throw SignedIOSAppTestSignatureError.invalid
            },
            decodeProvisioningProfile: { _ in fixture.profilePlistData }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("代码签名失败时不得返回已验证产物。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .codeSignatureInvalid = error else {
                Issue.record("应返回代码签名错误，实际为：\(error)")
                return
            }
        }
    }

    @Test
    func rejectsProfileChangedWhileItIsBeingDecoded() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector(
            validateCodeSignature: { _ in },
            decodeProvisioningProfile: { profileURL in
                try Data("changed-profile".utf8).write(to: profileURL)
                return fixture.profilePlistData
            }
        )

        do {
            _ = try await inspector.inspect(fixture.request())
            Issue.record("核验期间被替换的 Profile 不得返回旧指纹。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .invalidProvisioningProfile = error else {
                Issue.record("应返回 Profile 稳定性错误，实际为：\(error)")
                return
            }
        }
    }

    @Test
    func productionBoundaryUsesSecurityAndCodesignWithoutShell() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let deploymentToken =
            "ios-sign-kit-deploy-12345678-1234-1234-1234-1234567890ab"
        let recorder = SignedIOSAppCommandRecorder(
            profilePlistData: fixture.profilePlistData
        )
        let inspector = SignedIOSAppInspector(runCommand: recorder.run)

        _ = try await inspector.inspect(
            fixture.request(deploymentToken: deploymentToken)
        )

        #expect(recorder.snapshot() == [
            SignedIOSAppCommandRecorder.Invocation(
                launchPath: "/usr/bin/security",
                arguments: [
                    "cms", "-D", "-i",
                    fixture.applicationURL
                        .appendingPathComponent("embedded.mobileprovision").path
                ],
                environmentOverrides: [
                    DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                        deploymentToken
                ],
                timeoutSeconds: 10
            ),
            SignedIOSAppCommandRecorder.Invocation(
                launchPath: "/usr/bin/codesign",
                arguments: [
                    "--verify", "--deep", "--strict", "--verbose=2",
                    fixture.applicationURL.path
                ],
                environmentOverrides: [
                    DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                        deploymentToken
                ],
                timeoutSeconds: 15
            )
        ])
    }

    @Test
    func rejectsMalformedDeploymentTokenBeforeRunningExternalCommands() async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let recorder = SignedIOSAppCommandRecorder(
            profilePlistData: fixture.profilePlistData
        )
        let inspector = SignedIOSAppInspector(runCommand: recorder.run)

        do {
            _ = try await inspector.inspect(
                fixture.request(deploymentToken: "not-a-deployment-token")
            )
            Issue.record("非法部署令牌不得进入外部命令。")
        } catch let error as SignedIOSAppInspectionError {
            #expect(error == .invalidRequest("部署令牌"))
        }
        #expect(recorder.snapshot().isEmpty)
    }

    @Test(arguments: ["/usr/bin/security", "/usr/bin/codesign"])
    func reportsUnconfirmedSecurityOrCodesignProcessTree(
        unresolvedLaunchPath: String
    ) async throws {
        let fixture = try SignedIOSAppFixture()
        defer { fixture.remove() }
        let inspector = SignedIOSAppInspector { launchPath, _, _, _ in
            CommandResult(
                standardOutput: launchPath == "/usr/bin/security"
                    ? String(decoding: fixture.profilePlistData, as: UTF8.self)
                    : "",
                standardError: "",
                terminationStatus: 0,
                processGroupTerminationWasConfirmed:
                    launchPath != unresolvedLaunchPath
            )
        }

        do {
            _ = try await inspector.inspect(
                fixture.request(expectedTeamIdentifier: "TEAM123456")
            )
            Issue.record("外部核验命令的进程树未确认结束时不得返回产物。")
        } catch let error as SignedIOSAppInspectionError {
            guard case .commandProcessTreeUnresolved = error else {
                Issue.record("应返回进程树未结束错误，实际为：\(error)")
                return
            }
        }
    }
}

private final class SignedIOSAppFixture: @unchecked Sendable {
    let derivedDataRootURL: URL
    let applicationURL: URL
    let profilePlistData: Data
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let expirationDate = Date(timeIntervalSince1970: 1_700_086_400)

    var productsDirectoryURL: URL {
        applicationURL.deletingLastPathComponent()
    }

    init() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-signed-app-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        derivedDataRootURL = temporaryRoot
            .appendingPathComponent("DerivedData", isDirectory: true)
        applicationURL = derivedDataRootURL
            .appendingPathComponent(
                "Build/Products/Debug-iphoneos/Sample.app",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )

        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.Sample",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45",
                "CFBundleExecutable": "Sample"
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: applicationURL.appendingPathComponent("Info.plist"))

        let executableURL = applicationURL.appendingPathComponent("Sample")
        try Data("executable".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        try Data("cms-fixture".utf8).write(
            to: applicationURL.appendingPathComponent("embedded.mobileprovision")
        )
        profilePlistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "UUID": "12345678-1234-1234-1234-1234567890AB",
                "ExpirationDate": expirationDate,
                "TeamIdentifier": ["TEAM123456"],
                "ProvisionedDevices": ["DEVICE-123", "DEVICE-456"],
                "Entitlements": [
                    "application-identifier": "TEAM123456.com.example.Sample",
                    "com.apple.developer.team-identifier": "TEAM123456"
                ]
            ],
            format: .xml,
            options: 0
        )
    }

    func remove() {
        try? FileManager.default.removeItem(
            at: derivedDataRootURL.deletingLastPathComponent()
        )
    }

    func request(
        candidate: SignedIOSAppCandidate? = nil,
        deploymentToken: String? = nil,
        expectedTeamIdentifier: String? = nil,
        profileRefreshMode: ProvisioningProfileRefreshMode = .automatic,
        previousProfileDigest: String? = nil
    ) -> SignedIOSAppInspectionRequest {
        SignedIOSAppInspectionRequest(
            derivedDataRootURL: derivedDataRootURL,
            candidate: candidate ?? .application(applicationURL),
            expectedBundleIdentifier: "com.example.Sample",
            expectedTeamIdentifier: expectedTeamIdentifier,
            targetDeviceID: "DEVICE-123",
            deploymentToken: deploymentToken,
            profileRefreshMode: profileRefreshMode,
            previousProfileDigest: previousProfileDigest,
            now: now
        )
    }

    func profileData(replacing value: Any?, forKey key: String) throws -> Data {
        guard var dictionary = try PropertyListSerialization.propertyList(
            from: profilePlistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SignedIOSAppFixtureError.invalidProfileFixture
        }
        dictionary[key] = value
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }

    func profileData(
        replacingEntitlement value: Any?,
        forKey key: String
    ) throws -> Data {
        guard var dictionary = try PropertyListSerialization.propertyList(
            from: profilePlistData,
            options: [],
            format: nil
        ) as? [String: Any],
              var entitlements = dictionary["Entitlements"] as? [String: Any] else {
            throw SignedIOSAppFixtureError.invalidProfileFixture
        }
        entitlements[key] = value
        dictionary["Entitlements"] = entitlements
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }

    func replaceInfoValue(_ value: Any?, forKey key: String) throws {
        let infoURL = applicationURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard var dictionary = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SignedIOSAppFixtureError.invalidInfoFixture
        }
        dictionary[key] = value
        let updatedData = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try updatedData.write(to: infoURL)
    }
}

private enum SignedIOSAppFixtureError: Error {
    case invalidProfileFixture
    case invalidInfoFixture
}

private enum SignedIOSAppTestSignatureError: Error {
    case invalid
}

private final class SignedIOSAppCommandRecorder: @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        let launchPath: String
        let arguments: [String]
        let environmentOverrides: [String: String]
        let timeoutSeconds: TimeInterval?
    }

    private let lock = NSLock()
    private let profilePlistData: Data
    private var invocations: [Invocation] = []

    init(profilePlistData: Data) {
        self.profilePlistData = profilePlistData
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ environmentOverrides: [String: String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        lock.withLock {
            invocations.append(Invocation(
                launchPath: launchPath,
                arguments: arguments,
                environmentOverrides: environmentOverrides,
                timeoutSeconds: timeoutSeconds
            ))
        }
        if launchPath == "/usr/bin/security" {
            return CommandResult(
                standardOutput: String(decoding: profilePlistData, as: UTF8.self),
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }

    func snapshot() -> [Invocation] {
        lock.withLock { invocations }
    }
}
