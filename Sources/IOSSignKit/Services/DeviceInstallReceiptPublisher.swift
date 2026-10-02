import Foundation

struct DeviceInstallReceiptPublisher {
    /// All commands run through the active deployment's cancellation and
    /// process-ownership tracker. A failed transfer never undoes installation.
    func publish(
        installation: HostInstallReceipt,
        installResultURL: URL,
        workspaceURL: URL,
        runCommand: ([String]) throws -> Void
    ) throws {
        let data = try BoundedFileReader().data(
            at: installResultURL,
            maximumBytes: BoundedFileReader.structuredOutputMaximumBytes
        )
        let response = try JSONDecoder().decode(InstallResponse.self, from: data)
        let matches = response.result.installedApplications.filter {
            $0.bundleID == installation.bundleIdentifier
        }
        guard matches.count == 1, let installed = matches.first else {
            throw DeviceInstallReceiptError.invalid("安装结果未提供唯一的目标 App 容器。")
        }
        let receipt = DeviceInstallReceipt(
            schemaVersion: 1,
            installationAppURL: installed.installationURL,
            installation: installation
        )
        let encoded = try receipt.encoded()
        try confirmCurrentInstallation(receipt, workspaceURL: workspaceURL, runCommand: runCommand)

        let sourceURL = workspaceURL.appendingPathComponent("device-install-receipt.json")
        try encoded.write(to: sourceURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        try runCommand([
            "devicectl", "device", "copy", "to",
            "--device", installation.deviceIdentifier,
            "--domain-type", "appDataContainer",
            "--domain-identifier", installation.bundleIdentifier,
            "--source", sourceURL.path,
            "--destination", DeviceInstallReceipt.containerPath,
            "--timeout", "30"
        ])
        let readbackURL = workspaceURL.appendingPathComponent("device-install-receipt-readback.json")
        try runCommand([
            "devicectl", "device", "copy", "from",
            "--device", installation.deviceIdentifier,
            "--domain-type", "appDataContainer",
            "--domain-identifier", installation.bundleIdentifier,
            "--source", DeviceInstallReceipt.containerPath,
            "--destination", readbackURL.path,
            "--timeout", "30"
        ])
        let readback = try BoundedFileReader().data(at: readbackURL, maximumBytes: DeviceInstallReceipt.maximumBytes)
        guard readback == encoded else {
            throw DeviceInstallReceiptError.invalid("设备回执读回内容与本次安装不一致。")
        }
        // Never rebind our verified artifact to a different Mac's intervening
        // installation, even when version, Build and Profile are unchanged.
        try confirmCurrentInstallation(receipt, workspaceURL: workspaceURL, runCommand: runCommand)
    }

    private func confirmCurrentInstallation(
        _ receipt: DeviceInstallReceipt,
        workspaceURL: URL,
        runCommand: ([String]) throws -> Void
    ) throws {
        let outputURL = workspaceURL.appendingPathComponent("receipt-apps-\(UUID().uuidString).json")
        let installation = receipt.installation
        try runCommand([
            "devicectl", "device", "info", "apps",
            "--device", installation.deviceIdentifier,
            "--bundle-id", installation.bundleIdentifier,
            "--json-output", outputURL.path,
            "--timeout", "30"
        ])
        let data = try BoundedFileReader().data(at: outputURL, maximumBytes: BoundedFileReader.structuredOutputMaximumBytes)
        guard let app = try DeviceAppsResponse.app(from: data, bundleID: installation.bundleIdentifier),
              receipt.validation(deviceID: installation.deviceIdentifier, app: app) == .valid else {
            throw DeviceInstallReceiptError.invalid("设备当前安装已变化或无法绑定本次安装回执。")
        }
    }

    private struct InstallResponse: Decodable {
        struct Result: Decodable {
            struct Application: Decodable {
                let bundleID: String
                let installationURL: String
            }
            let installedApplications: [Application]
        }
        let result: Result
    }
}
