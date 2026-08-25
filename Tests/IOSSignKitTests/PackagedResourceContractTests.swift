import AppKit
import Foundation
import Testing
@testable import IOSSignKit

struct PackagedResourceContractTests {
    private static let excludedAppIconSourceFileNames: Set<String> = [
        "AppIcon.icns",
        "AppIconMaster.png",
        "icon_16x16.png",
        "icon_16x16@2x.png",
        "icon_32x32.png",
        "icon_32x32@2x.png",
        "icon_128x128.png",
        "icon_128x128@2x.png",
        "icon_256x256.png",
        "icon_256x256@2x.png",
        "icon_512x512.png",
        "icon_512x512@2x.png",
    ]

    @Test
    func swiftPMBundleContainsExactlyTheDeclaredRuntimeResources() throws {
        let manifest = try runtimeResourceManifest()
        #expect(
            manifest.filter({ $0.role == "notification-attachment" }).count
                == 4
        )
        #expect(
            Set(manifest.map(\.role))
                == Set(["notification-attachment", "runtime"])
        )
        for entry in manifest {
            #expect(
                FileManager().fileExists(
                    atPath: testRepositoryRoot
                        .appendingPathComponent("Sources/IOSSignKit")
                        .appendingPathComponent(entry.sourcePath)
                        .path
                )
            )
        }
        let fileURLs = try packagedFileURLs()
        let packagedFileNames = fileURLs.map(\.lastPathComponent)

        #expect(
            Set(packagedFileNames) == Set(manifest.map(\.fileName))
        )
        #expect(
            packagedFileNames.count
                == manifest.count
        )
    }

    @Test
    func swiftPMBundleExcludesAppIconSourceResources() throws {
        let fileURLs = try packagedFileURLs()
        let packagedFileNames = Set(fileURLs.map(\.lastPathComponent))

        #expect(
            packagedFileNames.isDisjoint(
                with: Self.excludedAppIconSourceFileNames
            )
        )
        #expect(
            !fileURLs.contains { $0.pathComponents.contains("AppIcon.iconset") }
        )
    }

    @Test
    func notificationAttachmentsStayAtOptimizedDimensions() throws {
        let resourceURL = try #require(Bundle.module.resourceURL)

        for fileName in try runtimeResourceManifest()
            .filter({ $0.role == "notification-attachment" })
            .map(\.fileName) {
            let fileURL = resourceURL.appendingPathComponent(fileName)
            let data = try Data(contentsOf: fileURL)
            let representation = try #require(NSBitmapImageRep(data: data))

            #expect(representation.pixelsWide == 256)
            #expect(representation.pixelsHigh == 256)
            #expect(!representation.hasAlpha)
        }
    }

    @Test
    func lanControlSuccessCompletionSubmitsDismissAction() throws {
        let scriptURL = testRepositoryRoot
            .appendingPathComponent("Sources/IOSSignKit/Resources/LANControlWeb/app.js")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(
            script.contains(
                "elements.successDone.addEventListener(\"click\", () => performAction(\"/api/dismiss-result\"));"
            )
        )
    }

    private func runtimeResourceManifest() throws -> [
        (sourcePath: String, fileName: String, role: String)
    ] {
        let manifestURL = testRepositoryRoot
            .appendingPathComponent("config/runtime-resources.tsv")
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
        return try content.split(whereSeparator: \.isNewline).compactMap { line in
            if line.isEmpty || line.hasPrefix("#") {
                return nil
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw ManifestError.invalidEntry(String(line))
            }
            return (
                String(fields[0]),
                URL(fileURLWithPath: String(fields[0])).lastPathComponent,
                String(fields[1])
            )
        }
    }

    private func packagedFileURLs() throws -> [URL] {
        let resourceURL = try #require(Bundle.module.resourceURL)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            if values.isRegularFile == true {
                fileURLs.append(fileURL)
            }
        }
        return fileURLs
    }
}

private enum ManifestError: Error {
    case invalidEntry(String)
}
