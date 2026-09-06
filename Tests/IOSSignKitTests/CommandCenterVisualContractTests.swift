import AppKit
import Foundation
import SwiftUI
import Testing
@testable import IOSSignKit

struct CommandCenterVisualContractTests {
    @Test
    @MainActor
    func liveDeployOutputUsesAReadableBoundedConsole() {
        #expect(
            LiveDeployOutputPanel.displayedText(for: "  \n")
                == LiveDeployOutputPanel.waitingMessage
        )
        #expect(
            LiveDeployOutputPanel.displayedText(
                for: "first line\nsecond line\n"
            ) == "first line\nsecond line"
        )
        #expect(LiveDeployOutputPanel.Layout.minimumContentHeight == 190)
        #expect(LiveDeployOutputPanel.Layout.idealContentHeight == 250)
        #expect(LiveDeployOutputPanel.Layout.maximumContentHeight == 280)
    }

    @Test
    func sidebarRenewalIconUsesTheSpecifiedMotionCadence() {
        let motions: [(RenewalIconMotion, TimeInterval)] = [
            (.idle, 0),
            (.checking, 1.4),
            (.countdown(fraction: 1), 0.95),
            (.recovering, 2.2),
            (.deploying, 0.9),
            (.success, 2.8),
            (.attention, 1.8),
            (.paused, 0)
        ]

        for (motion, expectedDuration) in motions {
            let profile = RenewalIconMotionProfile.make(
                presentation: RenewalIconPresentation(
                    visualState: .normal,
                    motion: motion
                )
            )

            #expect(
                abs(profile.orbitDuration - expectedDuration) < 0.001
            )
        }
    }

    @Test
    func sidebarRenewalIconUsesDisplayRateMotion() {
        #expect(SidebarBrandIcon.Layout.preferredFrameRate == 60)
        #expect(SidebarBrandIcon.Layout.reducedMotionFrameRate == 4)
    }

    @Test
    func sidebarRenewalIconUsesDistinctMotionForActiveAndBlockedStates() {
        let deploying = RenewalIconMotionProfile.make(
            presentation: RenewalIconPresentation(
                visualState: .normal,
                motion: .deploying
            )
        )
        let blocked = RenewalIconMotionProfile.make(
            presentation: RenewalIconPresentation(
                visualState: .critical,
                motion: .paused
            )
        )

        #expect(deploying.orbitDuration < 1)
        #expect(blocked.orbitDuration == 0)
    }

    @Test
    func sidebarRenewalIconPreservesMotionPhaseWhenItsSpeedChanges() {
        let checking = RenewalIconMotionProfile.make(
            presentation: RenewalIconPresentation(
                visualState: .normal,
                motion: .checking
            )
        )
        let recovering = RenewalIconMotionProfile.make(
            presentation: RenewalIconPresentation(
                visualState: .warning,
                motion: .recovering
            )
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let transition = start.addingTimeInterval(1.3)
        var clock = RenewalIconMotionClock(anchorDate: start)
        let before = clock.phases(
            at: transition,
            profile: checking
        )

        clock.retime(at: transition, using: checking)
        let after = clock.phases(
            at: transition,
            profile: recovering
        )

        #expect(before == after)
    }

    @Test
    func sidebarRenewalIconFreezesWhereActiveMotionStopsForEveryColor() {
        let visualStates: [RenewalIconVisualState] = [
            .normal,
            .healthy,
            .warning,
            .critical,
            .offline
        ]
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let stop = start.addingTimeInterval(0.73)
        let later = stop.addingTimeInterval(19)

        for visualState in visualStates {
            let checking = RenewalIconMotionProfile.make(
                presentation: RenewalIconPresentation(
                    visualState: visualState,
                    motion: .checking
                )
            )
            let idle = RenewalIconMotionProfile.make(
                presentation: RenewalIconPresentation(
                    visualState: visualState,
                    motion: .idle
                )
            )
            var motionState = RenewalIconMotionState(
                profile: checking,
                date: start
            )
            let phaseAtStop = motionState.phases(at: stop)

            motionState.transition(to: idle, at: stop)
            let phaseAfterStop = motionState.phases(
                at: later
            )

            #expect(phaseAfterStop.orbit == phaseAtStop.orbit)
        }
    }

    @Test
    func sidebarRenewalIconResumesFromItsPausedPhaseWithoutCatchingUp() {
        let profile = RenewalIconMotionProfile.make(
            presentation: RenewalIconPresentation(
                visualState: .normal,
                motion: .idle
            )
        )
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let pause = start.addingTimeInterval(2.7)
        let resume = pause.addingTimeInterval(937)
        var clock = RenewalIconMotionClock(anchorDate: start)
        let phaseAtPause = clock.phases(
            at: pause,
            profile: profile
        )

        clock.retime(at: pause, using: profile)
        #expect(clock.anchorPhases == phaseAtPause)

        clock.resume(at: resume)
        let phaseAtResume = clock.phases(
            at: resume,
            profile: profile
        )

        #expect(clock.anchorDate == resume)
        #expect(phaseAtResume == phaseAtPause)
    }

    @Test
    func sidebarRenewalIconFreezesGeometryForReducedMotion() {
        let livePhases = RenewalIconMotionPhases(
            orbit: 0.62,
            pulse: 0.36
        )

        #expect(livePhases.rendered(reducesMotion: false) == livePhases)
        let reducedPhases = livePhases.rendered(reducesMotion: true)
        #expect(reducedPhases == .reducedMotion)
        #expect(reducedPhases.orbit == 0.125)
        #expect(reducedPhases.pulse == 0)
    }

    @Test
    func commandBarKeepsACompactBrandWithoutChangingWindowWidth() {
        #expect(MainPanelView.Layout.brandIconSize == 30)
        #expect(MainPanelView.Layout.commandBarHeight == 56)
        #expect(MainPanelView.Layout.minimumWindowWidth == 860)
    }

    @MainActor
    @Test
    func sidebarRenewalIconVisibilityStartsPausedAndTracksThePanel() {
        let visibility = MainPanelVisibilityState()

        #expect(!visibility.isVisible)

        visibility.setVisible(true)
        #expect(visibility.isVisible)

        visibility.setVisible(false)
        #expect(!visibility.isVisible)
    }

    @Test
    func sidebarNavigationSymbolsResolveOnTheCurrentHost() {
        for tab in MainPanelView.PanelTab.allCases {
            #expect(
                NSImage(
                    systemSymbolName: tab.systemImage,
                    accessibilityDescription: nil
                ) != nil
            )
        }
    }

}

