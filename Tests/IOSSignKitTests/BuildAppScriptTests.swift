import Foundation
import Testing

struct BuildAppScriptTests {
    @Test(arguments: [false, true])
    func buildsFromOutsideProjectAndHoldsLockThroughMetrics(nestedResources: Bool) throws {
        let fixture = try Fixture(nestedResources: nestedResources)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try fixture.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Build complete"))
        #expect(try String(contentsOf: fixture.packagedResource, encoding: .utf8) == "fixture resource")
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test
    func metricsFailureReleasesLockWithoutRollingBackCommittedApp() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try fixture.run(failMetrics: true)
        #expect(result.status != 0)
        #expect(result.output.contains("Injected metrics failure"))
        #expect(!result.output.contains("Build complete"))
        #expect(FileManager.default.fileExists(atPath: fixture.packagedResource.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test(arguments: ["directory-link", "dangling-link", "regular-file"])
    func rejectsUnexpectedOutputBeforeBuilding(kind: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dist = fixture.project.appendingPathComponent("dist")
        let external = fixture.root.appendingPathComponent("external")
        if kind == "regular-file" {
            try Data("keep".utf8).write(to: dist)
        } else {
            if kind == "directory-link" {
                try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
                try Data("keep".utf8).write(to: external.appendingPathComponent("sentinel"))
            }
            try FileManager.default.createSymbolicLink(at: dist, withDestinationURL: external)
        }
        let result = try fixture.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Refusing unexpected build output directory"))
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("swift-called").path))
        if kind == "directory-link" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: external.path) == ["sentinel"])
            #expect(try String(contentsOf: external.appendingPathComponent("sentinel"), encoding: .utf8) == "keep")
        } else if kind == "dangling-link" {
            #expect(!FileManager.default.fileExists(atPath: external.path))
        } else {
            #expect(try String(contentsOf: dist, encoding: .utf8) == "keep")
        }
    }

    private struct Fixture {
        let root: URL
        let project: URL
        var lock: URL { project.appendingPathComponent("dist/.build-app.lock") }
        var packagedResource: URL {
            project.appendingPathComponent("dist/Fixture.app/Contents/Resources/ios-sign-kit_IOSSignKit.bundle/example.txt")
        }

        init(nestedResources: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("build-app-test-\(UUID().uuidString)")
            project = root.appendingPathComponent("project with spaces")
            for directory in ["scripts", "config", "Sources/IOSSignKit/Resources", "AppIcon.icon", "tools", "bin"] {
                try FileManager.default.createDirectory(
                    at: project.appendingPathComponent(directory), withIntermediateDirectories: true
                )
            }
            for script in ["build-app.sh", "validate-release-metadata.sh"] {
                try FileManager.default.copyItem(
                    at: testRepositoryRoot.appendingPathComponent("scripts/\(script)"),
                    to: project.appendingPathComponent("scripts/\(script)")
                )
            }
            try write("""
                {"appDisplayName":"Fixture","executableName":"Fixture","bundleIdentifier":"com.example.fixture",\
                "marketingVersion":"1.0.0","buildVersion":"1","minimumMacOSVersion":"14.0"}
                """, to: "config/release-metadata.json")
            try write("Resources/example.txt\truntime\n", to: "config/runtime-resources.tsv")
            try write("fixture resource", to: "Sources/IOSSignKit/Resources/example.txt")
            try write("icon input", to: "AppIcon.icon/icon.json")
            try write("binary fixture", to: "bin/Fixture")
            let resourceDirectory = "bin/ios-sign-kit_IOSSignKit.bundle"
                + (nestedResources ? "/Contents/Resources" : "")
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(resourceDirectory), withIntermediateDirectories: true
            )
            try write("fixture resource", to: "\(resourceDirectory)/example.txt")
            for tool in ["swift", "xcodebuild", "xcrun", "codesign", "stat"] {
                try write(Self.tool, to: "tools/\(tool)")
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: project.appendingPathComponent("tools/\(tool)").path
                )
            }
        }

        private func write(_ text: String, to path: String) throws {
            try Data(text.utf8).write(to: project.appendingPathComponent(path))
        }

        func run(failMetrics: Bool = false) throws -> (status: Int32, output: String) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [project.appendingPathComponent("scripts/build-app.sh").path]
            process.currentDirectoryURL = root
            process.environment = [
                "PATH": "\(project.appendingPathComponent("tools").path):/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "FIXTURE_PROJECT": project.path,
                "FAIL_METRICS": failMetrics ? "1" : "0",
            ]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        // Real script and filesystem transactions, with only expensive toolchain commands stubbed.
        private static let tool = #"""
        #!/bin/zsh
        set -eu
        case "${0:t}" in
          swift)
            [[ "$PWD" -ef "$FIXTURE_PROJECT" ]] || { echo 'Wrong package directory'; exit 90; }
            touch "$FIXTURE_PROJECT/swift-called"
            if [[ " $* " == *' --show-bin-path '* ]]; then
              echo "$FIXTURE_PROJECT/bin"
            fi
            ;;
          xcodebuild) printf 'Xcode 27.0\nBuild version 18A1\n' ;;
          xcrun)
            case "$1" in
              --sdk) echo '27.0' ;;
              actool)
                shift
                [[ "$1" == '--compile' ]]
                printf 'assets fixture' > "$2/Assets.car"
                ;;
              assetutil|strip) ;;
              *) exit 92 ;;
            esac
            ;;
          codesign) ;;
          stat)
            if /usr/bin/shlock -f "$FIXTURE_PROJECT/dist/.build-app.lock" -p "$$"; then
              echo 'Metrics ran without exclusive build lock' >&2
              exit 93
            fi
            if [[ "$FAIL_METRICS" == '1' ]]; then
              echo 'Injected metrics failure' >&2
              exit 94
            fi
            exec /usr/bin/stat "$@"
            ;;
          *) exit 95 ;;
        esac
        """#
    }
}
