import Foundation
import SwiftUI

struct RenewalIconMotionProfile: Equatable {
    let orbitDuration: TimeInterval
    let pulseDuration: TimeInterval
    let boltPulseScale: CGFloat

    static func make(
        presentation: RenewalIconPresentation
    ) -> RenewalIconMotionProfile {
        switch presentation.motion {
        case .idle:
            profile(
                orbitDuration: 0,
                pulseDuration: 3.2,
                boltPulseScale: 0.010
            )
        case .checking:
            profile(
                orbitDuration: 1.4,
                pulseDuration: 1.5,
                boltPulseScale: 0.012
            )
        case .countdown:
            profile(
                orbitDuration: 0.95,
                pulseDuration: 1.0,
                boltPulseScale: 0.015
            )
        case .recovering:
            profile(
                orbitDuration: 2.2,
                pulseDuration: 1.8,
                boltPulseScale: 0.012
            )
        case .deploying:
            profile(
                orbitDuration: 0.9,
                pulseDuration: 0.95,
                boltPulseScale: 0.015
            )
        case .success:
            profile(
                orbitDuration: 2.8,
                pulseDuration: 2.1,
                boltPulseScale: 0.014
            )
        case .attention:
            profile(
                orbitDuration: 1.8,
                pulseDuration: 1.25,
                boltPulseScale: 0.014
            )
        case .paused:
            profile(
                orbitDuration: 0,
                pulseDuration: 0,
                boltPulseScale: 0
            )
        }
    }

    private static func profile(
        orbitDuration: TimeInterval,
        pulseDuration: TimeInterval,
        boltPulseScale: CGFloat
    ) -> RenewalIconMotionProfile {
        RenewalIconMotionProfile(
            orbitDuration: orbitDuration,
            pulseDuration: pulseDuration,
            boltPulseScale: boltPulseScale
        )
    }
}

struct RenewalIconMotionPhases: Equatable {
    let orbit: Double
    let pulse: Double

    static let zero = RenewalIconMotionPhases(
        orbit: 0,
        pulse: 0
    )

    static let reducedMotion = RenewalIconMotionPhases(
        orbit: 0.125,
        pulse: 0
    )

    func rendered(reducesMotion: Bool) -> RenewalIconMotionPhases {
        reducesMotion ? .reducedMotion : self
    }
}

struct RenewalIconMotionClock: Equatable {
    private(set) var anchorDate: Date
    private(set) var anchorPhases: RenewalIconMotionPhases

    init(
        anchorDate: Date = Date(),
        anchorPhases: RenewalIconMotionPhases = .zero
    ) {
        self.anchorDate = anchorDate
        self.anchorPhases = anchorPhases
    }

    func phases(
        at date: Date,
        profile: RenewalIconMotionProfile
    ) -> RenewalIconMotionPhases {
        let elapsed = date.timeIntervalSince(anchorDate)
        return RenewalIconMotionPhases(
            orbit: advancedPhase(
                anchor: anchorPhases.orbit,
                elapsed: elapsed,
                duration: profile.orbitDuration
            ),
            pulse: advancedPhase(
                anchor: anchorPhases.pulse,
                elapsed: elapsed,
                duration: profile.pulseDuration
            )
        )
    }

    mutating func retime(
        at date: Date,
        using profile: RenewalIconMotionProfile
    ) {
        anchorPhases = phases(at: date, profile: profile)
        anchorDate = date
    }

    mutating func resume(at date: Date) {
        anchorDate = date
    }

    private func advancedPhase(
        anchor: Double,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else {
            return normalized(anchor)
        }
        return normalized(anchor + (elapsed / duration))
    }

    private func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }
}

struct RenewalIconMotionState: Equatable {
    private(set) var profile: RenewalIconMotionProfile
    private(set) var clock: RenewalIconMotionClock

    init(
        profile: RenewalIconMotionProfile,
        date: Date = Date()
    ) {
        self.profile = profile
        self.clock = RenewalIconMotionClock(anchorDate: date)
    }

    func phases(at date: Date) -> RenewalIconMotionPhases {
        clock.phases(at: date, profile: profile)
    }

    mutating func transition(
        to newProfile: RenewalIconMotionProfile,
        at date: Date
    ) {
        guard newProfile != profile else {
            return
        }
        clock.retime(at: date, using: profile)
        profile = newProfile
    }

    mutating func pause(at date: Date) {
        clock.retime(at: date, using: profile)
    }

    mutating func resume(at date: Date) {
        clock.resume(at: date)
    }
}