struct InterfaceContractTests {
    @Test
    func renewalRingPathsStayInsideEverySpecifiedFrame() {
        let sizes: [(diameter: CGFloat, lineWidth: CGFloat)] = [
            (132, 10),
            (40, 3.5),
            (26, 2.5),
            (40, 4)
        ]

        for size in sizes {
            let geometry = RenewalRingGeometry(
                diameter: size.diameter,
                lineWidth: size.lineWidth
            )

            #expect(geometry.inset == size.lineWidth / 2)
            #expect(geometry.pathDiameter == size.diameter - size.lineWidth)
            #expect(geometry.pathRadius == (size.diameter - size.lineWidth) / 2)
            #expect(geometry.pathRadius + size.lineWidth / 2 == size.diameter / 2)
        }
    }

    @Test
    func renewalRingRendersCompleteAndUsesADarkerOfflineArc() async throws {
        // AppKit rendering must hop to the main actor. Keep this opt-in so the
        // pixel-level QA cannot starve unrelated timing-sensitive tests when
        // Swift Testing runs the full suite concurrently.
        guard ProcessInfo.processInfo.environment[
            "IOS_SIGN_KIT_RUN_UI_PIXEL_TESTS"
        ] == "1" else {
            return
        }

        let trackData = try await renderRingData(fraction: 0)
        let arcData = try await renderRingData(fraction: 1)
        let trackBitmap = try #require(NSBitmapImageRep(data: trackData))
        let arcBitmap = try #require(NSBitmapImageRep(data: arcData))

        for bitmap in [trackBitmap, arcBitmap] {
            let edgeCounts = outerEdgeInkCounts(in: bitmap)
            #expect(edgeCounts.left > 0)
            #expect(edgeCounts.right > 0)
            #expect(edgeCounts.top > 0)
            #expect(edgeCounts.bottom > 0)
            #expect(abs(edgeCounts.left - edgeCounts.right) <= 8)
            #expect(abs(edgeCounts.top - edgeCounts.bottom) <= 8)
        }

        #expect(averageLuminance(of: arcBitmap) + 0.01 < averageLuminance(of: trackBitmap))
    }

