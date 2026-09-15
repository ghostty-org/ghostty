import AppKit
import Foundation
import Testing
@testable import Ghostty

struct WorkspaceProviderTests {
    @Test func titleDependencyRespectsPathDisplayAndRemoteState() {
        let local = PaneSessionContext(workingDirectory: "/work/repo", terminalTitle: "title")
        #expect(local.displaysTerminalTitle(pathDisplay: .fullPath))
        #expect(!local.displaysTerminalTitle(pathDisplay: .folderName))
        let unknownDirectory = PaneSessionContext(workingDirectory: nil, terminalTitle: "title")
        #expect(unknownDirectory.displaysTerminalTitle(pathDisplay: .folderName))
        var remote = local
        remote.apply(.init(action: .start, id: "omg-ssh-title",
                           metadata: "type=remote;targethost=cloud;cwd=/work/repo"),
                     currentWorkingDirectory: "/work/repo", currentTerminalTitle: "remote")
        #expect(!remote.displaysTerminalTitle(pathDisplay: .fullPath))
    }

    @Test func locationComparisonIgnoresOnlyTitleRevisions() {
        let initial = PaneSessionContext(workingDirectory: "/repo", terminalTitle: "first")
        var changed = initial
        changed.updateLocalMetadata(workingDirectory: "/repo", terminalTitle: "second")
        #expect(changed != initial)
        #expect(changed.hasSameLocation(as: initial))
        #expect(changed.local.terminalTitle == "second")
        changed.updateLocalMetadata(workingDirectory: "/other", terminalTitle: "second")
        #expect(!changed.hasSameLocation(as: initial))

        var remote = initial
        remote.apply(.init(action: .start, id: "omg-ssh-test",
                           metadata: "type=remote;targethost=cloud;cwd=/repo"),
                     currentWorkingDirectory: "/repo", currentTerminalTitle: "first")
        #expect(!remote.hasSameLocation(as: initial))
    }

