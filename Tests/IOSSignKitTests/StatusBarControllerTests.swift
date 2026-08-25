import AppKit
import Testing
@testable import IOSSignKit

struct StatusBarControllerTests {
    @Test
    func firstPresentationUsesImmediateUpdates() {
        var state = StatusBarTransitionState()
        let first = snapshot(
            title: "检查中",
            icon: .progress,
            group: .semantic
        )

        let decision = state.transition(to: first, reduceMotion: false)

        #expect(decision == StatusBarTransitionDecision(
            title: .immediate,
            icon: .immediate
        ))
        #expect(state.snapshot == first)
        #expect(state.generation == 1)
    }

    @Test
    func identicalPresentationDoesNotAnimate() {
        var state = StatusBarTransitionState()
        let expiry = snapshot(
            title: "6d12h",
            icon: .online,
            group: .expiry
        )
        _ = state.transition(to: expiry, reduceMotion: false)

        let decision = state.transition(to: expiry, reduceMotion: false)

        #expect(decision == StatusBarTransitionDecision(
            title: .immediate,
            icon: .immediate
        ))
        #expect(!StatusBarTransitionPolicy.shouldApply(
            previous: expiry,
            next: expiry,
            forceImmediate: false
        ))
        #expect(StatusBarTransitionPolicy.shouldApply(
            previous: expiry,
            next: expiry,
            forceImmediate: true
        ))
    }

    @Test
    func reduceMotionMakesSemanticAndIconChangesImmediate() {
        let previous = snapshot(
            title: "检查中",
            icon: .progress,
            group: .semantic
        )
        let next = snapshot(
            title: "离线",
            icon: .offline,
            group: .semantic
        )

        let decision = StatusBarTransitionPolicy.decision(
            previous: previous,
            next: next,
            reduceMotion: true
        )

        #expect(decision == StatusBarTransitionDecision(
            title: .immediate,
            icon: .immediate
        ))
    }

    @Test
    func expiryCountdownCrossfadesWithoutMovement() {
        let previous = snapshot(
            title: "6d12h",
            icon: .online,
            group: .expiry
        )
        let next = snapshot(
            title: "10h40m",
            icon: .online,
            group: .expiry
        )

        let decision = StatusBarTransitionPolicy.decision(
            previous: previous,
            next: next,
            reduceMotion: false
        )

        #expect(decision == StatusBarTransitionDecision(
            title: .crossfade(duration: 0.12),
            icon: .immediate
        ))
    }

    @Test
    func stableExpiryTitleDoesNotAnimateWhenOnlyActivityIconChanges() {
        let previous = snapshot(
            title: "6d12h",
            icon: .online,
            group: .expiry
        )
        let next = snapshot(
            title: "6d12h",
            icon: .progress,
            group: .expiry
        )

        let decision = StatusBarTransitionPolicy.decision(
            previous: previous,
            next: next,
            reduceMotion: false
        )

        #expect(decision == StatusBarTransitionDecision(
            title: .immediate,
            icon: .crossfade(duration: 0.14)
        ))
    }

    @Test
    func semanticChangeUsesPushAndChangedIconCrossfades() {
        let previous = snapshot(
            title: "检查中",
            icon: .progress,
            group: .semantic
        )
        let next = snapshot(
            title: "离线",
            icon: .offline,
            group: .semantic
        )

        let decision = StatusBarTransitionPolicy.decision(
            previous: previous,
            next: next,
            reduceMotion: false
        )

        #expect(decision == StatusBarTransitionDecision(
            title: .semanticPush(duration: 0.18, verticalOffset: 3),
            icon: .crossfade(duration: 0.14)
        ))
    }

    @Test
    func changingFromExpiryToSemanticStatusUsesSemanticTransition() {
        let previous = snapshot(
            title: "1m",
            icon: .online,
            group: .expiry
        )
        let next = snapshot(
            title: "离线",
            icon: .offline,
            group: .semantic
        )

        let decision = StatusBarTransitionPolicy.decision(
            previous: previous,
            next: next,
            reduceMotion: false
        )

        #expect(decision.title == .semanticPush(
            duration: StatusBarTransitionPolicy.semanticTitleDuration,
            verticalOffset: StatusBarTransitionPolicy.semanticTitleOffset
        ))
        #expect(decision.icon == .crossfade(
            duration: StatusBarTransitionPolicy.iconDuration
        ))
    }

    @Test
    func rapidUpdatesKeepOnlyLatestTargetInPolicyState() {
        var state = StatusBarTransitionState()
        let checking = snapshot(
            title: "检查中",
            icon: .progress,
            group: .semantic
        )
        let preparing = snapshot(
            title: "续签中",
            icon: .progress,
            group: .semantic
        )
        let deploying = snapshot(
            title: "待解锁",
            icon: .attention,
            group: .semantic
        )

        _ = state.transition(to: checking, reduceMotion: false)
        _ = state.transition(to: preparing, reduceMotion: false)
        let latestDecision = state.transition(to: deploying, reduceMotion: false)

        #expect(state.snapshot == deploying)
        #expect(state.generation == 3)
        #expect(latestDecision.title == .semanticPush(
            duration: StatusBarTransitionPolicy.semanticTitleDuration,
            verticalOffset: StatusBarTransitionPolicy.semanticTitleOffset
        ))
        #expect(latestDecision.icon == .crossfade(
            duration: StatusBarTransitionPolicy.iconDuration
        ))
    }

    @Test
    func widthMetricsMatchTheTwoStatusItemContracts() {
        #expect(StatusBarWidthMetrics.iconWidth == 16)
        #expect(StatusBarWidthMetrics.iconTitleSpacing == 8)
        #expect(StatusBarWidthMetrics.horizontalInset == 1)
        #expect(StatusBarWidthMetrics.titleWidth(for: .compact) == 24)
        #expect(StatusBarWidthMetrics.statusItemLength(for: .compact) == 50)
        #expect(StatusBarWidthMetrics.titleWidth(for: .standard) == 41)
        #expect(StatusBarWidthMetrics.statusItemLength(for: .standard) == 67)
    }

    @Test
    func widthOrFontStyleChangeInvalidatesAnOtherwiseIdenticalSnapshot() {
        let status = snapshot(
            title: "4d3h",
            icon: .online,
            group: .expiry
        )
        let time = snapshot(
            title: "4d3h",
            icon: .online,
            group: .expiry,
            widthTier: .compact,
            fontStyle: .time
        )

        #expect(StatusBarTransitionPolicy.shouldApply(
            previous: status,
            next: time,
            forceImmediate: false
        ))
    }

    @Test
    func firstWidthTierAndCompactToStandardApplyBeforeTitleTransition() {
        var unconfiguredState = StatusBarWidthTransitionState()
        let firstTransition = unconfiguredState.transition(
            to: .compact,
            titleTransition: .immediate,
            reduceMotion: false
        )
        #expect(firstTransition == .applyImmediately(.compact))
        #expect(unconfiguredState.appliedTier == .compact)

        var compactState = StatusBarWidthTransitionState(appliedTier: .compact)
        let expansion = compactState.transition(
            to: .standard,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )
        #expect(expansion == .applyImmediately(.standard))
        #expect(compactState.appliedTier == .standard)
    }

    @Test
    func sameWidthTierDoesNotRequestAWidthMutation() {
        var state = StatusBarWidthTransitionState(appliedTier: .standard)

        let transition = state.transition(
            to: .standard,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )

        #expect(transition == .unchanged)
        #expect(state.appliedTier == .standard)
    }

    @Test
    func standardToCompactWaitsForTheTitleTransitionBeforeShrinking() {
        var state = StatusBarWidthTransitionState(appliedTier: .standard)

        let transition = state.transition(
            to: .compact,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )

        #expect(transition == .shrinkAfterTransition(
            tier: .compact,
            delay: 0.18,
            generation: 1
        ))
        #expect(state.appliedTier == .standard)
        let didComplete = state.completeDelayedShrink(
            to: .compact,
            generation: 1
        )
        #expect(didComplete)
        #expect(state.appliedTier == .compact)
    }

    @Test
    func expiryWidthShrinkWaitsForTheCrossfadeToFinish() {
        var state = StatusBarWidthTransitionState(appliedTier: .standard)

        let transition = state.transition(
            to: .compact,
            titleTransition: .crossfade(duration: 0.12),
            reduceMotion: false
        )

        #expect(transition == .shrinkAfterTransition(
            tier: .compact,
            delay: 0.12,
            generation: 1
        ))
        #expect(state.appliedTier == .standard)
    }

    @Test
    func reduceMotionShrinksImmediately() {
        var state = StatusBarWidthTransitionState(appliedTier: .standard)

        let transition = state.transition(
            to: .compact,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: true
        )

        #expect(transition == .applyImmediately(.compact))
        #expect(state.appliedTier == .compact)
    }

    @Test
    func newerWidthGenerationInvalidatesDelayedShrink() {
        var state = StatusBarWidthTransitionState(appliedTier: .standard)
        let staleShrink = state.transition(
            to: .compact,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )
        #expect(staleShrink == .shrinkAfterTransition(
            tier: .compact,
            delay: 0.18,
            generation: 1
        ))

        let returnToStandard = state.transition(
            to: .standard,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )
        #expect(returnToStandard == .unchanged)
        let staleCompletion = state.completeDelayedShrink(
            to: .compact,
            generation: 1
        )
        #expect(!staleCompletion)
        #expect(state.appliedTier == .standard)
        #expect(state.targetTier == .standard)
    }

    @Test
    func consecutiveCompactTargetsRescheduleShrinkFromLatestGeneration() {
        var state = StatusBarWidthTransitionState(appliedTier: .standard)
        _ = state.transition(
            to: .compact,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )
        let latestShrink = state.transition(
            to: .compact,
            titleTransition: .semanticPush(duration: 0.18, verticalOffset: 3),
            reduceMotion: false
        )

        #expect(latestShrink == .shrinkAfterTransition(
            tier: .compact,
            delay: 0.18,
            generation: 2
        ))
        let staleCompletion = state.completeDelayedShrink(
            to: .compact,
            generation: 1
        )
        let latestCompletion = state.completeDelayedShrink(
            to: .compact,
            generation: 2
        )
        #expect(!staleCompletion)
        #expect(latestCompletion)
        #expect(state.appliedTier == .compact)
    }

    @Test
    func accessibilityLabelChangeInvalidatesSameVisualSnapshot() {
        var state = StatusBarTransitionState()
        let environmentError = snapshot(
            title: "异常",
            icon: .error,
            group: .semantic,
            widthTier: .compact,
            accessibilityLabel: "运行环境异常"
        )
        let scanError = snapshot(
            title: "异常",
            icon: .error,
            group: .semantic,
            widthTier: .compact,
            accessibilityLabel: "设备检查异常"
        )
        _ = state.transition(to: environmentError, reduceMotion: false)

        let decision = state.transition(to: scanError, reduceMotion: false)

        #expect(StatusBarTransitionPolicy.shouldApply(
            previous: environmentError,
            next: scanError,
            forceImmediate: false
        ))
        #expect(decision == StatusBarTransitionDecision(
            title: .immediate,
            icon: .immediate
        ))
        #expect(state.snapshot == scanError)
        #expect(state.generation == 2)
    }

    @Test
    func statusMenuLayoutKeepsTheApprovedEightItemContract() {
        let items = StatusMenuLayout.items(
            refreshTitle: "立即续签"
        )

        #expect(items.count == 8)
        #expect(items == [
            .header,
            .separator,
            .command(
                id: .openPanel,
                title: "打开面板",
                systemImageName: "rectangle.on.rectangle.angled",
                keyEquivalent: ""
            ),
            .command(
                id: .reload,
                title: "重新检查",
                systemImageName: "arrow.clockwise",
                keyEquivalent: ""
            ),
            .command(
                id: .refresh,
                title: "立即续签",
                systemImageName: "arrow.triangle.2.circlepath",
                keyEquivalent: ""
            ),
            .command(
                id: .openProject,
                title: "打开项目",
                systemImageName: "folder",
                keyEquivalent: ""
            ),
            .separator,
            .command(
                id: .quit,
                title: "退出 iOSSignKit",
                systemImageName: "power",
                keyEquivalent: "q"
            )
        ])
    }

    @Test
    @MainActor
    func titleFontProviderUsesStatusAndTimeTypography() {
        let statusFont = StatusBarTitleFontProvider.font(for: .status)
        let timeFont = StatusBarTitleFontProvider.font(for: .time)

        #expect(statusFont.pointSize == 12)
        #expect(timeFont.pointSize == 11)
        #expect(timeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test
    @MainActor
    func representativeTitlesFitTheirAssignedWidthTiers() {
        let statusFont = StatusBarTitleFontProvider.font(for: .status)
        let timeFont = StatusBarTitleFontProvider.font(for: .time)
        let compactStatusTitles = ["异常", "离线", "到期", "5s"]
        let compactTimeTitles = ["1m", "8m", "59m"]
        let standardStatusTitles = [
            "检查中", "续签中", "已续签", "已取消",
            "待解锁", "确认中", "配对中", "需确认", "需配对",
            "需升级", "需连线", "待检测"
        ]
        let standardTimeTitles = ["6d12h", "10h40m", "23h59m"]

        for title in compactStatusTitles {
            #expect(measuredWidth(of: title, font: statusFont) <= 24)
        }
        for title in compactTimeTitles {
            #expect(measuredWidth(of: title, font: timeFont) <= 24)
        }
        for title in standardStatusTitles {
            #expect(measuredWidth(of: title, font: statusFont) <= 41)
        }
        for title in standardTimeTitles {
            #expect(measuredWidth(of: title, font: timeFont) <= 41)
        }
    }

    @Test
    @MainActor
    func mainPanelInitialContentRectProducesFinalWindowFrameWithoutResize() {
        let frame = NSWindow.frameRect(
            forContentRect: MainPanelWindowGeometry.initialContentRect,
            styleMask: MainPanelWindowGeometry.styleMask
        )

        #expect(frame.size == NSSize(width: 912, height: 768))
    }

    @Test
    @MainActor
    func consecutiveLeftClicksOnlyOpenMainPanel() {
        var contextMenuPresentationCount = 0
        var panelPresentationCount = 0

        for _ in 0..<2 {
            StatusBarController.performStatusItemClick(
                isRightClick: false,
                showContextMenu: {
                    contextMenuPresentationCount += 1
                },
                showMainPanel: {
                    panelPresentationCount += 1
                }
            )
        }

        #expect(contextMenuPresentationCount == 0)
        #expect(panelPresentationCount == 2)
    }

    @Test
    @MainActor
    func rightClickOnlyOpensContextMenu() {
        var contextMenuPresentationCount = 0
        var panelPresentationCount = 0

        StatusBarController.performStatusItemClick(
            isRightClick: true,
            showContextMenu: {
                contextMenuPresentationCount += 1
            },
            showMainPanel: {
                panelPresentationCount += 1
            }
        )

        #expect(contextMenuPresentationCount == 1)
        #expect(panelPresentationCount == 0)
    }

    @Test
    @MainActor
    func profileChoiceOutcomeOpensMainPanel() {
        var requestCount = 0
        var panelPresentationCount = 0

        StatusBarController.performManualRefresh(
            requestRefresh: {
                requestCount += 1
                return .profileChoiceRequired
            },
            showMainPanel: {
                panelPresentationCount += 1
            }
        )

        #expect(requestCount == 1)
        #expect(panelPresentationCount == 1)
    }

    @Test(arguments: [
        ManualRefreshRequestOutcome.deploymentRequested,
        ManualRefreshRequestOutcome.rejected
    ])
    @MainActor
    func nonChoiceOutcomeDoesNotOpenMainPanel(
        outcome: ManualRefreshRequestOutcome
    ) {
        var requestCount = 0
        var panelPresentationCount = 0

        StatusBarController.performManualRefresh(
            requestRefresh: {
                requestCount += 1
                return outcome
            },
            showMainPanel: {
                panelPresentationCount += 1
            }
        )

        #expect(requestCount == 1)
        #expect(panelPresentationCount == 0)
    }

    private func snapshot(
        title: String,
        icon: MenuBarIconTransitionIdentity,
        group: MenuBarTitleTransitionGroup,
        widthTier: MenuBarTitleWidthTier = .standard,
        fontStyle: MenuBarTitleFontStyle = .status,
        accessibilityLabel: String = ""
    ) -> StatusBarTransitionSnapshot {
        StatusBarTransitionSnapshot(
            title: title,
            iconTransitionIdentity: icon,
            titleGroup: group,
            titleWidthTier: widthTier,
            titleFontStyle: fontStyle,
            accessibilityLabel: accessibilityLabel
        )
    }

    @MainActor
    private func measuredWidth(of title: String, font: NSFont) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width
    }
}