    @Test
    func historyGroupsUseTheSpecifiedTimeFormats() throws {
        let calendar = testCalendar
        let now = try makeDate(
            year: 2026,
            month: 8,
            day: 6,
            hour: 15,
            minute: 30,
            calendar: calendar
        )
        let today = try makeDate(
            year: 2026,
            month: 8,
            day: 6,
            hour: 9,
            minute: 12,
            calendar: calendar
        )
        let yesterday = try makeDate(
            year: 2026,
            month: 8,
            day: 5,
            hour: 21,
            minute: 47,
            calendar: calendar
        )
        let thisWeek = try makeDate(
            year: 2026,
            month: 8,
            day: 4,
            hour: 8,
            minute: 0,
            calendar: calendar
        )
        let earlier = try makeDate(
            year: 2026,
            month: 8,
            day: 1,
            hour: 12,
            minute: 5,
            calendar: calendar
        )

        #expect(HistoryDateGroup.resolve(date: today, now: now, calendar: calendar) == .today)
        #expect(HistoryDateGroup.resolve(date: yesterday, now: now, calendar: calendar) == .yesterday)
        #expect(HistoryDateGroup.resolve(date: thisWeek, now: now, calendar: calendar) == .thisWeek)
        #expect(HistoryDateGroup.resolve(date: earlier, now: now, calendar: calendar) == .earlier)
        #expect(HistoryTimelineTimePresentation.text(for: today, group: .today, calendar: calendar) == "09:12")
        #expect(HistoryTimelineTimePresentation.text(for: yesterday, group: .yesterday, calendar: calendar) == "21:47")
        #expect(HistoryTimelineTimePresentation.text(for: thisWeek, group: .thisWeek, calendar: calendar) == "周二")
        #expect(HistoryTimelineTimePresentation.text(for: earlier, group: .earlier, calendar: calendar) == "08-01")
    }

    @Test
    func historyResultRingsUseTheSpecifiedGlyphMatrix() {
        let success = HistoryResultRingPresentation.make(outcome: .success)
        #expect(success.tone == .success)
        #expect(success.glyph == .none)
        #expect(success.fraction == 1)

        let failure = HistoryResultRingPresentation.make(outcome: .failure)
        #expect(failure.tone == .critical)
        #expect(failure.glyph == .exclamation)
        #expect(failure.fraction == 1)

        for outcome in [
            RefreshHistoryOutcome.cancelled,
            .interrupted,
            .unknown
        ] {
            let presentation = HistoryResultRingPresentation.make(outcome: outcome)
            #expect(presentation.tone == .offline)
            #expect(presentation.glyph == .verticalLine)
            #expect(presentation.fraction == 1)
        }
    }

    @Test
    func saveControlKeepsUnsavedDraftActionableForValidationRouting() {
        let clean = SettingsSaveControlPresentation(
            hasUnsavedChanges: false
        )
        #expect(!clean.isEnabled)
        #expect(!clean.isProminent)
        #expect(!clean.showsConfirmationIcon)

        let dirty = SettingsSaveControlPresentation(
            hasUnsavedChanges: true
        )
        #expect(dirty.isEnabled)
        #expect(dirty.isProminent)
        #expect(dirty.showsConfirmationIcon)
    }

    @Test
    func settingsCategoryToolbarMatchesApprovedDirectionBGeometry() {
        #expect(SettingsCategoryControlLayout.width == 480)
        #expect(SettingsCategoryControlLayout.height == 52)
        #expect(SettingsCategoryControlLayout.headerSpacing == 16)
        #expect(SettingsCategoryControlLayout.segmentSpacing == 4)
        #expect(SettingsCategoryControlLayout.selectedCornerRadius == 8)
        #expect(SettingsCategoryControlLayout.iconSize == 18)
        #expect(SettingsCategoryControlLayout.itemHorizontalPadding == 4)
        #expect(SettingsCategoryControlLayout.itemVerticalSpacing == 3)
        #expect(SettingsCategoryControlLayout.selectionOpacity == 0.12)
        #expect(SettingsCategoryControlLayout.errorDotSize == 6)
        #expect(SettingsCategoryControlLayout.errorDotHorizontalOffset == 6)
        #expect(SettingsCategoryControlLayout.errorDotVerticalOffset == -2)
        #expect(SettingsCategoryControlLayout.focusOutlineWidth == 2)
        #expect(SettingsCategoryControlLayout.focusOutlineOffset == 2)

        for category in SettingsPanelCategory.allCases {
            #expect(
                NSImage(
                    systemSymbolName: category.systemImage,
                    accessibilityDescription: nil
                ) != nil
            )
        }
    }

    @MainActor
    @Test
    func heroUnitsAndEnvironmentSeparatorsKeepTheDesignContract() {
        #expect(
            HeroMetricUnitPresentation.text(
                phase: .waitingForDevice,
                unit: "天"
            ) == "天后到期"
        )
        #expect(
            HeroMetricUnitPresentation.text(
                phase: .monitoring,
                unit: "小时"
            ) == "小时后到期"
        )
        #expect(
            HeroMetricUnitPresentation.text(
                phase: .countdown,
                unit: nil
            ) == "后自动续期"
        )
        #expect(EnvironmentTrackRow.separatorWidth == 1)
        #expect(EnvironmentTrackRow.separatorHorizontalPadding == 16)
    }

