import Foundation

struct XcodeValidationCacheKey: Hashable, Sendable {
    let targetGeneration: Int
    let normalizedProjectIdentity: String
    let scheme: String
    let targetName: String
    let bundleID: String
}

struct XcodeValidationCacheEntry: Equatable, Sendable {
    let validation: XcodeProjectValidation
    let observedAt: ContinuousClock.Instant
    let observedWallClockAt: Date
}

struct InstalledAppCacheKey: Hashable, Sendable {
    let targetGeneration: Int
    let deviceID: StableDeviceID
    let bundleID: String
}

enum InstalledAppCacheResult: Equatable, Sendable {
    case installed(InstalledAppInfo)
    case notInstalled
}

struct InstalledAppCacheEntry: Equatable, Sendable {
    let result: InstalledAppCacheResult
    let observedAt: ContinuousClock.Instant
    let observedWallClockAt: Date
}

struct RefreshTargetCacheKeys: Equatable, Sendable {
    let xcode: XcodeValidationCacheKey?
    let installedApp: InstalledAppCacheKey?

    init(
        xcode: XcodeValidationCacheKey?,
        installedApp: InstalledAppCacheKey?
    ) {
        self.xcode = xcode
        self.installedApp = installedApp
    }
}

enum DeviceScanCacheIssue: CaseIterable, Equatable, Sendable {
    case partial
    case failure
    case conflict
}

enum DeploymentCacheEvent: Equatable, Sendable {
    case started
    case settled
    case recovery
}

enum RefreshSessionInvalidation: Equatable, Sendable {
    case targetChanged(retaining: RefreshTargetCacheKeys)
    case manualDeepCheck
    case systemWake
    case scanIssue(DeviceScanCacheIssue, appKey: InstalledAppCacheKey?)
    case deployment(
        DeploymentCacheEvent,
        target: RefreshTargetCacheKeys?
    )
    case installedAppIdentityChanged(InstalledAppCacheKey)
}

struct RefreshSessionCaches: Sendable {
    static let defaultXcodeValidationTTL =
        RefreshTimingPolicy.production.xcodeValidationCacheTTL
    static let defaultInstalledAppTTL =
        RefreshTimingPolicy.production.installedAppCacheTTL

    let xcodeValidationTTL: Duration
    let installedAppTTL: Duration

    private var xcodeEntries: [XcodeValidationCacheKey: XcodeValidationCacheEntry] = [:]
    private var installedAppEntries: [InstalledAppCacheKey: InstalledAppCacheEntry] = [:]

    init(
        xcodeValidationTTL: Duration = Self.defaultXcodeValidationTTL,
        installedAppTTL: Duration = Self.defaultInstalledAppTTL
    ) {
        self.xcodeValidationTTL = max(xcodeValidationTTL, .zero)
        self.installedAppTTL = max(installedAppTTL, .zero)
    }

    mutating func storeXcodeValidation(
        _ entry: XcodeValidationCacheEntry,
        for key: XcodeValidationCacheKey
    ) {
        guard entry.validation.isValid else {
            xcodeEntries.removeValue(forKey: key)
            return
        }
        xcodeEntries[key] = entry
    }

    mutating func storeInstalledApp(
        _ entry: InstalledAppCacheEntry,
        for key: InstalledAppCacheKey
    ) {
        installedAppEntries[key] = entry
    }

    func xcodeCandidate(
        for key: XcodeValidationCacheKey,
        at now: ContinuousClock.Instant
    ) -> XcodeValidationCacheEntry? {
        guard let entry = xcodeEntries[key],
              Self.isFresh(
                observedAt: entry.observedAt,
                now: now,
                ttl: xcodeValidationTTL
              ) else {
            return nil
        }
        return entry
    }

    func installedAppCandidate(
        for key: InstalledAppCacheKey,
        at now: ContinuousClock.Instant
    ) -> InstalledAppCacheEntry? {
        guard let entry = installedAppEntries[key],
              Self.isFresh(
                observedAt: entry.observedAt,
                now: now,
                ttl: installedAppTTL
              ) else {
            return nil
        }
        return entry
    }

    mutating func invalidate(_ event: RefreshSessionInvalidation) {
        switch event {
        case .manualDeepCheck, .systemWake:
            removeAll()
        case .targetChanged(let retainedKeys):
            retainOnly(retainedKeys)
        case .scanIssue(_, let appKey):
            if let appKey {
                installedAppEntries.removeValue(forKey: appKey)
            } else {
                installedAppEntries.removeAll()
            }
        case .deployment(_, let target):
            guard let target else {
                removeAll()
                return
            }
            if let xcodeKey = target.xcode {
                xcodeEntries.removeValue(forKey: xcodeKey)
            }
            if let appKey = target.installedApp {
                installedAppEntries.removeValue(forKey: appKey)
            }
        case .installedAppIdentityChanged(let appKey):
            installedAppEntries.removeValue(forKey: appKey)
        }
    }

    mutating func removeAll() {
        xcodeEntries.removeAll()
        installedAppEntries.removeAll()
    }

    private mutating func retainOnly(
        _ retainedKeys: RefreshTargetCacheKeys
    ) {
        if let retainedXcodeKey = retainedKeys.xcode,
           let entry = xcodeEntries[retainedXcodeKey] {
            xcodeEntries = [retainedXcodeKey: entry]
        } else {
            xcodeEntries.removeAll()
        }

        if let retainedAppKey = retainedKeys.installedApp,
           let entry = installedAppEntries[retainedAppKey] {
            installedAppEntries = [retainedAppKey: entry]
        } else {
            installedAppEntries.removeAll()
        }
    }

    private static func isFresh(
        observedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        ttl: Duration
    ) -> Bool {
        let age = observedAt.duration(to: now)
        return age >= .zero && age < ttl
    }
}
