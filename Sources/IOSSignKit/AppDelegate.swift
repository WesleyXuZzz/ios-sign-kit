import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = ApplicationInstanceLock()
    private var viewModel: MenuBarViewModel?
    private var statusBarController: StatusBarController?
    private var systemWakeMonitor: SystemWakeMonitor?
#if DEBUG
    private var visualQAOutputTask: Task<Void, Never>?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try instanceLock.acquire()
        } catch {
            let message = "\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            NSApp.terminate(nil)
            return
        }

#if DEBUG
        if VisualQAScenario.isEnabled {
            do {
                let viewModel = try VisualQAScenario.makeViewModel()
                self.viewModel = viewModel
                if VisualQAScenario.phase == .deploying {
                    visualQAOutputTask = Task { @MainActor [weak viewModel] in
                        for sequence in 1...300 {
                            do { try await Task.sleep(for: .seconds(1)) } catch { return }
                            guard let viewModel else { return }
                            VisualQAScenario.appendMockOutput(to: viewModel, sequence: sequence)
                        }
                    }
                }
                NSApp.setActivationPolicy(.accessory)
                NSApp.appearance = NSAppearance(
                    named: VisualQAScenario.usesDarkAppearance
                        ? .darkAqua
                        : .aqua
                )
                let statusBarController = StatusBarController(viewModel: viewModel)
                self.statusBarController = statusBarController
                statusBarController.configureVisualQA(
                    initialTab: VisualQAScenario.page.initialTab,
                    settingsScrollAnchor:
                        VisualQAScenario.page.settingsScrollAnchor
                )
                if VisualQAScenario.usesCompactWindow {
                    statusBarController.setVisualQAFrameSize(
                        NSSize(width: 860, height: 680)
                    )
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    statusBarController.showMainPanel()
                }
            } catch {
                let message = "无法启动视觉验证模式：\(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                NSApp.terminate(nil)
            }
            return
        }
#endif

        // Only the real app entry point performs the global orphan scan.
        // The instance lock is already held and no CommandRunner work has
        // started, so matching markers from prior app instances are abandoned.
        let commandRecoveryOutcome =
            CommandProcessRecovery().recoverAnyCommand()
        let deploymentPrefixRecoveryOutcome =
            DeploymentProcessRecovery().recoverAnyDeployment()
        let rolloutConfiguration =
            DeviceDetectionRolloutConfiguration()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode:
                rolloutConfiguration.mode,
            deviceDetectionRolloutDiagnostic:
                rolloutConfiguration.resolution.diagnostic,
            bootstrapper: AppBootstrapper(
                commandProcessRecoveryOutcome:
                    commandRecoveryOutcome,
                deploymentPrefixRecoveryOutcome:
                    deploymentPrefixRecoveryOutcome
            )
        )
        self.viewModel = viewModel
        let systemWakeMonitor = SystemWakeMonitor { [weak viewModel] in
            viewModel?.handleSystemWake()
        }
        systemWakeMonitor.start()
        self.systemWakeMonitor = systemWakeMonitor
        NSApp.setActivationPolicy(.accessory)
        viewModel.performStartupRefresh()
        statusBarController = StatusBarController(viewModel: viewModel)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.statusBarController?.preloadMainPanelWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showMainPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
#if DEBUG
        visualQAOutputTask?.cancel()
        visualQAOutputTask = nil
#endif
        systemWakeMonitor?.stop()
        systemWakeMonitor = nil
        viewModel?.prepareForTermination()
    }
}
