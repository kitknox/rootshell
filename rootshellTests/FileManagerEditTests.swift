import XCTest

final class FileManagerEditTests: XCTestCase {

    // MARK: - Classification

    func testCommonServerAndConfigFilesOpenInEditor() {
        let names = [
            ".env", ".env.local", ".env.production", "app.env",
            "Dockerfile", "Dockerfile.prod", "Containerfile",
            "Makefile", "GNUmakefile", "Justfile", "Caddyfile",
            "nginx.conf", "sshd_config", "ssh_config", "hosts", "fstab",
            "config.toml", "docker-compose.yml", "values.yaml",
            "package.json", "tsconfig.jsonc", "my.cnf", "app.ini",
            "nginx.service", "backup.timer", ".bashrc", ".zshrc",
            ".gitconfig", ".gitignore", ".dockerignore",
            "deploy.sh", "server.py", "main.go", "lib.rs", "App.swift",
            "index.tsx", "query.sql", "README.md", "icon.svg",
        ]
        for name in names {
            XCTAssertEqual(
                FileEditClassification.decision(forName: name, size: 1024),
                .edit,
                "Expected \(name) to open in editor"
            )
        }
    }

    func testKnownBinaryFilesUseQuickLook() {
        let names = [
            "photo.png", "image.jpg", "clip.mp4", "song.mp3",
            "manual.pdf", "bundle.tar.gz", "archive.zip", "app.dmg",
            "font.woff2", "data.sqlite", "module.wasm", "libfoo.dylib",
            ".DS_Store", "slides.pptx", "sheet.xlsx",
        ]
        for name in names {
            XCTAssertEqual(
                FileEditClassification.decision(forName: name, size: 1024),
                .quickLook,
                "Expected \(name) to use Quick Look"
            )
        }
    }

    func testExtensionlessAndUnknownFilesSniffBeforeDeciding() {
        XCTAssertEqual(FileEditClassification.decision(forName: "my-custom-config", size: 512), .sniffThenDecide)
        XCTAssertEqual(FileEditClassification.decision(forName: "worker", size: 0), .sniffThenDecide)
        XCTAssertEqual(FileEditClassification.decision(forName: "unknown.xyz123", size: 2048), .sniffThenDecide)
    }

    func testOversizedFilesFallBackToQuickLook() {
        let tooBig = FileEditClassification.maxInAppEditBytes + 1
        XCTAssertEqual(FileEditClassification.decision(forName: "huge.json", size: tooBig), .quickLook)
        XCTAssertEqual(FileEditClassification.decision(forName: "huge-no-ext", size: tooBig), .quickLook)
    }

    // MARK: - Content Sniffing

