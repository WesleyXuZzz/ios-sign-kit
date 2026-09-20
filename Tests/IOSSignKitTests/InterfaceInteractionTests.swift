import AppKit
import Testing
import SwiftUI
@testable import IOSSignKit

struct InterfaceInteractionTests {
    @Test
    @MainActor
    func semanticTextRemainsReadableOnTintedStatusSurfaces() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            for tone in [StatusTone.good, .warning, .critical, .info, .neutral] {
                let foreground = rgb(tone.textColor, environment: environment)
                let tint = rgb(tone.color, environment: environment)
                let canvas = rgb(ColorTokens.BG.surfaceEmphasis, environment: environment)
                let background = zip(tint, canvas).map { $0 * 0.14 + $1 * 0.86 }
                let first = luminance(foreground)
                let second = luminance(background)
                let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
                #expect(ratio >= 4.5, "Scheme: \(scheme), tone: \(tone), contrast: \(ratio)")
            }
        }
    }

    @MainActor
    private func rgb(_ color: Color, environment: EnvironmentValues) -> [Double] {
        let resolved = color.resolve(in: environment)
        return [Double(resolved.red), Double(resolved.green), Double(resolved.blue)]
    }

    private func luminance(_ channels: [Double]) -> Double {
        zip(channels, [0.2126, 0.7152, 0.0722]).reduce(0) { result, pair in
            let channel = pair.0 <= 0.04045 ? pair.0 / 12.92 : pow((pair.0 + 0.055) / 1.055, 2.4)
            return result + channel * pair.1
        }
    }

    @Test
    func logGrowthAndResizingDoNotPauseFollowing() {
        var state = LogFollowState()
        state.observe(frame: CGRect(x: 0, y: -600, width: 300, height: 800), viewportHeight: 200)
        state.observe(frame: CGRect(x: 0, y: -600, width: 300, height: 900), viewportHeight: 200)
        #expect(state.isFollowing)
        state.observe(frame: CGRect(x: 0, y: -700, width: 300, height: 900), viewportHeight: 200)
        state.observe(frame: CGRect(x: 0, y: -650, width: 300, height: 900), viewportHeight: 250)
        #expect(state.isFollowing)
    }

    @Test
    func readerCanPauseAndResumeAtTheTail() {
        var state = LogFollowState()
        state.observe(frame: CGRect(x: 0, y: -600, width: 300, height: 800), viewportHeight: 200)
        state.observe(frame: CGRect(x: 0, y: -500, width: 300, height: 800), viewportHeight: 200)
        #expect(!state.isFollowing)
        state.observe(frame: CGRect(x: 0, y: -500, width: 300, height: 900), viewportHeight: 200)
        #expect(!state.isFollowing)
        state.observe(frame: CGRect(x: 0, y: -700, width: 300, height: 900), viewportHeight: 200)
        #expect(state.isFollowing)
    }

    @Test
    func explicitPauseSurvivesReachingTheTail() {
        var state = LogFollowState()
        state.observe(frame: CGRect(x: 0, y: -500, width: 300, height: 800), viewportHeight: 200)
        state.setFollowing(false)
        state.observe(frame: CGRect(x: 0, y: -600, width: 300, height: 800), viewportHeight: 200)
        #expect(!state.isFollowing)
        state.setFollowing(true)
        #expect(state.isFollowing)
    }

    @Test
    @MainActor
    func draftCategoriesReflectIndependentChangesAndReverts() {
        let model = SetupWizardViewModel(
            deviceDetectionRolloutMode: .readOnly,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(appSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        )
        #expect(!model.hasUnsavedTargetChanges)
        #expect(!model.hasUnsavedRenewalChanges)
        #expect(!model.hasUnsavedLANControlChanges)
        model.scheme = "Example"
        model.checkIntervalMinutes = 12
        model.lanControlPassword = "example-password"
        #expect(model.hasUnsavedTargetChanges)
        #expect(model.hasUnsavedRenewalChanges)
        #expect(model.hasUnsavedLANControlChanges)
        model.scheme = ""
        model.checkIntervalMinutes = AppConfig.default.checkIntervalMinutes
        model.lanControlPassword = ""
        #expect(!model.hasUnsavedChanges)
    }
}
