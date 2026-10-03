import AppKit
import Combine
import Testing
@testable import IOSSignKit

struct StatusBarControllerTests {
    @Test
    @MainActor
    func statusNotificationsCoalesceAndReadTheFinalState() async {
        let publisher = ObservableObjectPublisher()
        var state = 0
        var renderedStates: [Int] = []
        let subscription = StatusBarController.observeStatusChanges(publisher) {
            renderedStates.append(state)
        }
        for value in 1...100 {
            publisher.send()
            state = value
        }
        #expect(renderedStates.isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(renderedStates == [100])

        publisher.send()
        state = 101
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(renderedStates == [100, 101])
        subscription.cancel()
        publisher.send()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(renderedStates == [100, 101])
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
}