    func testIsTextDataRecognizesValidTextAndRejectsBinary() {
        XCTAssertTrue(FileEditClassification.isTextData(Data()))
        XCTAssertTrue(FileEditClassification.isTextData(Data("PORT=8080\nHOST=localhost\n".utf8)))
        XCTAssertTrue(FileEditClassification.isTextData(Data("#!/bin/sh\necho \"héllo 🚀 世界\"\n".utf8)))

        // UTF-8 BOM
        var bomUTF8 = Data([0xEF, 0xBB, 0xBF])
        bomUTF8.append(Data("key = \"value\"\n".utf8))
        XCTAssertTrue(FileEditClassification.isTextData(bomUTF8))

        // UTF-16 LE with BOM (contains NUL bytes, still valid text)
        var bomUTF16 = Data([0xFF, 0xFE])
        bomUTF16.append("hello=world\n".data(using: .utf16LittleEndian)!)
        XCTAssertTrue(FileEditClassification.isTextData(bomUTF16))

        // Multi-byte UTF-8 sequence split right across the 8192-byte sniff boundary
        var boundary = Data(repeating: 0x61, count: FileEditClassification.sniffByteCount - 1)
        boundary.append(Data("🚀end".utf8))
        XCTAssertTrue(FileEditClassification.isTextData(boundary))

        // Binary data: NUL bytes, PNG header, ELF header, binary plist
        XCTAssertFalse(FileEditClassification.isTextData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])))
        XCTAssertFalse(FileEditClassification.isTextData(Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00])))
        XCTAssertFalse(FileEditClassification.isTextData(Data("bplist00\u{01}\u{02}".utf8)))
    }

    // MARK: - Encoding & Line-Ending Round Trip

    func testDocumentPreservesCRLFAndUTF8BOM() {
        var original = Data([0xEF, 0xBB, 0xBF])
        original.append(Data("line1\r\nline2\r\n".utf8))

        let doc = EditableTextDocument.decode(original)
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.encoding, .utf8BOM)
        XCTAssertEqual(doc?.lineEnding, .crlf)
        XCTAssertEqual(doc?.text, "line1\nline2\n")

        let reencoded = doc!.encode("line1\nline2\nline3\n")
        var expected = Data([0xEF, 0xBB, 0xBF])
        expected.append(Data("line1\r\nline2\r\nline3\r\n".utf8))
        XCTAssertEqual(reencoded, expected)
    }

    func testDocumentPreservesUTF16LE() {
        var original = Data([0xFF, 0xFE])
        original.append("a=1\nb=2\n".data(using: .utf16LittleEndian)!)

        let doc = EditableTextDocument.decode(original)
        XCTAssertEqual(doc?.encoding, .utf16LE)
        XCTAssertEqual(doc?.lineEnding, .lf)
        XCTAssertEqual(doc?.text, "a=1\nb=2\n")

        let reencoded = doc!.encode("a=1\nb=3\n")
        var expected = Data([0xFF, 0xFE])
        expected.append("a=1\nb=3\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(reencoded, expected)
    }

    func testDocumentDecodesLatin1AndUpgradesOnUnicodeEdit() {
        // "café" in ISO-8859-1 (0xE9 is invalid standalone UTF-8)
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        let doc = EditableTextDocument.decode(latin1)
        XCTAssertEqual(doc?.encoding, .isoLatin1)
        XCTAssertEqual(doc?.text, "café\n")
        XCTAssertEqual(doc?.encode("café\n"), latin1)

        // Adding emoji falls back to UTF-8 rather than dropping characters.
        let upgraded = doc!.encode("café 🚀\n")
        XCTAssertEqual(String(data: upgraded, encoding: .utf8), "café 🚀\n")
    }

    func testIndentationDetection() {
        XCTAssertEqual(EditableTextDocument.detectIndentation(in: "all:\n\techo hi\n", filename: "Makefile"), .tabs)
        XCTAssertEqual(EditableTextDocument.detectIndentation(in: "{\n  \"a\": 1\n}\n", filename: "config.json"), .spaces(2))
        XCTAssertEqual(EditableTextDocument.detectIndentation(in: "def f():\n    return 1\n", filename: "app.py"), .spaces(4))
        XCTAssertEqual(EditableTextDocument.detectIndentation(in: "server {\n\tlisten 80;\n}\n", filename: "nginx.conf"), .tabs)
    }

    func testContentDigestDetectsSingleByteChanges() {
        let a = EditableTextDocument.contentDigest(Data("hello".utf8))
        let b = EditableTextDocument.contentDigest(Data("hello".utf8))
        let c = EditableTextDocument.contentDigest(Data("hellp".utf8))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Remote Fingerprint Conflicts

    func testFingerprintConflictDetection() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let base = RemoteFileFingerprint(size: 100, modified: t0)
        let sameSecond = RemoteFileFingerprint(size: 100, modified: t0.addingTimeInterval(0.4))
        let oneSecondLater = RemoteFileFingerprint(size: 100, modified: t0.addingTimeInterval(1.0))
        let newer = RemoteFileFingerprint(size: 100, modified: t0.addingTimeInterval(3.0))
        let resized = RemoteFileFingerprint(size: 105, modified: t0)
        let missingDate = RemoteFileFingerprint(size: 100, modified: nil)

        XCTAssertFalse(base.differs(from: sameSecond))
        // Exact 1-second SFTP boundary must be flagged as a conflict even when size matches.
        XCTAssertTrue(base.differs(from: oneSecondLater))
        XCTAssertTrue(base.differs(from: newer))
        XCTAssertTrue(base.differs(from: resized))
        XCTAssertTrue(base.differs(from: missingDate))

        // Exact precision catches sub-second edits too.
        let exactA = RemoteFileFingerprint(size: 100, modified: t0, precision: .exact)
        let exactB = RemoteFileFingerprint(size: 100, modified: t0.addingTimeInterval(0.4), precision: .exact)
        XCTAssertTrue(exactA.differs(from: exactB))

        // S3 ETags take precedence when present on both sides.
        let s3A = RemoteFileFingerprint(size: 100, modified: t0, eTag: "abc")
        let s3B = RemoteFileFingerprint(size: 100, modified: t0, eTag: "def")
        let s3Same = RemoteFileFingerprint(size: 100, modified: t0.addingTimeInterval(5), eTag: "abc")
        XCTAssertTrue(s3A.differs(from: s3B))
        XCTAssertFalse(s3A.differs(from: s3Same))
    }

    // MARK: - Staging Directory Cleanup Safety

    func testStagingCleanupOnlyAllowsDirectChildrenOfStagingRoot() {
        let root = URL(fileURLWithPath: "/tmp/Caches/FileManagerEdits", isDirectory: true)
        let validChild = root.appendingPathComponent("session-123", isDirectory: true)
        let nestedGrandchild = validChild.appendingPathComponent("nested", isDirectory: true)
        let escaped = root.appendingPathComponent("../Documents/project", isDirectory: true)
        let unrelatedProject = URL(fileURLWithPath: "/Users/dev/project", isDirectory: true)

        XCTAssertTrue(FileEditStagingPath.isDirectChild(validChild, of: root))
        XCTAssertFalse(FileEditStagingPath.isDirectChild(root, of: root))
        XCTAssertFalse(FileEditStagingPath.isDirectChild(nestedGrandchild, of: root))
        XCTAssertFalse(FileEditStagingPath.isDirectChild(escaped, of: root))
        XCTAssertFalse(FileEditStagingPath.isDirectChild(unrelatedProject, of: root))
    }

    func testStagingRelaunchCleanupPreservesUnsyncedWorkingCopies() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Cleanly synced folder: hasPendingUpload == false and disk hash matches manifest -> PRUNED.
        let cleanDir = root.appendingPathComponent("clean-session", isDirectory: true)
        try fm.createDirectory(at: cleanDir, withIntermediateDirectories: true)
        let cleanData = Data("server_name example.com;\n".utf8)
        let cleanFile = cleanDir.appendingPathComponent("nginx.conf")
        try cleanData.write(to: cleanFile)
        FileEditStagingCleanup.writeManifest(
            StagingFolderManifest(
                folderName: "clean-session",
                fileName: "nginx.conf",
                lastSyncedHashHex: FileEditStagingCleanup.hexDigest(EditableTextDocument.contentDigest(cleanData)),
                hasPendingUpload: false,
                endpointDisplayName: "web1",
                remotePath: "/etc/nginx/nginx.conf"
            ),
            in: root
        )

        // 2. Modified-on-disk folder: user edited locally before quit/debounce -> PRESERVED.
        let dirtyDiskDir = root.appendingPathComponent("dirty-disk-session", isDirectory: true)
        try fm.createDirectory(at: dirtyDiskDir, withIntermediateDirectories: true)
        let originalData = Data("PORT=8080\n".utf8)
        let editedData = Data("PORT=9090\n".utf8)
        let dirtyDiskFile = dirtyDiskDir.appendingPathComponent(".env")
        try editedData.write(to: dirtyDiskFile)
        FileEditStagingCleanup.writeManifest(
            StagingFolderManifest(
                folderName: "dirty-disk-session",
                fileName: ".env",
                lastSyncedHashHex: FileEditStagingCleanup.hexDigest(EditableTextDocument.contentDigest(originalData)),
                hasPendingUpload: false,
                endpointDisplayName: "api1",
                remotePath: "/srv/app/.env"
            ),
            in: root
        )

        // 3. Interrupted upload / conflict folder: hasPendingUpload == true -> PRESERVED.
        let pendingUploadDir = root.appendingPathComponent("pending-upload-session", isDirectory: true)
        try fm.createDirectory(at: pendingUploadDir, withIntermediateDirectories: true)
        let pendingFile = pendingUploadDir.appendingPathComponent("config.toml")
        try originalData.write(to: pendingFile)
        FileEditStagingCleanup.writeManifest(
            StagingFolderManifest(
                folderName: "pending-upload-session",
                fileName: "config.toml",
                lastSyncedHashHex: FileEditStagingCleanup.hexDigest(EditableTextDocument.contentDigest(originalData)),
                hasPendingUpload: true,
                endpointDisplayName: "api1",
                remotePath: "/srv/app/config.toml"
            ),
            in: root
        )

        // 4. Folder missing a manifest containing ONLY a hidden file (`.env`) -> PRESERVED!
        let unmanifestedHiddenDir = root.appendingPathComponent("no-manifest-hidden", isDirectory: true)
        try fm.createDirectory(at: unmanifestedHiddenDir, withIntermediateDirectories: true)
        let hiddenEnvFile = unmanifestedHiddenDir.appendingPathComponent(".env")
        try Data("SECRET=1\n".utf8).write(to: hiddenEnvFile)

        // 5. Valid manifest with matching original hash PLUS a Vim swap file -> PRESERVED!
        let vimSwapDir = root.appendingPathComponent("vim-swap-session", isDirectory: true)
        try fm.createDirectory(at: vimSwapDir, withIntermediateDirectories: true)
        let vimTargetFile = vimSwapDir.appendingPathComponent("app.conf")
        let vimSwapFile = vimSwapDir.appendingPathComponent(".app.conf.swp")
        try cleanData.write(to: vimTargetFile)
        try Data("unsaved vim buffer".utf8).write(to: vimSwapFile)
        FileEditStagingCleanup.writeManifest(
            StagingFolderManifest(
                folderName: "vim-swap-session",
                fileName: "app.conf",
                lastSyncedHashHex: FileEditStagingCleanup.hexDigest(EditableTextDocument.contentDigest(cleanData)),
                hasPendingUpload: false,
                endpointDisplayName: "web1",
                remotePath: "/etc/app.conf"
            ),
            in: root
        )

        // 6. Truly empty folder with no manifest -> PRUNED.
        let trulyEmptyDir = root.appendingPathComponent("empty-session", isDirectory: true)
        try fm.createDirectory(at: trulyEmptyDir, withIntermediateDirectories: true)

        // 7. Unreadable folder (directory listing fails) -> PRESERVED (never treated as empty).
        let unreadableDir = root.appendingPathComponent("unreadable-session", isDirectory: true)
        try fm.createDirectory(at: unreadableDir, withIntermediateDirectories: true)
        let unreadableInner = unreadableDir.appendingPathComponent("secret.conf")
        try Data("keep me\n".utf8).write(to: unreadableInner)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDir.path) }

        // 8. Orphaned manifest for an already-deleted folder -> cleaned up.
        FileEditStagingCleanup.writeManifest(
            StagingFolderManifest(
                folderName: "gone-session",
                fileName: "old.txt",
                lastSyncedHashHex: "00",
                hasPendingUpload: false,
                endpointDisplayName: "web1",
                remotePath: "/tmp/old.txt"
            ),
            in: root
        )

        let preserved = FileEditStagingCleanup.pruneSyncedFolders(in: root)

        XCTAssertFalse(fm.fileExists(atPath: cleanDir.path))
        XCTAssertFalse(fm.fileExists(atPath: trulyEmptyDir.path))
        XCTAssertFalse(fm.fileExists(atPath: FileEditStagingCleanup.manifestURL(forFolderName: "clean-session", in: root).path))
        XCTAssertFalse(fm.fileExists(atPath: FileEditStagingCleanup.manifestURL(forFolderName: "gone-session", in: root).path))

        XCTAssertTrue(fm.fileExists(atPath: dirtyDiskFile.path))
        XCTAssertTrue(fm.fileExists(atPath: pendingFile.path))
        XCTAssertTrue(fm.fileExists(atPath: hiddenEnvFile.path))
        XCTAssertTrue(fm.fileExists(atPath: vimTargetFile.path))
        XCTAssertTrue(fm.fileExists(atPath: vimSwapFile.path))
        XCTAssertTrue(fm.fileExists(atPath: unreadableDir.path))
        XCTAssertEqual(
            Set(preserved.map(\.fileName)),
            [".env", "config.toml", "app.conf", "unreadable-session"]
        )

        // Preserved Vim swap folder must expose BOTH the primary file and the hidden swap file for export.
        let vimPreserved = try XCTUnwrap(preserved.first { $0.folderURL.lastPathComponent == "vim-swap-session" })
        XCTAssertEqual(vimPreserved.files.map(\.lastPathComponent), ["app.conf", ".app.conf.swp"])

        // Clean-stop full-directory check must refuse deletion when a Vim swap file or unreadable dir is present.
        XCTAssertFalse(FileEditStagingCleanup.directoryContainsOnly("app.conf", in: vimSwapDir))
        XCTAssertFalse(FileEditStagingCleanup.directoryContainsOnly("secret.conf", in: unreadableDir))
        XCTAssertTrue(FileEditStagingCleanup.directoryContainsOnly(".env", in: dirtyDiskDir))
    }

    func testSFTPFileTypeRequiresConfirmedRegularFileMode() {
        XCTAssertEqual(SFTPFileType(permissions: 0o100644), .regularFile)
        XCTAssertEqual(SFTPFileType(permissions: 0o040755), .directory)
        XCTAssertEqual(SFTPFileType(permissions: 0o120777), .symlink)
        XCTAssertEqual(SFTPFileType(permissions: 0o010644), .other) // FIFO
        XCTAssertEqual(SFTPFileType(permissions: 0o000644), .unknown) // missing S_IFMT type bits
        XCTAssertEqual(SFTPFileType(permissions: nil), .unknown)
    }

    func testSFTPOwnershipVerificationPreventsSilentOwnerChange() {
        let wwwData = SFTPOwnership(uid: 33, gid: 1001)
        let alice = SFTPOwnership(uid: 1000, gid: 1001)
        let wwwDataOtherGroup = SFTPOwnership(uid: 33, gid: 33)

        // Replacing an existing file requires BOTH original and staged UID/GID to be reported and equal.
        XCTAssertTrue(SFTPOwnership.preservesOwnership(replacingExistingFile: true, original: wwwData, staged: wwwData))
        XCTAssertFalse(SFTPOwnership.preservesOwnership(replacingExistingFile: true, original: wwwData, staged: alice))
        XCTAssertFalse(SFTPOwnership.preservesOwnership(replacingExistingFile: true, original: wwwData, staged: wwwDataOtherGroup))
        XCTAssertFalse(SFTPOwnership.preservesOwnership(replacingExistingFile: true, original: wwwData, staged: nil))
        XCTAssertFalse(SFTPOwnership.preservesOwnership(replacingExistingFile: true, original: nil, staged: alice))
        XCTAssertFalse(SFTPOwnership.preservesOwnership(replacingExistingFile: true, original: nil, staged: nil))

        // Creating a brand-new file has no prior owner to preserve.
        XCTAssertTrue(SFTPOwnership.preservesOwnership(replacingExistingFile: false, original: nil, staged: alice))
        XCTAssertTrue(SFTPOwnership.preservesOwnership(replacingExistingFile: false, original: nil, staged: nil))
    }

    func testSFTPPermissionsVerificationPreventsConcurrentChmodUndo() {
        // Matching mode bits (with or without S_IFREG type bits) pass.
        XCTAssertTrue(SFTPPermissions.preservesPermissions(replacingExistingFile: true, original: 0o100644, staged: 0o644))
        XCTAssertTrue(SFTPPermissions.preservesPermissions(replacingExistingFile: true, original: 0o100640, staged: 0o100640))

        // Concurrent `chmod 0644 -> 0600` or omitted permissions on an existing file MUST fail.
        XCTAssertFalse(SFTPPermissions.preservesPermissions(replacingExistingFile: true, original: 0o100600, staged: 0o100644))
        XCTAssertFalse(SFTPPermissions.preservesPermissions(replacingExistingFile: true, original: 0o100640, staged: nil))
        XCTAssertFalse(SFTPPermissions.preservesPermissions(replacingExistingFile: true, original: nil, staged: 0o100640))

        // Brand-new file creation has no prior permissions to match.
        XCTAssertTrue(SFTPPermissions.preservesPermissions(replacingExistingFile: false, original: nil, staged: 0o600))

        // Private staging verification must explicitly confirm group/other bits are zero and reject nil.
        XCTAssertTrue(SFTPPermissions.isPrivateStagingMode(0o100600))
        XCTAssertTrue(SFTPPermissions.isPrivateStagingMode(0o600))
        XCTAssertTrue(SFTPPermissions.isPrivateStagingMode(0o400))
        XCTAssertFalse(SFTPPermissions.isPrivateStagingMode(0o100640))
        XCTAssertFalse(SFTPPermissions.isPrivateStagingMode(0o100604))
        XCTAssertFalse(SFTPPermissions.isPrivateStagingMode(0o100644))
        XCTAssertFalse(SFTPPermissions.isPrivateStagingMode(nil))
    }

    // MARK: - Interrupted SFTP Swap Recovery Store

    func testRecoveryKeyDistinguishesJumpChainsAndSudoScope() {
        let direct = FileEditRecoveryKey.ssh(
            host: "10.0.0.5",
            port: 22,
            username: "root",
            isSudo: false,
            jumpHops: []
        )
        let viaBastionA = FileEditRecoveryKey.ssh(
            host: "10.0.0.5",
            port: 22,
            username: "root",
            isSudo: false,
            jumpHops: [.init(host: "bastion-a.example.com", port: 22, username: "ops")]
        )
        let viaBastionB = FileEditRecoveryKey.ssh(
            host: "10.0.0.5",
            port: 22,
            username: "root",
            isSudo: false,
            jumpHops: [.init(host: "bastion-b.example.com", port: 22, username: "ops")]
        )
        let sudoDirect = FileEditRecoveryKey.ssh(
            host: "10.0.0.5",
            port: 22,
            username: "root",
            isSudo: true,
            jumpHops: []
        )
        let sameCaseInsensitive = FileEditRecoveryKey.ssh(
            host: "10.0.0.5",
            port: 22,
            username: "root",
            isSudo: false,
            jumpHops: [.init(host: "BASTION-A.EXAMPLE.COM", port: 22, username: "ops")]
        )

        XCTAssertNotEqual(direct, viaBastionA)
        XCTAssertNotEqual(viaBastionA, viaBastionB)
        XCTAssertNotEqual(direct, sudoDirect)
        XCTAssertEqual(viaBastionA, sameCaseInsensitive)
    }

    func testRecoveryStorePersistsAndClearsSwapRecords() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("recovery.json")

        let record = PendingSFTPSwapRecord(
            endpointKey: "ssh:example.com:22:root",
            targetPath: "/etc/nginx/nginx.conf",
            backupPath: "/etc/nginx/.nginx.conf.rootshell-bak-1234",
            tempPath: "/etc/nginx/.nginx.conf.rootshell-tmp-1234"
        )
        let otherHostRecord = PendingSFTPSwapRecord(
            endpointKey: "ssh:other.example.com:22:root",
            targetPath: "/etc/nginx/nginx.conf",
            backupPath: "/etc/nginx/.nginx.conf.rootshell-bak-5678",
            tempPath: "/etc/nginx/.nginx.conf.rootshell-tmp-5678"
        )

        let writer = RemoteSaveRecoveryStore(fileURL: storeURL)
        try await writer.record(record)
        try await writer.record(otherHostRecord)

        // Fresh store instance simulates an app relaunch / reconnect.
        let reloaded = RemoteSaveRecoveryStore(fileURL: storeURL)
        let fetched = await reloaded.record(forEndpointKey: record.endpointKey, targetPath: record.targetPath)
        XCTAssertEqual(fetched, record)
        let allForEndpoint = await reloaded.allRecords(forEndpointKey: record.endpointKey)
        XCTAssertEqual(allForEndpoint, [record])

        await reloaded.clear(endpointKey: record.endpointKey, targetPath: record.targetPath)
        let afterClear = await RemoteSaveRecoveryStore(fileURL: storeURL).record(
            forEndpointKey: record.endpointKey,
            targetPath: record.targetPath
        )
        XCTAssertNil(afterClear)
        let remainingOther = await RemoteSaveRecoveryStore(fileURL: storeURL).record(
            forEndpointKey: otherHostRecord.endpointKey,
            targetPath: otherHostRecord.targetPath
        )
        XCTAssertEqual(remainingOther, otherHostRecord)
    }

    func testRecoveryStoreThrowsWhenJournalCannotBeWritten() async throws {
        // Place a regular file where the journal's parent directory would need to be created,
        // guaranteeing persistence fails instead of silently continuing with an in-memory record.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blockingFile = dir.appendingPathComponent("not-a-dir", isDirectory: false)
        try Data("x".utf8).write(to: blockingFile)
        let unwritableStoreURL = blockingFile.appendingPathComponent("recovery.json")

        let store = RemoteSaveRecoveryStore(fileURL: unwritableStoreURL)
        let record = PendingSFTPSwapRecord(
            endpointKey: "ssh:example.com:22:root",
            targetPath: "/etc/hosts",
            backupPath: "/etc/.hosts.rootshell-bak-1",
            tempPath: "/etc/.hosts.rootshell-tmp-1"
        )

        do {
            try await store.record(record)
            XCTFail("Expected RemoteSaveRecoveryStore.record(_:) to throw when journal path cannot be written")
        } catch {
            // Expected: in-memory state must remain untouched when disk write fails.
            let stored = await store.record(forEndpointKey: record.endpointKey, targetPath: record.targetPath)
            XCTAssertNil(stored)
        }
    }

    func testPathOperationGateSerializesSamePath() async {
        let gate = SFTPPathOperationGate()
        actor Trace {
            var events: [String] = []
            func append(_ event: String) { events.append(event) }
            func snapshot() -> [String] { events }
        }
        let trace = Trace()

        async let first: Void = gate.withLock(endpointKey: "ep", targetPath: "/a") {
            await trace.append("enter-1")
            try? await Task.sleep(for: .milliseconds(40))
            await trace.append("exit-1")
        }
        try? await Task.sleep(for: .milliseconds(10))
        async let second: Void = gate.withLock(endpointKey: "ep", targetPath: "/a") {
            await trace.append("enter-2")
            await trace.append("exit-2")
        }
        _ = await (first, second)

        let events = await trace.snapshot()
        XCTAssertEqual(events, ["enter-1", "exit-1", "enter-2", "exit-2"])
    }

    func testStagedTempStoreTracksActiveAndRetainsOrphansAcrossReconnect() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("staged-temps.json")

        let activeRec = PendingSFTPTempRecord(
            endpointKey: "ssh:example.com:22:root",
            targetPath: "/etc/nginx/nginx.conf",
            tempPath: "/etc/nginx/.nginx.conf.rootshell-tmp-1111"
        )
        let failedCleanupRec = PendingSFTPTempRecord(
            endpointKey: "ssh:example.com:22:root",
            targetPath: "/etc/nginx/nginx.conf",
            tempPath: "/etc/nginx/.nginx.conf.rootshell-tmp-2222"
        )

        let store = RemoteStagedTempStore(fileURL: storeURL)
        try await store.trackActive(activeRec)
        try await store.trackActive(failedCleanupRec)

        // While active in-process, neither record may be reported as orphaned.
        let orphansWhileActive = await store.orphanedRecords(forEndpointKey: activeRec.endpointKey)
        XCTAssertTrue(orphansWhileActive.isEmpty)

        // Simulating a disconnect during cleanup: active mark released, persisted record kept.
        await store.releaseActiveKeepingRecord(endpointKey: failedCleanupRec.endpointKey, tempPath: failedCleanupRec.tempPath)
        let orphansAfterRelease = await store.orphanedRecords(forEndpointKey: activeRec.endpointKey)
        XCTAssertEqual(orphansAfterRelease, [failedCleanupRec])

        // Simulating an app relaunch: BOTH previously tracked temp paths become eligible for reconnect cleanup.
        let relaunched = RemoteStagedTempStore(fileURL: storeURL)
        let orphansAfterRelaunch = await relaunched.orphanedRecords(forEndpointKey: activeRec.endpointKey)
        XCTAssertEqual(Set(orphansAfterRelaunch.map(\.tempPath)), [activeRec.tempPath, failedCleanupRec.tempPath])

        // Confirming removal clears only that record from disk.
        await relaunched.markCompleted(endpointKey: failedCleanupRec.endpointKey, tempPath: failedCleanupRec.tempPath)
        let remaining = await RemoteStagedTempStore(fileURL: storeURL).orphanedRecords(forEndpointKey: activeRec.endpointKey)
        XCTAssertEqual(remaining, [activeRec])
    }

    func testRecoveryStoreStrictTempLookupThrowsWhenJournalUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let corruptURL = dir.appendingPathComponent("recovery.json")
        try Data("{corrupt json".utf8).write(to: corruptURL)

        let store = RemoteSaveRecoveryStore(fileURL: corruptURL)
        do {
            _ = try await store.referencesTempPathStrict(
                endpointKey: "ssh:example.com:22:root",
                tempPath: "/etc/.hosts.rootshell-tmp-1"
            )
            XCTFail("Expected referencesTempPathStrict to throw when swap journal cannot be decoded")
        } catch {
            // Expected: reconnect temp cleanup must defer deletion when swap journal is unreadable.
        }
    }

    func testRecoveryStoreDoesNotCacheInaccessibleDirectoryAsEmpty() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("recovery.json")

        let record = PendingSFTPSwapRecord(
            endpointKey: "ssh:example.com:22:root",
            targetPath: "/etc/hosts",
            backupPath: "/etc/.hosts.rootshell-bak-1",
            tempPath: "/etc/.hosts.rootshell-tmp-1"
        )
        try await RemoteSaveRecoveryStore(fileURL: storeURL).record(record)

        // Make parent directory temporarily inaccessible.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        let store = RemoteSaveRecoveryStore(fileURL: storeURL)
        // Best-effort call during outage MUST NOT cache empty state.
        let duringOutage = await store.allRecords(forEndpointKey: record.endpointKey)
        XCTAssertTrue(duringOutage.isEmpty)
        do {
            _ = try await store.referencesTempPathStrict(endpointKey: record.endpointKey, tempPath: record.tempPath)
            XCTFail("Expected strict lookup to throw while journal directory is inaccessible")
        } catch {
            // Expected permission error, NOT missing file.
        }

        // Restore directory access: same store instance MUST retry loading and see the real record.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let referenced = try await store.referencesTempPathStrict(endpointKey: record.endpointKey, tempPath: record.tempPath)
        XCTAssertTrue(referenced)
        let fetched = await store.record(forEndpointKey: record.endpointKey, targetPath: record.targetPath)
        XCTAssertEqual(fetched, record)
    }

    func testPendingSwapRecordCodableRoundTripsStagedFingerprintAndLegacyJSON() throws {
        let staged = RemoteFileFingerprint(size: 512, modified: Date(timeIntervalSince1970: 1_700_000_123))
        let record = PendingSFTPSwapRecord(
            endpointKey: "ssh:example.com:22:root",
            targetPath: "/etc/nginx/nginx.conf",
            backupPath: "/etc/nginx/.nginx.conf.rootshell-bak-1",
            tempPath: "/etc/nginx/.nginx.conf.rootshell-tmp-1",
            stagedFingerprint: staged
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PendingSFTPSwapRecord.self, from: encoded)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.stagedFingerprint, staged)

        // Legacy journal records written before stagedFingerprint existed must still decode safely.
        let legacyJSON = """
        {"endpointKey":"ssh:example.com:22:root","targetPath":"/etc/hosts","backupPath":"/etc/.hosts.bak","tempPath":"/etc/.hosts.tmp"}
        """
        let legacy = try JSONDecoder().decode(PendingSFTPSwapRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.stagedFingerprint)
    }

    func testRecoveryPlannerPreservesBothCopiesOnAmbiguousConflict() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_100)
        let t1 = Date(timeIntervalSince1970: 1_700_000_105)
        let staged = RemoteFileFingerprint(size: 200, modified: t0)
        let differentSize = RemoteFileFingerprint(size: 205, modified: t0)
        let differentTime = RemoteFileFingerprint(size: 200, modified: t1)
        let noMtime = RemoteFileFingerprint(size: 200, modified: nil)

        // 1. Target missing + backup present => safe to restore backup.
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .missing, backupExists: true, tempExists: true, stagedFingerprint: staged),
            .restoreBackup
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .missing, backupExists: true, tempExists: false, stagedFingerprint: nil),
            .restoreBackup
        )

        // 2. Backup absent => swap never moved original or already deleted backup.
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(differentSize), backupExists: false, tempExists: true, stagedFingerprint: staged),
            .clearOnly(removeTemp: true)
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(staged), backupExists: false, tempExists: false, stagedFingerprint: staged),
            .clearOnly(removeTemp: false)
        )

        // 3. Another process created target while original was at backup (temp STILL exists):
        //    MUST NOT delete backup or temp even if size/mtime happen to coincide.
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(staged), backupExists: true, tempExists: true, stagedFingerprint: staged),
            .conflict(hasStagedCopy: true)
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(differentSize), backupExists: true, tempExists: true, stagedFingerprint: staged),
            .conflict(hasStagedCopy: true)
        )

        // 4. Both target and backup exist, temp gone, but target does not prove it is our staged edit:
        //    MUST preserve backup and report conflict.
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(differentSize), backupExists: true, tempExists: false, stagedFingerprint: staged),
            .conflict(hasStagedCopy: false)
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(differentTime), backupExists: true, tempExists: false, stagedFingerprint: staged),
            .conflict(hasStagedCopy: false)
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(staged), backupExists: true, tempExists: false, stagedFingerprint: nil),
            .conflict(hasStagedCopy: false)
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(noMtime), backupExists: true, tempExists: false, stagedFingerprint: noMtime),
            .conflict(hasStagedCopy: false)
        )
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .other, backupExists: true, tempExists: false, stagedFingerprint: staged),
            .conflict(hasStagedCopy: false)
        )

        // 5. Temp consumed AND target is a regular file matching verified staged size & mtime:
        //    safe to remove redundant backup and clear journal.
        XCTAssertEqual(
            SFTPRecoveryPlanner.decide(target: .regularFile(staged), backupExists: true, tempExists: false, stagedFingerprint: staged),
            .finalizeInstalledEdit
        )
    }

    // MARK: - Byte-exact Remote Path Identity

    func testRemoteEditPathIdentityDistinguishesNFCAndNFDKeys() {
        let nfc = "/bucket/caf\u{00E9}.txt"
        let nfd = "/bucket/cafe\u{0301}.txt"
        XCTAssertEqual(nfc, nfd, "precondition: Swift String equates NFC and NFD")
        XCTAssertFalse(RemoteEditPathIdentity.matches(nfc, nfd))
        XCTAssertTrue(RemoteEditPathIdentity.matches(nfc, nfc))
        XCTAssertTrue(RemoteEditPathIdentity.matches(nfd, nfd))
        XCTAssertNotEqual(
            RemoteEditPathIdentity.key(endpointKey: "s3:ceph", path: nfc),
            RemoteEditPathIdentity.key(endpointKey: "s3:ceph", path: nfd)
        )
    }

    // MARK: - JSON Formatting

    func testJSONPrettyPrint() throws {
        let formatted = try FileEditJSONFormatter.prettyPrint("{\"b\":2,\"a\":[1,true,null]}")
        XCTAssertTrue(formatted.contains("\"a\" : ["))
        XCTAssertTrue(formatted.hasSuffix("\n"))
        XCTAssertThrowsError(try FileEditJSONFormatter.prettyPrint("{invalid"))
    }

    // MARK: - Syntax Detection & Highlighting

    func testSyntaxLanguageDetection() {
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: ".env.local"), .dotenv)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "Dockerfile.prod"), .dockerfile)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "nginx.conf"), .ini)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "Cargo.toml"), .toml)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "docker-compose.yml"), .yaml)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "settings.json"), .json)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "Makefile"), .makefile)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "run", contentPrefix: "#!/usr/bin/env bash\necho hi"), .shell)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "tool", contentPrefix: "#!/usr/bin/env python3\nimport sys"), .hashCode)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "payload", contentPrefix: "{\n  \"ok\": true\n}"), .json)
        XCTAssertEqual(FileEditorSyntax.detectLanguage(fileName: "feed", contentPrefix: "<?xml version=\"1.0\"?>"), .markup)
    }

    func testSyntaxTokenizerProducesValidUTF16Spans() {
        let samples: [(FileEditorSyntax.Language, String, [FileEditorSyntax.Token])] = [
            (.json, "{\n  \"name\": \"🚀 app\",\n  \"port\": 8080,\n  \"tls\": true // ok\n}\n", [.key, .string, .number, .keyword, .comment]),
            (.dotenv, "# comment\nexport API_URL=\"https://example.com\"\nTOKEN=$SECRET # inline\n", [.comment, .keyword, .key, .string, .variable]),
            (.toml, "[server]\nhost = \"0.0.0.0\"\nport = 443 # https\n", [.section, .key, .string, .number, .comment]),
            (.yaml, "# config\nname: \"web\"\nreplicas: 3\nenabled: true\n", [.comment, .key, .string, .number, .keyword]),
            (.dockerfile, "# build\nFROM alpine:3.20\nENV PORT=$APP_PORT\nRUN echo \"hi\"\n", [.comment, .keyword, .variable, .string]),
            (.ini, "[Unit]\nDescription=Web\n# nginx\nworker_processes 4;\n", [.section, .key, .comment, .keyword, .number]),
        ]

        for (language, text, expectedTokens) in samples {
            let utf16Length = (text as NSString).length
            let spans = FileEditorSyntax.highlight(text, language: language)
            XCTAssertFalse(spans.isEmpty, "Expected non-empty spans for \(language)")
            for span in spans {
                XCTAssertGreaterThanOrEqual(span.location, 0)
                XCTAssertGreaterThan(span.length, 0)
                XCTAssertLessThanOrEqual(span.location + span.length, utf16Length)
            }
            let found = Set(spans.map(\.token))
            for expected in expectedTokens {
                XCTAssertTrue(found.contains(expected), "Expected token \(expected) in \(language)")
            }
        }
    }

    // MARK: - Editor Preferences & Embedded Editors

    func testEditorPreferenceResolvesPerPlatform() {
        XCTAssertEqual(FileManagerEditorPreference.inApp.resolved(isMacCatalyst: true), .inApp)
        XCTAssertEqual(FileManagerEditorPreference.external.resolved(isMacCatalyst: true), .external)
        XCTAssertEqual(FileManagerEditorPreference.vim.resolved(isMacCatalyst: true), .inApp)
        XCTAssertEqual(FileManagerEditorPreference.hx.resolved(isMacCatalyst: true), .inApp)

        XCTAssertEqual(FileManagerEditorPreference.inApp.resolved(isMacCatalyst: false), .inApp)
        XCTAssertEqual(FileManagerEditorPreference.vim.resolved(isMacCatalyst: false), .vim)
        XCTAssertEqual(FileManagerEditorPreference.hx.resolved(isMacCatalyst: false), .hx)
        XCTAssertEqual(FileManagerEditorPreference.external.resolved(isMacCatalyst: false), .inApp)

        XCTAssertEqual(FileManagerEditorPreference.vim.embeddedEditor, .vim)
        XCTAssertEqual(FileManagerEditorPreference.hx.embeddedEditor, .hx)
        XCTAssertNil(FileManagerEditorPreference.inApp.embeddedEditor)
        XCTAssertEqual(FileManagerEmbeddedEditor.vim.command, "vim")
        XCTAssertEqual(FileManagerEmbeddedEditor.hx.command, "hx")
    }
}
