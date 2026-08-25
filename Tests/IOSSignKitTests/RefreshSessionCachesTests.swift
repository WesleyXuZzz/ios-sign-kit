import Foundation
import Testing
@testable import IOSSignKit

struct RefreshSessionCachesTests {
    @Test
    func xcodeCandidateExpiresAtThirtyMinuteBoundary() {
        let start = ContinuousClock().now
        let key = makeXcodeKey()
        var cache = RefreshSessionCaches()
        cache.storeXcodeValidation(
            XcodeValidationCacheEntry(
                validation: XcodeProjectValidation(
                    isValid: true,
                    diagnosticMessage: nil
                ),
                observedAt: start,
                observedWallClockAt: Date(timeIntervalSince1970: 100)
            ),
            for: key
        )

        #expect(
            cache.xcodeCandidate(
                for: key,
                at: start.advanced(by: .seconds(1_799))
            ) != nil
        )
        #expect(
            cache.xcodeCandidate(
                for: key,
                at: start.advanced(by: .seconds(1_800))
            ) == nil
        )
    }

    @Test
    func installedAppCandidateExpiresAtTenMinuteBoundary() {
        let start = ContinuousClock().now
        let key = makeAppKey()
        var cache = RefreshSessionCaches()
        cache.storeInstalledApp(
            InstalledAppCacheEntry(
                result: .notInstalled,
                observedAt: start,
                observedWallClockAt: Date(timeIntervalSince1970: 100)
            ),
            for: key
        )

        #expect(
            cache.installedAppCandidate(
                for: key,
                at: start.advanced(by: .seconds(599))
            ) != nil
        )
        #expect(
            cache.installedAppCandidate(
                for: key,
                at: start.advanced(by: .seconds(600))
            ) == nil
        )
    }

    @Test
    func everyXcodeIdentityFieldParticipatesInCacheKey() {
        let start = ContinuousClock().now
        let original = makeXcodeKey()
        var cache = RefreshSessionCaches()
        cache.storeXcodeValidation(
            XcodeValidationCacheEntry(
                validation: XcodeProjectValidation(
                    isValid: true,
                    diagnosticMessage: nil
                ),
                observedAt: start,
                observedWallClockAt: Date()
            ),
            for: original
        )
        let changedKeys = [
            makeXcodeKey(targetGeneration: 2),
            makeXcodeKey(projectIdentity: "project-b"),
            makeXcodeKey(scheme: "Other"),
            makeXcodeKey(targetName: "OtherApp"),
            makeXcodeKey(bundleID: "com.example.other"),
        ]

        for key in changedKeys {
            #expect(cache.xcodeCandidate(for: key, at: start) == nil)
        }
    }

    @Test
    func appCacheKeyBindsGenerationCanonicalDeviceAndBundle() {
        let start = ContinuousClock().now
        let original = makeAppKey()
        var cache = RefreshSessionCaches()
        cache.storeInstalledApp(
            InstalledAppCacheEntry(
                result: .notInstalled,
                observedAt: start,
                observedWallClockAt: Date()
            ),
            for: original
        )
        let changedKeys = [
            makeAppKey(targetGeneration: 2),
            makeAppKey(deviceID: "iphone-2"),
            makeAppKey(bundleID: "com.example.other"),
        ]

        for key in changedKeys {
            #expect(cache.installedAppCandidate(for: key, at: start) == nil)
        }
    }

    @Test(arguments: [
        RefreshSessionInvalidation.manualDeepCheck,
        RefreshSessionInvalidation.systemWake,
    ])
    func manualAndWakeInvalidateBothCacheTypes(
        _ invalidation: RefreshSessionInvalidation
    ) {
        let start = ContinuousClock().now
        let xcodeKey = makeXcodeKey()
        let appKey = makeAppKey()
        var cache = populatedCache(
            xcodeKey: xcodeKey,
            appKey: appKey,
            observedAt: start
        )

        cache.invalidate(invalidation)

        #expect(cache.xcodeCandidate(for: xcodeKey, at: start) == nil)
        #expect(cache.installedAppCandidate(for: appKey, at: start) == nil)
    }

    @Test(arguments: DeviceScanCacheIssue.allCases)
    func scanIssueInvalidatesOnlyTheAffectedAppCandidate(
        _ issue: DeviceScanCacheIssue
    ) {
        let start = ContinuousClock().now
        let xcodeKey = makeXcodeKey()
        let affected = makeAppKey(deviceID: "iphone-1")
        let unaffected = makeAppKey(deviceID: "iphone-2")
        var cache = populatedCache(
            xcodeKey: xcodeKey,
            appKey: affected,
            observedAt: start
        )
        cache.storeInstalledApp(
            InstalledAppCacheEntry(
                result: .notInstalled,
                observedAt: start,
                observedWallClockAt: Date()
            ),
            for: unaffected
        )

        cache.invalidate(.scanIssue(issue, appKey: affected))

        #expect(cache.xcodeCandidate(for: xcodeKey, at: start) != nil)
        #expect(cache.installedAppCandidate(for: affected, at: start) == nil)
        #expect(cache.installedAppCandidate(for: unaffected, at: start) != nil)
    }

    @Test
    func deploymentInvalidatesOnlyItsExactTargetKeys() {
        let start = ContinuousClock().now
        let targetXcode = makeXcodeKey()
        let targetApp = makeAppKey()
        let otherXcode = makeXcodeKey(targetGeneration: 2)
        let otherApp = makeAppKey(targetGeneration: 2)
        var cache = populatedCache(
            xcodeKey: targetXcode,
            appKey: targetApp,
            observedAt: start
        )
        cache.storeXcodeValidation(
            validXcodeEntry(at: start),
            for: otherXcode
        )
        cache.storeInstalledApp(
            appEntry(at: start),
            for: otherApp
        )

        cache.invalidate(
            .deployment(
                .started,
                target: RefreshTargetCacheKeys(
                    xcode: targetXcode,
                    installedApp: targetApp
                )
            )
        )

        #expect(cache.xcodeCandidate(for: targetXcode, at: start) == nil)
        #expect(cache.installedAppCandidate(for: targetApp, at: start) == nil)
        #expect(cache.xcodeCandidate(for: otherXcode, at: start) != nil)
        #expect(cache.installedAppCandidate(for: otherApp, at: start) != nil)
    }

    @Test
    func targetChangeRetainsOnlyTheNewTargetGenerationAndIdentity() {
        let start = ContinuousClock().now
        let oldXcode = makeXcodeKey()
        let oldApp = makeAppKey()
        let newXcode = makeXcodeKey(targetGeneration: 2)
        let newApp = makeAppKey(targetGeneration: 2)
        var cache = populatedCache(
            xcodeKey: oldXcode,
            appKey: oldApp,
            observedAt: start
        )
        cache.storeXcodeValidation(validXcodeEntry(at: start), for: newXcode)
        cache.storeInstalledApp(appEntry(at: start), for: newApp)

        cache.invalidate(
            .targetChanged(
                retaining: RefreshTargetCacheKeys(
                    xcode: newXcode,
                    installedApp: newApp
                )
            )
        )

        #expect(cache.xcodeCandidate(for: oldXcode, at: start) == nil)
        #expect(cache.installedAppCandidate(for: oldApp, at: start) == nil)
        #expect(cache.xcodeCandidate(for: newXcode, at: start) != nil)
        #expect(cache.installedAppCandidate(for: newApp, at: start) != nil)
    }

    @Test
    func identityChangeOnlyInvalidatesItsExactAppCandidate() {
        let start = ContinuousClock().now
        let changed = makeAppKey(deviceID: "iphone-1")
        let other = makeAppKey(deviceID: "iphone-2")
        var cache = RefreshSessionCaches()
        cache.storeInstalledApp(appEntry(at: start), for: changed)
        cache.storeInstalledApp(appEntry(at: start), for: other)

        cache.invalidate(.installedAppIdentityChanged(changed))

        #expect(cache.installedAppCandidate(for: changed, at: start) == nil)
        #expect(cache.installedAppCandidate(for: other, at: start) != nil)
    }
}

