import Foundation
import Testing

struct RepositoryPublicationScriptTests {
    @Test
    func publicSourceVerifierAcceptsGovernedSourceHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let result = try runVerifier(fixture)

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("公开源码检查通过"))
        #expect(result.standardOutput.contains("已检查历史提交: 1"))
    }

    @Test
    func publicSourceVerifierRejectsGeneratedDistributionArtifacts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(
            "fixture\n",
            to: fixture.working.appendingPathComponent("dist/iOSSignKit.dmg")
        )
        try commitAll("add generated artifact", in: fixture.working)

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("不能进入源码发布的路径"))
        #expect(result.standardError.contains("dist/iOSSignKit.dmg"))
    }

    @Test
    func publicSourceVerifierRejectsUppercaseSigningMaterialExtensions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(
            "fixture\n",
            to: fixture.working.appendingPathComponent(
                "Secrets/SigningIdentity.P12"
            )
        )
        try commitAll("add uppercase signing material", in: fixture.working)

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("不能进入源码发布的路径"))
        #expect(result.standardError.contains("SigningIdentity.P12"))
    }

    @Test
    func publicSourceVerifierRejectsPrivateHomePaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let privatePath = "/" + "Users/private-maintainer/Project"
        try write(
            "let localPath = \"\(privatePath)\"\n",
            to: fixture.working.appendingPathComponent("Sources/LocalPath.swift")
        )
        try commitAll("add private path", in: fixture.working)

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("本机路径"))
        #expect(result.standardError.contains("LocalPath.swift"))
    }

    @Test
    func publicSourceVerifierRejectsRetiredWorkflowMarkersInHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let retiredMarker = "github" + "-master"
        try write(
            "retired branch: \(retiredMarker)\n",
            to: fixture.working.appendingPathComponent("docs/retired.md")
        )
        try commitAll("add retired workflow marker", in: fixture.working)
        try FileManager.default.removeItem(
            at: fixture.working.appendingPathComponent("docs/retired.md")
        )
        try commitAll("remove retired workflow marker", in: fixture.working)

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("已退出的公开快照流程标记"))
    }

    @Test
    func publicSourceVerifierRejectsShallowHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            ["config", "user.email", "private-maintainer@example.test"],
            in: fixture.working
        )
        try write(
            "private path /" + "Users/private-maintainer/project\n",
            to: fixture.working.appendingPathComponent("Sources/Private.swift")
        )
        try commitAll("add private history", in: fixture.working)
        _ = try runGit(
            [
                "config",
                "user.email",
                "public-fixture@users.noreply.github.com",
            ],
            in: fixture.working
        )
        try FileManager.default.removeItem(
            at: fixture.working.appendingPathComponent("Sources/Private.swift")
        )
        try commitAll("remove private history fixture", in: fixture.working)
        try write(
            "let shallowBoundary = true\n",
            to: fixture.working.appendingPathComponent(
                "Sources/ShallowBoundary.swift"
            )
        )
        try commitAll("add shallow boundary", in: fixture.working)

        let shallow = fixture.container.appendingPathComponent(
            "shallow",
            isDirectory: true
        )
        _ = try runGit(
            [
                "clone",
                "--quiet",
                "--depth",
                "2",
                "file://\(fixture.working.path)",
                shallow.path,
            ],
            in: fixture.container
        )

        let result = try runVerifier(in: shallow)

        #expect(result.status != 0)
        #expect(result.standardError.contains("shallow 仓库"))
    }

    @Test
    func publicSourceVerifierRejectsReplacementObjects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let cleanCommit = try gitOutput(["rev-parse", "HEAD"], in: fixture.working)
        _ = try runGit(
            ["config", "user.email", "private-maintainer@example.test"],
            in: fixture.working
        )
        try write(
            "let replacementFixture = true\n",
            to: fixture.working.appendingPathComponent(
                "Sources/ReplacementFixture.swift"
            )
        )
        try commitAll(
            "private path /" + "Users/private-maintainer/project",
            in: fixture.working
        )
        let sensitiveCommit = try gitOutput(
            ["rev-parse", "HEAD"],
            in: fixture.working
        )
        _ = try runGit(
            ["replace", sensitiveCommit, cleanCommit],
            in: fixture.working
        )

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("replacement refs"))
    }

    @Test
    func publicSourceVerifierRejectsLegacyGrafts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let head = try gitOutput(["rev-parse", "HEAD"], in: fixture.working)
        try write(
            "\(head)\n",
            to: fixture.working.appendingPathComponent(".git/info/grafts")
        )

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("legacy grafts"))
    }

    @Test
    func publicSourceVerifierRejectsNonNoreplyAuthorIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(
            "let privateIdentity = true\n",
            to: fixture.working.appendingPathComponent("Sources/PrivateIdentity.swift")
        )
        _ = try runGit(["add", "--all"], in: fixture.working)
        _ = try runGit(
            [
                "commit",
                "--quiet",
                "--author",
                "Private Maintainer <private-maintainer@example.test>",
                "-m",
                "add author identity fixture",
            ],
            in: fixture.working
        )

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("作者邮箱不是 GitHub noreply 地址"))
    }

    @Test
    func publicSourceVerifierRejectsNonNoreplyCommitterIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            ["config", "user.email", "private-maintainer@example.test"],
            in: fixture.working
        )
        try write(
            "let privateCommitter = true\n",
            to: fixture.working.appendingPathComponent(
                "Sources/PrivateCommitter.swift"
            )
        )
        _ = try runGit(["add", "--all"], in: fixture.working)
        _ = try runGit(
            [
                "commit",
                "--quiet",
                "--author",
                "Public Fixture <public-fixture@users.noreply.github.com>",
                "-m",
                "add committer identity fixture",
            ],
            in: fixture.working
        )

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("提交者邮箱不是 GitHub noreply 地址"))
    }

    @Test
    func publicSourceVerifierRejectsSensitiveCommitMessage() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let privatePath = "/" + "Users/private-maintainer/project"
        try write(
            "let commitMessageFixture = true\n",
            to: fixture.working.appendingPathComponent(
                "Sources/CommitMessageFixture.swift"
            )
        )
        try commitAll("reference local path \(privatePath)", in: fixture.working)

        let result = try runVerifier(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("身份或消息命中"))
    }

    @Test
    func mirrorPublisherPushesTheSameCommitToBothRemotes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let result = try runPublisher(fixture)
        let localOID = try gitOutput(["rev-parse", "HEAD"], in: fixture.working)

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("双镜像推送完成"))
        #expect(try remoteOID(fixture.publicBare) == localOID)
        #expect(try remoteOID(fixture.privateBare) == localOID)
    }

    @Test
    func mirrorPublisherDoesNotFollowAnnotatedTags() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            ["config", "user.email", "private-tagger@example.test"],
            in: fixture.working
        )
        _ = try runGit(
            [
                "tag",
                "--annotate",
                "leaked-tag",
                "--message",
                "private path /" + "Users/private-maintainer/project",
            ],
            in: fixture.working
        )
        _ = try runGit(
            ["config", "push.followTags", "true"],
            in: fixture.working
        )

        let result = try runPublisher(fixture)

        #expect(result.status == 0)
        #expect(
            try remoteOID(
                fixture.publicBare,
                ref: "refs/tags/leaked-tag"
            ) == nil
        )
        #expect(
            try remoteOID(
                fixture.privateBare,
                ref: "refs/tags/leaked-tag"
            ) == nil
        )
    }

    @Test
    func mirrorPublisherDoesNotRunLocalPrePushHooks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let hook = fixture.working.appendingPathComponent(".git/hooks/pre-push")
        try write("#!/bin/sh\nexit 91\n", to: hook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook.path
        )

        let result = try runPublisher(fixture)

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("双镜像推送完成"))
    }

    @Test
    func mirrorPublisherDryRunDoesNotCreateRemoteBranches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let result = try runPublisher(fixture, arguments: ["--dry-run"])

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("Dry run completed"))
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsDirtyVerifierBeforeExecutingIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(
            "#!/bin/zsh\nexit 0\n",
            to: fixture.working
                .appendingPathComponent("scripts/verify-public-source.sh")
        )

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("工作区不干净"))
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsNonCanonicalPublicRemoteBeforeNetworkAccess()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            ["remote", "set-url", "origin", "https://example.invalid/repository.git"],
            in: fixture.working
        )

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("WesleyXuZzz/ios-sign-kit"))
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsPublicRepositoryAsPrivateMirror() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            [
                "remote",
                "set-url",
                "private",
                "git@github.com:WesleyXuZzz/ios-sign-kit.git",
            ],
            in: fixture.working
        )

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("独立私有镜像"))
        #expect(try remoteOID(fixture.publicBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsEquivalentGitHubURLAsPrivateMirror() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            [
                "remote",
                "set-url",
                "private",
                "ssh://git@github.com:22/WesleyXuZzz/ios-sign-kit.git",
            ],
            in: fixture.working
        )

        let result = try runPublisher(fixture, arguments: ["--dry-run"])

        #expect(result.status != 0)
        #expect(result.standardError.contains("独立私有镜像"))
        #expect(try remoteOID(fixture.publicBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsConfiguredURLRewrite() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            [
                "config",
                "url.\(fixture.publicBare.path).insteadOf",
                "https://github.com/WesleyXuZzz/ios-sign-kit.git",
            ],
            in: fixture.working
        )

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("fetch URL 被 url.*.insteadOf 重写"))
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsConfiguredPushURLRewrite() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try runGit(
            ["config", "--unset-all", "remote.origin.pushurl"],
            in: fixture.working
        )
        _ = try runGit(
            [
                "remote",
                "set-url",
                "origin",
                "git@github.com:WesleyXuZzz/ios-sign-kit.git",
            ],
            in: fixture.working
        )
        _ = try runGit(
            [
                "config",
                "url.\(fixture.publicBare.path).pushInsteadOf",
                "git@github.com:WesleyXuZzz/ios-sign-kit.git",
            ],
            in: fixture.working
        )

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("push URL 被"))
        #expect(result.standardError.contains("pushInsteadOf"))
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsMasterMovementAfterVerification() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let scripts = fixture.working.appendingPathComponent(
            "scripts",
            isDirectory: true
        )
        let verifier = scripts.appendingPathComponent("verify-public-source.sh")
        let realVerifier = scripts.appendingPathComponent(
            "verify-public-source-real.sh"
        )
        try FileManager.default.moveItem(at: verifier, to: realVerifier)
        try write(
            """
            #!/bin/zsh
            "${0:A:h}/verify-public-source-real.sh" "$@"
            /usr/bin/git -C "${0:A:h:h}" commit --quiet --allow-empty -m "concurrent fixture commit"

            """,
            to: verifier
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: verifier.path
        )
        try commitAll("install verifier race fixture", in: fixture.working)

        let verifiedCommit = try gitOutput(
            ["rev-parse", "HEAD"],
            in: fixture.working
        )
        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("本地 master 已发生变化"))
        #expect(
            try gitOutput(["rev-parse", "HEAD"], in: fixture.working)
                != verifiedCommit
        )
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherRejectsRemoteChangeAfterVerification() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let scripts = fixture.working.appendingPathComponent(
            "scripts",
            isDirectory: true
        )
        let verifier = scripts.appendingPathComponent("verify-public-source.sh")
        let realVerifier = scripts.appendingPathComponent(
            "verify-public-source-real.sh"
        )
        try FileManager.default.moveItem(at: verifier, to: realVerifier)
        try write(
            """
            #!/bin/zsh
            "${0:A:h}/verify-public-source-real.sh" "$@"
            /usr/bin/git -C "${0:A:h:h}" config remote.origin.pushurl "ssh://git@github.com/WesleyXuZzz/ios-sign-kit.git"

            """,
            to: verifier
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: verifier.path
        )
        try commitAll("install remote mutation fixture", in: fixture.working)

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("origin URL 配置发生变化"))
        #expect(try remoteOID(fixture.publicBare) == nil)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherUsesFrozenURLWhenRemoteChangesAtPushTime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let decoy = fixture.container.appendingPathComponent(
            "decoy.git",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: decoy,
            withIntermediateDirectories: true
        )
        _ = try runGit(
            ["init", "--quiet", "--bare", "--initial-branch=master"],
            in: decoy
        )
        let fakeGitDirectory = fixture.container.appendingPathComponent(
            "fake-git-bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fakeGitDirectory,
            withIntermediateDirectories: true
        )
        let mutationMarker = fixture.container.appendingPathComponent(
            "remote-mutated"
        )
        let fakeGit = fakeGitDirectory.appendingPathComponent("git")
        try write(
            """
            #!/bin/sh
            case " $* " in
              *" push "*)
                case " $* " in
                  *" --dry-run "*) ;;
                  *)
                    if [ ! -e "\(mutationMarker.path)" ]; then
                      /usr/bin/touch "\(mutationMarker.path)"
                      GIT_CONFIG="\(fixture.working.path)/.git/config" /usr/bin/git config remote.private.pushurl "\(decoy.path)"
                    fi
                    ;;
                esac
                ;;
            esac
            exec /usr/bin/git "$@"

            """,
            to: fakeGit
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGit.path
        )
        let inheritedPATH = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin"

        let result = try runPublisher(
            fixture,
            environment: [
                "PATH": "\(fakeGitDirectory.path):\(inheritedPATH)",
            ]
        )
        let localOID = try gitOutput(["rev-parse", "HEAD"], in: fixture.working)

        #expect(result.status != 0)
        #expect(result.standardError.contains("private URL 配置发生变化"))
        #expect(try remoteOID(fixture.privateBare) == localOID)
        #expect(try remoteOID(decoy) == nil)
        #expect(try remoteOID(fixture.publicBare) == nil)
    }

    @Test
    func mirrorPublisherPreflightsBothRemotesBeforeMutatingEither() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let publicSeedOID = try seedDivergentPublicRemote(fixture)

        let result = try runPublisher(fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("拒绝 fast-forward 预检"))
        #expect(try remoteOID(fixture.publicBare) == publicSeedOID)
        #expect(try remoteOID(fixture.privateBare) == nil)
    }

    @Test
    func mirrorPublisherReportsPartialSuccessWithoutForcing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try installRejectingHook(in: fixture.publicBare)

        let result = try runPublisher(fixture)
        let localOID = try gitOutput(["rev-parse", "HEAD"], in: fixture.working)

        #expect(result.status != 0)
        #expect(result.standardError.contains("GitHub 推送失败"))
        #expect(result.standardError.contains("私有镜像可能已经更新"))
        #expect(try remoteOID(fixture.privateBare) == localOID)
        #expect(try remoteOID(fixture.publicBare) == nil)
    }

    private func makeFixture() throws -> PublicationFixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-publication-\(UUID().uuidString)",
                isDirectory: true
            )
        let working = container.appendingPathComponent("working", isDirectory: true)
        let publicBare = container.appendingPathComponent("public.git", isDirectory: true)
        let privateBare = container.appendingPathComponent("private.git", isDirectory: true)
        let fakeSSH = container.appendingPathComponent("fake-github-ssh")
        for directory in [working, publicBare, privateBare] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        _ = try runGit(["init", "--quiet", "--initial-branch=master"], in: working)
        _ = try runGit(["init", "--quiet", "--bare", "--initial-branch=master"], in: publicBare)
        _ = try runGit(["init", "--quiet", "--bare", "--initial-branch=master"], in: privateBare)
        try write(
            """
            #!/bin/sh
            case "$*" in
              *git-upload-pack*) exec /usr/bin/git-upload-pack '\(publicBare.path)' ;;
              *git-receive-pack*) exec /usr/bin/git-receive-pack '\(publicBare.path)' ;;
              *) exit 1 ;;
            esac

            """,
            to: fakeSSH
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeSSH.path
        )
        _ = try runGit(["config", "user.name", "Public Fixture"], in: working)
        _ = try runGit(
            ["config", "user.email", "public-fixture@users.noreply.github.com"],
            in: working
        )

        let scripts = working.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: true
        )
        for scriptName in ["verify-public-source.sh", "push-source-mirrors.sh"] {
            try FileManager.default.copyItem(
                at: testRepositoryRoot.appendingPathComponent("scripts/\(scriptName)"),
                to: scripts.appendingPathComponent(scriptName)
            )
        }

        let rootFiles: [String: String] = [
            ".gitignore": "# fixture\n",
            "ASSET_PROVENANCE.md": "# Assets\n",
            "LICENSE": "MIT License\n",
            "Package.swift": "// swift-tools-version: 6.3\n",
            "README.md": "# Fixture\n",
            "SECURITY.md": "# Security\n",
            "Sources/App.swift": "let fixture = true\n",
        ]
        for (path, contents) in rootFiles {
            try write(contents, to: working.appendingPathComponent(path))
        }
        try commitAll("initial public source", in: working)
        let canonicalPublicURL =
            "https://github.com/WesleyXuZzz/ios-sign-kit.git"
        _ = try runGit(["remote", "add", "origin", canonicalPublicURL], in: working)
        _ = try runGit(
            [
                "remote",
                "set-url",
                "--push",
                "origin",
                "git@github.com:WesleyXuZzz/ios-sign-kit.git",
            ],
            in: working
        )
        _ = try runGit(["remote", "add", "private", privateBare.path], in: working)

        return PublicationFixture(
            container: container,
            working: working,
            publicBare: publicBare,
            privateBare: privateBare,
            fakeSSH: fakeSSH
        )
    }

    private func seedDivergentPublicRemote(
        _ fixture: PublicationFixture
    ) throws -> String {
        let seed = fixture.container.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        _ = try runGit(["init", "--quiet", "--initial-branch=master"], in: seed)
        _ = try runGit(["config", "user.name", "Divergent Fixture"], in: seed)
        _ = try runGit(
            ["config", "user.email", "divergent@users.noreply.github.com"],
            in: seed
        )
        try write("divergent\n", to: seed.appendingPathComponent("seed.txt"))
        try commitAll("divergent public history", in: seed)
        _ = try runGit(["remote", "add", "destination", fixture.publicBare.path], in: seed)
        _ = try runGit(["push", "destination", "master:master"], in: seed)
        return try gitOutput(["rev-parse", "HEAD"], in: seed)
    }

    private func installRejectingHook(in bareRepository: URL) throws {
        let hook = bareRepository.appendingPathComponent("hooks/pre-receive")
        try write(
            "#!/bin/sh\necho 'fixture rejection' >&2\nexit 1\n",
            to: hook
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook.path
        )
    }

    private func runVerifier(
        _ fixture: PublicationFixture
    ) throws -> PublicationProcessResult {
        try runVerifier(in: fixture.working)
    }

    private func runVerifier(
        in working: URL
    ) throws -> PublicationProcessResult {
        return try runProcess(
            executable: "/bin/zsh",
            arguments: [
                working.appendingPathComponent("scripts/verify-public-source.sh").path,
                "--repository",
                working.path,
            ],
            currentDirectory: working
        )
    }

    private func runPublisher(
        _ fixture: PublicationFixture,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> PublicationProcessResult {
        let publicationEnvironment = [
            "GIT_SSH_COMMAND": fixture.fakeSSH.path,
            "GIT_SSH_VARIANT": "ssh",
        ].merging(environment, uniquingKeysWith: { _, override in override })

        return try runProcess(
            executable: "/bin/zsh",
            arguments: [
                fixture.working.appendingPathComponent("scripts/push-source-mirrors.sh").path,
                "--repository",
                fixture.working.path,
            ] + arguments,
            currentDirectory: fixture.working,
            environment: publicationEnvironment
        )
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func commitAll(_ message: String, in root: URL) throws {
        _ = try runGit(["add", "--all"], in: root)
        _ = try runGit(["commit", "--quiet", "-m", message], in: root)
    }

    private func remoteOID(
        _ bareRepository: URL,
        ref: String = "refs/heads/master"
    ) throws -> String? {
        let result = try runGit(
            ["rev-parse", "--verify", ref],
            in: bareRepository,
            requireSuccess: false
        )
        guard result.status == 0 else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitOutput(
        _ arguments: [String],
        in root: URL
    ) throws -> String {
        try runGit(arguments, in: root).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        in root: URL,
        requireSuccess: Bool = true
    ) throws -> PublicationProcessResult {
        let result = try runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", root.path] + arguments,
            currentDirectory: root
        )
        if requireSuccess, result.status != 0 {
            throw PublicationTestError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                standardError: result.standardError
            )
        }
        return result
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String] = [:]
    ) throws -> PublicationProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        return PublicationProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private struct PublicationFixture {
    let container: URL
    let working: URL
    let publicBare: URL
    let privateBare: URL
    let fakeSSH: URL
}

private struct PublicationProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private enum PublicationTestError: Error {
    case commandFailed(command: String, standardError: String)
}