    @Test func localRenamePreservesContentsAndRefusesConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("old.md")
        let renamed = root.appendingPathComponent("new.md")
        let occupied = root.appendingPathComponent("occupied.md")
        try Data("original".utf8).write(to: original)
        try Data("keep".utf8).write(to: occupied)
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        try await filesystem.renameItem(at: original.path, to: "new.md")
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: renamed) == Data("original".utf8))
        await #expect(throws: (any Error).self) {
            try await filesystem.renameItem(at: renamed.path, to: "occupied.md")
        }
        #expect(try Data(contentsOf: occupied) == Data("keep".utf8))
        #expect(try Data(contentsOf: renamed) == Data("original".utf8))
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await filesystem.renameItem(at: folder.path, to: "renamed folder")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed folder").path))
    }

    @Test func fileActionPathsRespectBoundariesAndRejectInvalidNames() throws {
        #expect(WorkspaceFileActions.relativePath("/work/docs/readme.md", root: "/work") == "docs/readme.md")
        #expect(WorkspaceFileActions.relativePath("/work/docs/readme.md", root: "/work/") == "docs/readme.md")
        #expect(WorkspaceFileActions.relativePath("/worker/a", root: "/work") == "/worker/a")
        #expect(WorkspaceFileActions.relativePath("/file", root: "/") == "file")
        #expect(try WorkspaceFileActions.renamedPath("/work/old.md", name: "new name.md") == "/work/new name.md")
        for name in ["", ".", "..", "../escape", "bad\nname", "bad\0name", "bad\rname"] {
            #expect(throws: WorkspaceFilesystemError.invalidPath) {
                try WorkspaceFileActions.renamedPath("/work/old.md", name: name)
            }
        }
    }

    @Test @MainActor func imageOnlyClipboardWritesTempFileAndPastesPath() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [:]
        ))

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("omg-image-paste-test-\(UUID().uuidString)")
        )
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-image-paste-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("omg-paste", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // No text/file content, so the string path is nil and the image
        // fallback produces a temp file path.
        #expect(pasteboard.getOpinionatedStringContents() == nil)
        let escaped = try #require(pasteboard.imagePastePath(directory: directory))
        #expect(escaped.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: escaped))
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: escaped
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // A pre-existing symlink must not redirect private image data.
        try FileManager.default.removeItem(at: directory)
        let target = root.appendingPathComponent("redirect-target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: directory,
            withDestinationURL: target
        )
        #expect(pasteboard.imagePastePath(directory: directory) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

        // Text content takes precedence over the image fallback.
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)
        #expect(pasteboard.getOpinionatedStringContents() == "hello")
    }

    @Test func existingImageFileOnPasteboardUsesDirectURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-img-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegFile = tempDir.appendingPathComponent("img_v3_test.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: jpegFile)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("omg-img-paste-test-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(jpegFile.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        // When a single existing image file is on the pasteboard (like Lark/Feishu copy image),
        // imagePasteURL should return the original file URL directly.
        let resolvedURL = try #require(pasteboard.imagePasteURL())
        #expect(resolvedURL.path == jpegFile.path)
        #expect(pasteboard.imagePastePath() == Ghostty.Shell.escape(jpegFile.path))

        // Non-image file on pasteboard should NOT be treated as an image paste
        let textFile = tempDir.appendingPathComponent("document.txt")
        try "hello".write(to: textFile, atomically: true, encoding: .utf8)
        let textPB = NSPasteboard(
            name: NSPasteboard.Name("omg-txt-paste-test-\(UUID().uuidString)")
        )
        textPB.clearContents()
        let textItem = NSPasteboardItem()
        textItem.setString(textFile.absoluteString, forType: .fileURL)
        textPB.writeObjects([textItem])
        #expect(textPB.imagePasteURL() == nil)
        #expect(textPB.imagePastePath() == nil)
        #expect(textPB.getOpinionatedStringContents() == Ghostty.Shell.escape(textFile.path))

        // Multiple image files on pasteboard should fall back to opinionated string contents
        let secondJpeg = tempDir.appendingPathComponent("img_v3_second.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: secondJpeg)
        let multiPB = NSPasteboard(
            name: NSPasteboard.Name("omg-multi-paste-test-\(UUID().uuidString)")
        )
        multiPB.clearContents()
        let item1 = NSPasteboardItem()
        item1.setString(jpegFile.absoluteString, forType: .fileURL)
        let item2 = NSPasteboardItem()
        item2.setString(secondJpeg.absoluteString, forType: .fileURL)
        multiPB.writeObjects([item1, item2])
        #expect(multiPB.imagePasteURL() == nil)

        // Directory with image extension should NOT be treated as an image
        let dirWithImgExt = tempDir.appendingPathComponent("fake_image.png")
        try FileManager.default.createDirectory(at: dirWithImgExt, withIntermediateDirectories: true)
        let dirPB = NSPasteboard(
            name: NSPasteboard.Name("omg-dir-paste-test-\(UUID().uuidString)")
        )
        dirPB.clearContents()
        let dirItem = NSPasteboardItem()
        dirItem.setString(dirWithImgExt.absoluteString, forType: .fileURL)
        dirPB.writeObjects([dirItem])
        #expect(dirPB.imagePasteURL() == nil)
    }

    @Test func parsesSSHConfigAliasesWithoutSecrets() throws {
        let previous = UserDefaults.standard.object(forKey: "OMG.Plugin.Enabled.builtin.ssh")
        UserDefaults.standard.set(true, forKey: "OMG.Plugin.Enabled.builtin.ssh")
        defer { UserDefaults.standard.set(previous, forKey: "OMG.Plugin.Enabled.builtin.ssh") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        Host cloud
            HostName 10.0.0.12
            User json
            Port 22
            IdentityFile ~/.ssh/id_ed25519

        Host *.example.com
            HostName ignored.example.com
        """.write(to: url, atomically: true, encoding: .utf8)

        let hosts = SSHPlugin.configurations(at: url)
        #expect(hosts == [
            .init(
                alias: "cloud",
                hostname: "10.0.0.12",
                user: "json",
                port: 22,
                proxyJump: nil
            ),
        ])
        #expect(hosts.first?.workspaceID == "ssh:cloud")
    }

    @Test func imageTransferBuildsPrivateRemoteSFTPBatch() {
        let batch = SSHImagePasteTransfer.batch(
            localPath: "/tmp/local image's.png",
            remotePath: "/tmp/omg-paste-123.png"
        )
        #expect(batch == """
        put '/tmp/local image'\\''s.png' '/tmp/omg-paste-123.png'
        chmod 600 '/tmp/omg-paste-123.png'
        """)
    }

    @Test func imageTransferPreservesKnownFileExtensions() {
        let jpgURL = URL(fileURLWithPath: "/tmp/img_v3_test.jpg")
        let jpgRemote = SSHImagePasteTransfer.remotePath(for: jpgURL)
        #expect(jpgRemote.hasPrefix("/tmp/omg-paste-"))
        #expect(jpgRemote.hasSuffix(".jpg"))

        let pngURL = URL(fileURLWithPath: "/tmp/screenshot.PNG")
        let pngRemote = SSHImagePasteTransfer.remotePath(for: pngURL)
        #expect(pngRemote.hasSuffix(".png"))

        let webpURL = URL(fileURLWithPath: "/tmp/photo.webp")
        let webpRemote = SSHImagePasteTransfer.remotePath(for: webpURL)
        #expect(webpRemote.hasSuffix(".webp"))

        let noExtURL = URL(fileURLWithPath: "/tmp/raw_image")
        let noExtRemote = SSHImagePasteTransfer.remotePath(for: noExtURL)
        #expect(noExtRemote.hasSuffix(".png"))
    }

    @Test func createsGenericLocalWorkspaceDescriptor() {
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: "/tmp/project")
        #expect(filesystem.descriptor.kind == .local)
        #expect(filesystem.descriptor.workingDirectory == "/tmp/project")
    }

    @Test func recognizesOnlyInteractiveForegroundSSHCommands() {
        #expect(ForegroundSSHProcessDetector.observe(
            in: "ssh cloud\n"
        ) == .interactive(alias: "cloud", transferTarget: "cloud"))
        #expect(ForegroundSSHProcessDetector.observe(
            in: "/usr/bin/ssh -p 2222 -J jump user@example.com\n"
        ) == .interactive(alias: "example.com", transferTarget: "user@example.com"))
        #expect(ForegroundSSHProcessDetector.observe(
            in: "ssh -W host:22 jump\nssh cloud\n"
        ) == .interactive(alias: "cloud", transferTarget: "cloud"))
        #expect(ForegroundSSHProcessDetector.observe(
            in: "ssh cloud uptime\n"
        ) == .ambiguous)
        #expect(ForegroundSSHProcessDetector.observe(
            in: "ssh -N cloud\n"
        ) == .ambiguous)
        #expect(ForegroundSSHProcessDetector.observe(
            in: "/bin/cat ssh cloud\n/usr/bin/ssh-agent -l\n"
        ) == .none)
    }

    @Test func foregroundSSHAutomaticallyTransitionsBackToLocal() {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "~/code"
        )
        context.observeForegroundSSH(
            alias: "cloud",
            transferTarget: "json@cloud",
            processGroupID: 401,
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "~/code"
        )
        guard case .sshConnecting(let connecting) = context.state else {
            Issue.record("Expected inferred SSH connecting state")
            return
        }
        #expect(connecting.alias == "cloud")
        #expect(connecting.transferTarget == "json@cloud")
        #expect(connecting.localProcessGroupID == 401)
        #expect(context.inferredSSHProcessGroupID == 401)
        #expect(context.tabIconSystemName == "cloud")

        context.applyInferredRemoteWorkingDirectory("/home/test/project")
        guard case .sshReady(let ready, let remoteCWD) = context.state else {
            Issue.record("Expected inferred SSH ready state")
            return
        }
        #expect(ready.alias == "cloud")
        #expect(remoteCWD == "/home/test/project")
        let staleDisconnect = context.finishForegroundSSH(
            processGroupID: 402,
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "remote title"
        )
        #expect(!staleDisconnect)
        #expect(context.isSSHSession)
        let activeDisconnect = context.finishForegroundSSH(
            processGroupID: 401,
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "remote title"
        )
        #expect(activeDisconnect)
        #expect(context.state == .local)
        #expect(context.workingDirectory == "/Users/test/code")
        #expect(context.tabIconSystemName == "terminal")
    }

    @Test func paneSessionLifecycleRestoresLocalContextOnDisconnect() {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "~/code"
        )
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "~/code"
        )
        guard case .sshConnecting(let connecting) = context.state else {
            Issue.record("Expected an SSH connecting context")
            return
        }
        #expect(connecting.alias == "cloud")
        #expect(context.workingDirectory == "/Users/test/code")
        #expect(context.presentationTitle == "~/code")
        #expect(context.remoteTabBreadcrumb == nil)
        #expect(context.tabIconSystemName == "cloud")
        #expect(connecting.localProcessGroupID == nil)

        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;serverid=hostkey-SHA256:test=;cwd=/tmp"
            ),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "remote title"
        )
        guard case .sshReady(let ready, let remoteCWD) = context.state else {
            Issue.record("Expected an SSH ready context")
            return
        }
        #expect(ready.alias == "cloud")
        #expect(ready.serverID == "hostkey-SHA256:test=")
        #expect(remoteCWD == "/tmp")
        #expect(context.presentationTitle == "cloud › tmp")
        #expect(context.remoteTabBreadcrumb == .init(host: "cloud", directory: "tmp"))
        #expect(context.tabIconSystemName == "cloud")

        context.apply(
            .init(
                action: .end,
                id: "omg-ssh-1",
                metadata: "exit=success;status=0;cwd=/Users/test/code"
            ),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "remote title"
        )
        #expect(context.state == .local)
        #expect(context.workingDirectory == "/Users/test/code")
        #expect(context.presentationTitle == "~/code")
        #expect(context.remoteTabBreadcrumb == nil)
        #expect(context.tabIconSystemName == "terminal")
        #expect(PaneSessionContext.isSSHReconnectCommand(
            "/bin/zsh\n/usr/bin/ssh cloud",
            alias: "cloud"
        ))
        #expect(!PaneSessionContext.isSSHReconnectCommand(
            "/usr/bin/ssh another-host",
            alias: "cloud"
        ))

        context.applyDetectedSSHReconnect(processGroupID: 42)
        guard case .sshReady(let detected, let detectedCWD) = context.state else {
            Issue.record("Expected a detected SSH reconnect")
            return
        }
        #expect(detected.connectionID == "omg-ssh-detected-42")
        #expect(detected.alias == "cloud")
        #expect(detected.serverID == "hostkey-SHA256:test=")
        #expect(detectedCWD == "/tmp")
        context.endDetectedSSHReconnect(processGroupID: 42)
        #expect(context.state == .local)

        context.updateLocalMetadata(
            workingDirectory: "/Users/test/code",
            terminalTitle: "remote title"
        )
        #expect(context.presentationTitle == "~/code")
        context.updateLocalMetadata(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        #expect(context.presentationTitle == "code")
    }

    @Test func sshStartUsesExplicitLocalCWDEvenAfterRemotePwdWinsRace() {
        var context = PaneSessionContext(
            workingDirectory: nil,
            terminalTitle: "Terminal"
        )
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;localcwd=/Users/test/my%20project"
            ),
            currentWorkingDirectory: "/remote/project",
            currentTerminalTitle: "remote"
        )
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/remote/project"
            ),
            currentWorkingDirectory: "/remote/project",
            currentTerminalTitle: "remote"
        )

        #expect(context.local.workingDirectory == "/Users/test/my project")
        #expect(context.workingDirectory == "/remote/project")
    }

    @Test func shellNeutralSSHPromptDecodesBoundedHexCWD() {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        let remotePath = "/remote/project; \u{4F60}\u{597D} % done"
        let encoded = remotePath.utf8.map { String(format: "%02x", $0) }.joined()
        context.apply(
            .init(
                action: .start,
                id: "omg-ssh-train",
                metadata: "type=remote;targethost=train;cwdhex=\(encoded)"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "train"
        )

        guard case .sshReady(let ssh, let cwd) = context.state else {
            Issue.record("Expected shell-neutral SSH prompt to become ready")
            return
        }
        #expect(ssh.alias == "train")
        #expect(cwd == remotePath)
        #expect(context.tabIconSystemName == "cloud")

        for invalid in ["0", "zz", String(repeating: "00", count: 4_097)] {
            var rejected = PaneSessionContext(
                workingDirectory: "/Users/test/code",
                terminalTitle: "code"
            )
            rejected.apply(
                .init(
                    action: .start,
                    id: "omg-ssh-invalid",
                    metadata: "type=remote;targethost=train;cwdhex=\(invalid)"
                ),
                currentWorkingDirectory: "/Users/test/code",
                currentTerminalTitle: "train"
            )
            guard case .sshConnecting = rejected.state else {
                Issue.record("Expected invalid remote cwd hex to be rejected")
                return
            }
        }
    }

    @Test func staleSSHDisconnectCannotClearNewConnection() {
        var context = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        for (id, alias) in [("omg-ssh-a", "cloud"), ("omg-ssh-b", "build")] {
            context.apply(
                .init(
                    action: .start,
                    id: id,
                    metadata: "type=remote;targethost=\(alias);cwd=/tmp"
                ),
                currentWorkingDirectory: "/tmp",
                currentTerminalTitle: alias
            )
        }
        context.apply(
            .init(action: .end, id: "omg-ssh-a", metadata: "status=255"),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "cloud"
        )
        guard case .sshReady(let active, _) = context.state else {
            Issue.record("Expected the newer SSH connection to remain active")
            return
        }
        #expect(active.connectionID == "omg-ssh-b")
        #expect(active.alias == "build")
        #expect(context.presentationTitle == "build › tmp")
        #expect(context.remoteTabBreadcrumb == .init(host: "build", directory: "tmp"))
    }

    @Test func unresolvedReadySSHNeverFallsBackToLocalFilesystem() {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=missing-host;cwd=/remote/path"
            ),
            currentWorkingDirectory: "/remote/path",
            currentTerminalTitle: "remote"
        )
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            session: session
        )
        let filesystem = WorkspaceFilesystemFactory.make(for: context)
        #expect(filesystem.descriptor.kind == .ssh)
        #expect(filesystem.descriptor.workingDirectory == "/remote/path")
    }

    @Test func remoteBreadcrumbAlwaysUsesCurrentFolder() {
        var local = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "~/code"
        )
        #expect(local.presentationTitle(pathDisplay: .fullPath) == "~/code")
        #expect(local.presentationTitle(pathDisplay: .folderName) == "code")
        #expect(local.agentPathTitle(pathDisplay: .fullPath) == "/Users/test/code")
        #expect(local.agentPathTitle(pathDisplay: .folderName) == "code")

        local.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/home/test/project/omg"
            ),
            currentWorkingDirectory: "/home/test/project/omg",
            currentTerminalTitle: "remote"
        )
        #expect(local.presentationTitle(pathDisplay: .fullPath) == "cloud › omg")
        #expect(local.presentationTitle(pathDisplay: .folderName) == "cloud › omg")
        #expect(local.agentPathTitle(pathDisplay: .fullPath) == "cloud › omg")
        #expect(local.agentPathTitle(pathDisplay: .folderName) == "cloud › omg")
        #expect(local.remoteTabBreadcrumb == .init(host: "cloud", directory: "omg"))
    }

    @Test func folderDisplayNameIsSharedByLocalAndRemoteFiles() {
        #expect(WorkspacePathPresentation.folderName("/Users/test/code") == "code")
        #expect(WorkspacePathPresentation.folderName("/home/test/project/omg") == "omg")
        #expect(WorkspacePathPresentation.folderName("/remote/path/that/does/not/exist") == "exist")
        #expect(WorkspacePathPresentation.folderName("/home/test/project/") == "project")
        #expect(WorkspacePathPresentation.folderName("relative/path") == "path")
        #expect(WorkspacePathPresentation.folderName("/") == "/")
        #expect(WorkspacePathPresentation.folderName("///") == "/")
        #expect(WorkspacePathPresentation.folderName("") == "")
    }

    @Test func sshReplayDescriptorPreservesExactArgumentsAndQuotesCommand() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let connectionID = "omg-ssh-123"
        let url = try #require(SSHReplayStore.url(
            for: connectionID,
            applicationSupportURL: support
        ))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: true,
            terminfo: false,
            cache: true,
            args: ["-J", "jump host", "user@cloud", "quote'arg"]
        )
        try JSONEncoder().encode(descriptor).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        let restored = try #require(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support
        ))
        #expect(restored == descriptor)
        let command = try #require(restored.command(
            executablePath: "/Applications/OMG Dev.app/Contents/MacOS/omg"
        ))
        #expect(command.contains("'+ssh'"))
        #expect(command.contains("'--ssh=/usr/bin/ssh'"))
        #expect(command.contains("'jump host'"))
        #expect(command.contains("'quote'\\''arg'"))
        #expect(command.hasSuffix("'quote'\\''arg'"))

        let cwdCommand = try #require(restored.command(
            executablePath: "/Applications/OMG Dev.app/Contents/MacOS/omg",
            remoteWorkingDirectory: "/home/test/project's code"
        ))
        #expect(cwdCommand.contains(
            "'--remote-working-directory=/home/test/project'\\''s code'"
        ))
    }

    @Test func sshResumeDescriptorBuildsReconnectCommandAndRoundTrips() throws {
        let descriptor = SSHResumeDescriptor(
            sshReplay: .init(
                version: 1,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: false,
                cache: true,
                args: ["cloud"]
            ),
            remoteWorkingDirectory: "/home/test/project",
            localWorkingDirectory: "/Users/test/code"
        )
        let command = try #require(descriptor.command(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(command.contains("'+ssh'"))
        #expect(command.contains("'--remote-working-directory=/home/test/project'"))
        #expect(!command.contains("--remote-agent"))

        let encoded = try JSONEncoder().encode(descriptor)
        #expect(try JSONDecoder().decode(
            SSHResumeDescriptor.self,
            from: encoded
        ) == descriptor)

        let noRemoteCWD = SSHResumeDescriptor(
            sshReplay: descriptor.sshReplay,
            remoteWorkingDirectory: nil,
            localWorkingDirectory: "/Users/test/code"
        )
        let reconnect = try #require(noRemoteCWD.command(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(!reconnect.contains("--remote-working-directory"))

        let invalid = SSHResumeDescriptor(
            sshReplay: .init(
                version: 2,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: false,
                cache: true,
                args: ["cloud"]
            ),
            remoteWorkingDirectory: nil,
            localWorkingDirectory: nil
        )
        #expect(invalid.command(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ) == nil)
    }

    @Test func sshReplayStoreRejectsInvalidOrStaleDescriptors() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(SSHReplayStore.url(
            for: "../../escape",
            applicationSupportURL: support
        ) == nil)

        let connectionID = "omg-ssh-stale"
        let url = try #require(SSHReplayStore.url(
            for: connectionID,
            applicationSupportURL: support
        ))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = SSHReplayDescriptor(
            version: 1,
            ssh: "ssh",
            forwardEnv: true,
            terminfo: true,
            cache: true,
            args: ["cloud"]
        )
        try JSONEncoder().encode(descriptor).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let tomorrow = Date().addingTimeInterval(25 * 60 * 60)
        #expect(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support,
            now: tomorrow
        ) == nil)
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date(),
                .posixPermissions: 0o644,
            ],
            ofItemAtPath: url.path
        )
        #expect(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support
        ) == nil)
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date().addingTimeInterval(10 * 60),
                .posixPermissions: 0o600,
            ],
            ofItemAtPath: url.path
        )
        #expect(SSHReplayStore.load(
            connectionID: connectionID,
            applicationSupportURL: support
        ) == nil)
    }

    @Test func boundsLargeSFTPDirectoryListings() throws {
        let output = (0..<800).map { index in
            "-rw-r--r-- 1 user group 1 Jan 1 00:00 file-\(index)"
        }.joined(separator: "\n")
        let entries = try SSHWorkspaceFilesystem.parseLongListing(
            output,
            directory: "/remote"
        )
        #expect(entries.count == 500)
        #expect(entries.allSatisfy { $0.path.hasPrefix("/remote/") })
    }

    @Test func parsesSFTPListingPathsWithoutDuplicatingDirectory() throws {
        let output = """
        -rw-r--r-- 1 root root 1 Jan 1 00:00 /root/configure-maintenance.sh
        -rw-r--r-- 1 root root 1 Jan 1 00:00 root/file with spaces.txt
        -rw-r--r-- 1 root root 1 Jan 1 00:00 relative.txt
        lrwxrwxrwx 1 root root 7 Jan 1 00:00 current -> release
        """
        let entries = try SSHWorkspaceFilesystem.parseLongListing(output, directory: "/root")
        #expect(entries.map(\.path) == [
            "/root/configure-maintenance.sh",
            "/root/current",
            "/root/file with spaces.txt",
            "/root/relative.txt",
        ])
        #expect(entries.first { $0.name == "current" }?.isDirectory == false)
    }

    @Test func quotesSFTPBatchPaths() {
        #expect(SSHWorkspaceFilesystem.quote("/root/file name") == "\"/root/file name\"")
        #expect(SSHWorkspaceFilesystem.quote("/root/a\\b\"c") == "\"/root/a\\\\b\\\"c\"")
    }

    @Test func createsSSHWorkspaceDescriptorFromAlias() throws {
        let previous = UserDefaults.standard.object(forKey: "OMG.Plugin.Enabled.builtin.ssh")
        UserDefaults.standard.set(true, forKey: "OMG.Plugin.Enabled.builtin.ssh")
        defer { UserDefaults.standard.set(previous, forKey: "OMG.Plugin.Enabled.builtin.ssh") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        Host cloud
            HostName 10.0.0.12
            User json
        """.write(to: url, atomically: true, encoding: .utf8)
        let configuration = try #require(SSHPlugin.configurations(at: url).first)
        let filesystem = SSHWorkspaceFilesystem(
            host: configuration,
            workingDirectory: "/home/json/project"
        )
        #expect(filesystem.descriptor.kind == .ssh)
        #expect(filesystem.descriptor.id == "ssh:cloud")
        #expect(filesystem.descriptor.displayName == "cloud")
    }

    @Test func parsesSFTPFileAttributesAndPermissions() {
        let output = "-rwxr-xr-x 1 user group 12345678 Jan 1 00:00 /remote/script.sh"
        let attrs = SSHWorkspaceFilesystem.parseFileAttributes(from: output)
        #expect(attrs?.size == 12345678)
        #expect(attrs?.isDirectory == false)
        #expect(attrs?.permissions == 0o755)

        let dirOutput = "drwxr-xr-x 2 user group 4096 Jan 1 00:00 /remote/dir"
        let dirAttrs = SSHWorkspaceFilesystem.parseFileAttributes(from: dirOutput)
        #expect(dirAttrs?.isDirectory == true)
        #expect(dirAttrs?.permissions == 0o755)

        let mode = SSHWorkspaceFilesystem.parsePosixPermissions("-rw-r--r--")
        #expect(mode == 0o644)

        // Special permission bits: SUID, SGID, Sticky bit and without execute (S/T)
        #expect(SSHWorkspaceFilesystem.parsePosixPermissions("-rwSr--r--") == 0o4644)
        #expect(SSHWorkspaceFilesystem.parsePosixPermissions("-rwsr-xr-x") == 0o4755)
        #expect(SSHWorkspaceFilesystem.parsePosixPermissions("-rwxr-sr-x") == 0o2755)
        #expect(SSHWorkspaceFilesystem.parsePosixPermissions("-rwxr-Sr-x") == 0o2745)
        #expect(SSHWorkspaceFilesystem.parsePosixPermissions("drwxrwxrwt") == 0o1777)
        #expect(SSHWorkspaceFilesystem.parsePosixPermissions("drwxrwx--T") == 0o1770)
    }

    @Test func parsesSFTPSymlinkTarget() {
        let output = "lrwxrwxrwx 1 root root 7 Jan 1 00:00 /root/current -> /root/release"
        #expect(SSHWorkspaceFilesystem.parseSymlinkTarget(from: output) == "/root/release")

        let relOutput = "lrwxrwxrwx 1 root root 7 Jan 1 00:00 current -> release/v1"
        #expect(SSHWorkspaceFilesystem.parseSymlinkTarget(from: relOutput) == "release/v1")

        let nonLink = "-rw-r--r-- 1 root root 10 Jan 1 00:00 regular.txt"
        #expect(SSHWorkspaceFilesystem.parseSymlinkTarget(from: nonLink) == nil)
    }

    @Test func parsesSymlinkStatusFromRealSFTPServerDirectoryListing() {
        // Real OpenSSH sftp-server readdir output: no "-> target" arrow, only "l" prefix in mode
        let listing = """
        drwx------    ? chengjisheng staff         128 Sep  7 15:38 /remote/dir/.
        drwx------    ? chengjisheng staff      227168 Sep  7 15:38 /remote/dir/..
        lrwxr-xr-x    ? chengjisheng staff          71 Sep  7 15:38 /remote/dir/link.txt
        -rw-r--r--    ? chengjisheng staff           5 Sep  7 15:38 /remote/dir/target.txt
        """
        #expect(SSHWorkspaceFilesystem.parseSymlinkStatus(name: "link.txt", fromDirectoryListing: listing) == .symlink)
        #expect(SSHWorkspaceFilesystem.parseSymlinkStatus(name: "target.txt", fromDirectoryListing: listing) == .regularFile)
        #expect(SSHWorkspaceFilesystem.parseSymlinkStatus(name: "nonexistent.txt", fromDirectoryListing: listing) == .indeterminate)
    }

    @Test func shellQuoteEscapesSpecialCharactersAndSingleQuotes() {
        #expect(SSHWorkspaceFilesystem.shellQuote("simple.txt") == "'simple.txt'")
        #expect(SSHWorkspaceFilesystem.shellQuote("foo'bar.txt") == "'foo'\\''bar.txt'")
        #expect(SSHWorkspaceFilesystem.shellQuote("foo$(printf expanded).txt") == "'foo$(printf expanded).txt'")
        #expect(SSHWorkspaceFilesystem.shellQuote("foo`whoami`$USER.txt") == "'foo`whoami`$USER.txt'")
    }
}
