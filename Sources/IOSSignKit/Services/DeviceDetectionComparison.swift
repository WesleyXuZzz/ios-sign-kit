import Foundation
import OSLog

enum DeviceDetectionClassification: String, Equatable, Sendable {
    case matched
    case confirmedAbsent
    case unavailable
    case inconclusive
    case conflict
}

struct DeviceDetectionProjection: Equatable, Sendable {
    let classification: DeviceDetectionClassification
    let quality: ObservationQuality
}

struct DeviceDetectionProjectionPair: Equatable, Sendable {
    let compatibility: DeviceDetectionProjection
    let canonical: DeviceDetectionProjection
    let sourceCommandCount: UInt8

    init(
        compatibility: DeviceDetectionProjection,
        canonical: DeviceDetectionProjection,
        sourceCommandCount: Int
    ) {
        self.compatibility = compatibility
        self.canonical = canonical
        self.sourceCommandCount = UInt8(
            clamping: max(sourceCommandCount, 0)
        )
    }

    func projection(
        for path: DeviceDetectionEngine
    ) -> DeviceDetectionProjection {
        switch path {
        case .compatibility:
            return compatibility
        case .canonical:
            return canonical
        }
    }
}

struct DeviceDetectionComparisonSample: Equatable, Sendable {
    let rolloutMode: DeviceDetectionRolloutMode
    let primaryEngine: DeviceDetectionEngine
    let comparisonEngine: DeviceDetectionEngine
    let primaryDevice: DeviceDetectionProjection
    let comparisonDevice: DeviceDetectionProjection
    let primaryWork: RefreshWork
    let comparisonWork: RefreshWork
    let sourceCommandCount: UInt8

    var hasDeviceDifference: Bool {
        primaryDevice != comparisonDevice
    }

    var hasWorkDifference: Bool {
        primaryWork != comparisonWork
    }
}

struct DeviceDetectionComparisonSink: Sendable {
    typealias RecordHandler =
        @Sendable (DeviceDetectionComparisonSample) -> Void

    private let recordHandler: RecordHandler

    init(
        record: @escaping RecordHandler =
            DeviceDetectionComparisonSink.recordToUnifiedLog
    ) {
        self.recordHandler = record
    }

    func record(_ sample: DeviceDetectionComparisonSample) {
        recordHandler(sample)
    }

    private static func recordToUnifiedLog(
        _ sample: DeviceDetectionComparisonSample
    ) {
        let policy = String(describing: sample.rolloutMode)
        let primary = String(describing: sample.primaryEngine)
        let comparison = String(describing: sample.comparisonEngine)
        let primaryDevice = sample.primaryDevice.classification.rawValue
        let comparisonDevice =
            sample.comparisonDevice.classification.rawValue
        let primaryWork = String(describing: sample.primaryWork)
        let comparisonWork = String(describing: sample.comparisonWork)
        comparisonLogger.info(
            """
            policy=\(policy, privacy: .public) \
            primary=\(primary, privacy: .public) \
            comparison=\(comparison, privacy: .public) \
            primary_device=\(primaryDevice, privacy: .public) \
            comparison_device=\(comparisonDevice, privacy: .public) \
            primary_work=\(primaryWork, privacy: .public) \
            comparison_work=\(comparisonWork, privacy: .public) \
            source_commands=\(sample.sourceCommandCount) \
            device_difference=\(sample.hasDeviceDifference) \
            work_difference=\(sample.hasWorkDifference)
            """
        )
    }
}

struct ComparedTargetDeviceObservation: Sendable {
    let compatibility: TargetDeviceObservation
    let canonical: TargetDeviceObservation
    let projections: DeviceDetectionProjectionPair

    var primary: TargetDeviceObservation {
        canonical
    }

    func observation(
        for path: DeviceDetectionEngine
    ) -> TargetDeviceObservation {
        switch path {
        case .compatibility:
            return compatibility
        case .canonical:
            return canonical
        }
    }
}

struct ComparedDeviceInventory: Sendable {
    let compatibility: DeviceInventory
    let canonical: DeviceInventory
    let projections: DeviceDetectionProjectionPair

    var primary: DeviceInventory {
        canonical
    }

    func inventory(
        for path: DeviceDetectionEngine
    ) -> DeviceInventory {
        switch path {
        case .compatibility:
            return compatibility
        case .canonical:
            return canonical
        }
    }
}

struct ComparedCompatibilityDeviceScan: Sendable {
    let primary: DeviceScanResult
    let projections: DeviceDetectionProjectionPair
}

private let comparisonLogger = Logger(
    subsystem: "iOSSignKit",
    category: "DeviceDetectionComparison"
)