#if DEBUG
    @MainActor
    @Test
    func unsavedDraftPropagatesIntoTheSharedSettingsState() throws {
        let viewModel = try VisualQAScenario.makeViewModel(now: visualReviewNow)
        defer { viewModel.stopPolling() }

        #expect(!viewModel.setupViewModel.hasUnsavedChanges)
        viewModel.setupViewModel.scheme += " Draft"
        #expect(viewModel.setupViewModel.hasUnsavedChanges)

        let presentation = SettingsSaveControlPresentation(
            hasUnsavedChanges: viewModel.setupViewModel.hasUnsavedChanges
        )
        #expect(presentation.isProminent)
        #expect(presentation.showsConfirmationIcon)
    }
#endif

#if DEBUG
    @MainActor
    @Test
    func writesRequestedVisualReviewScreenshotsWithoutLaunchingTheApp() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "IOS_SIGN_KIT_UI_ARTIFACT_DIR"
        ], !outputPath.isEmpty else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let statusViewModel = try VisualQAScenario.makeViewModel(now: visualReviewNow)
        defer { statusViewModel.stopPolling() }
        let statusVisibility = MainPanelVisibilityState(isVisible: true)
        try await writeScreenshot(
            MainPanelView(
                viewModel: statusViewModel,
                panelVisibility: statusVisibility
            ),
            to: outputDirectory.appendingPathComponent("status-offline.png")
        )

        let settingsViewModel = try VisualQAScenario.makeViewModel(now: visualReviewNow)
        defer { settingsViewModel.stopPolling() }
        let settingsVisibility = MainPanelVisibilityState(isVisible: true)
        try await writeScreenshot(
            MainPanelView(
                viewModel: settingsViewModel,
                panelVisibility: settingsVisibility,
                initialTab: .settings,
                settingsInitialScrollAnchor: .bottom
            ),
            to: outputDirectory.appendingPathComponent("settings-bottom.png")
        )

        let directionBViewModel = try VisualQAScenario.makeViewModel(
            now: visualReviewNow
        )
        defer { directionBViewModel.stopPolling() }
        let directionBVisibility = MainPanelVisibilityState(isVisible: true)
        try await writeScreenshot(
            MainPanelView(
                viewModel: directionBViewModel,
                panelVisibility: directionBVisibility,
                initialTab: .settings
            ),
            to: outputDirectory.appendingPathComponent(
                "settings-direction-b-dark.png"
            ),
            size: CGSize(width: 860, height: 680),
            colorScheme: .dark
        )
    }
#endif

    @MainActor
    private func renderRingData(fraction: Double) throws -> Data {
        let diameter: CGFloat = 132
        let renderer = ImageRenderer(
            content: RenewalRingView(
                diameter: diameter,
                lineWidth: 10,
                tone: .offline,
                fraction: fraction,
                isAnimationActive: false
            )
            .background(.white)
        )
        renderer.proposedSize = ProposedViewSize(
            width: diameter,
            height: diameter
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        return try #require(image.tiffRepresentation)
    }

    private func outerEdgeInkCounts(
        in bitmap: NSBitmapImageRep
    ) -> (left: Int, right: Int, top: Int, bottom: Int) {
        let band = 3
        var result = (left: 0, right: 0, top: 0, bottom: 0)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y),
                      luminance(of: color) < 0.97 else {
                    continue
                }
                if x < band { result.left += 1 }
                if x >= bitmap.pixelsWide - band { result.right += 1 }
                if y < band { result.bottom += 1 }
                if y >= bitmap.pixelsHigh - band { result.top += 1 }
            }
        }
        return result
    }

    private func averageLuminance(of bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                total += luminance(of: color)
                count += 1
            }
        }
        return count == 0 ? 1 : total / Double(count)
    }

    private func luminance(of color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 1 }
        return (0.2126 * rgb.redComponent)
            + (0.7152 * rgb.greenComponent)
            + (0.0722 * rgb.blueComponent)
    }

#if DEBUG
    @MainActor
    private func writeScreenshot<Content: View>(
        _ content: Content,
        to destination: URL,
        size: CGSize = CGSize(width: 912, height: 768),
        colorScheme: ColorScheme = .light
    ) async throws {
        let hostingView = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, colorScheme)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)
        window.contentView = nil
        window.close()
    }
#endif
}

private var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    return calendar
}

private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    calendar: Calendar
) throws -> Date {
    let components = DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )
    return try #require(calendar.date(from: components))
}

#if DEBUG
private let visualReviewNow = Date(timeIntervalSince1970: 1_786_000_000)
#endif