private func makeXcodeKey(
    targetGeneration: Int = 1,
    projectIdentity: String = "project-a",
    scheme: String = "Example",
    targetName: String = "ExampleApp",
    bundleID: String = "com.example.app"
) -> XcodeValidationCacheKey {
    XcodeValidationCacheKey(
        targetGeneration: targetGeneration,
        normalizedProjectIdentity: projectIdentity,
        scheme: scheme,
        targetName: targetName,
        bundleID: bundleID
    )
}

private func makeAppKey(
    targetGeneration: Int = 1,
    deviceID: String = "iphone-1",
    bundleID: String = "com.example.app"
) -> InstalledAppCacheKey {
    InstalledAppCacheKey(
        targetGeneration: targetGeneration,
        deviceID: StableDeviceID(deviceID)!,
        bundleID: bundleID
    )
}

private func validXcodeEntry(
    at instant: ContinuousClock.Instant
) -> XcodeValidationCacheEntry {
    XcodeValidationCacheEntry(
        validation: XcodeProjectValidation(
            isValid: true,
            diagnosticMessage: nil
        ),
        observedAt: instant,
        observedWallClockAt: Date()
    )
}

private func appEntry(
    at instant: ContinuousClock.Instant
) -> InstalledAppCacheEntry {
    InstalledAppCacheEntry(
        result: .notInstalled,
        observedAt: instant,
        observedWallClockAt: Date()
    )
}

private func populatedCache(
    xcodeKey: XcodeValidationCacheKey,
    appKey: InstalledAppCacheKey,
    observedAt: ContinuousClock.Instant
) -> RefreshSessionCaches {
    var cache = RefreshSessionCaches()
    cache.storeXcodeValidation(
        validXcodeEntry(at: observedAt),
        for: xcodeKey
    )
    cache.storeInstalledApp(
        appEntry(at: observedAt),
        for: appKey
    )
    return cache
}
