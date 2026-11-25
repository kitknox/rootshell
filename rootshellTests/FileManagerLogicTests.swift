import XCTest

final class FileManagerLogicTests: XCTestCase {

    // MARK: - Paths

    func testJoinAndParent() {
        XCTAssertEqual(FileTransferLogic.join("/", "a"), "/a")
        XCTAssertEqual(FileTransferLogic.join("/a/", "b"), "/a/b")
        XCTAssertEqual(FileTransferLogic.join("/a", "/b"), "/a/b")
        XCTAssertEqual(FileTransferLogic.parent(of: "/a/b"), "/a")
        XCTAssertEqual(FileTransferLogic.parent(of: "/a"), "/")
        XCTAssertEqual(FileTransferLogic.parent(of: "/a/b/"), "/a")
        XCTAssertEqual(FileTransferLogic.lastComponent(of: "/a/b/"), "b")
    }

    func testDifferingSpellings() {
        func pairs(_ a: String, _ b: String) -> [String] {
            FileTransferLogic.differingSpellings(a, b).map { "\($0.0)|\($0.1)" }
        }
        XCTAssertEqual(pairs("/d/A.txt", "/d/a.txt"), ["A|a"])
        // Long names probe only the differing characters, each distinct pair once.
        let long = String(repeating: "x", count: 240)
        XCTAssertEqual(pairs("/d/\(long)A", "/d/\(long)a"), ["A|a"])
        XCTAssertEqual(pairs("/d/AbA", "/d/aBa"), ["A|a", "b|B"])
        // Ancestors count too.
        XCTAssertEqual(pairs("/shared/A/f", "/shared/a/f"), ["A|a"])
        // Unicode spellings String equality would call equal.
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        XCTAssertEqual(FileTransferLogic.differingSpellings("/\(nfc)", "/\(nfd)").map { Array($0.0.unicodeScalars) + Array($0.1.unicodeScalars) },
                       [Array("\u{E9}e\u{301}".unicodeScalars)])
        // Length-changing folds pair up by folding, not position, and stay short.
        XCTAssertEqual(pairs("/strasse-ß.txt", "/strasse-SS.txt"), ["ß|SS"])
        XCTAssertEqual(pairs("/ßSS", "/SSß"), ["ß|SS", "SS|ß"])
        XCTAssertEqual(pairs("/d/" + String(repeating: "ß", count: 120), "/d/" + String(repeating: "S", count: 240)), ["ß|SS"])
        XCTAssertEqual(pairs("/ﬃx", "/FFIX"), ["ﬃ|FFI", "x|X"])
        XCTAssertEqual(pairs("/d/same", "/d/same"), [])
    }

    func testSingleComponent() {
        XCTAssertTrue(FileTransferLogic.isSingleComponent("picture.png"))
        XCTAssertTrue(FileTransferLogic.isSingleComponent("..hidden"))
        XCTAssertFalse(FileTransferLogic.isSingleComponent(""))
        XCTAssertFalse(FileTransferLogic.isSingleComponent("."))
        XCTAssertFalse(FileTransferLogic.isSingleComponent(".."))
        XCTAssertFalse(FileTransferLogic.isSingleComponent("../../Documents/important.txt"))
        XCTAssertFalse(FileTransferLogic.isSingleComponent("/etc"))
        XCTAssertFalse(FileTransferLogic.isSingleComponent("a\0b"))
    }

    func testNormalize() {
        XCTAssertEqual(FileTransferLogic.normalize(""), "/")
        XCTAssertEqual(FileTransferLogic.normalize("a//b/"), "/a/b")
        XCTAssertEqual(FileTransferLogic.normalize("/a/./b/../c"), "/a/c")
        XCTAssertEqual(FileTransferLogic.normalize("/../.."), "/")
    }

    func testDestinationMapping() {
        XCTAssertEqual(FileTransferLogic.destination(for: "/src/dir", sourceRoot: "/src/dir", destinationRoot: "/dst/dir"), "/dst/dir")
        XCTAssertEqual(FileTransferLogic.destination(for: "/src/dir/x/y.txt", sourceRoot: "/src/dir", destinationRoot: "/dst/dir"), "/dst/dir/x/y.txt")
        // A sibling that merely shares a prefix is not inside the root.
        XCTAssertEqual(FileTransferLogic.destination(for: "/src/dir2/y", sourceRoot: "/src/dir", destinationRoot: "/dst"), "/dst/y")
    }

    func testSameOrDescendant() {
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("/a/b", of: "/a/b"))
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("/a/b/c", of: "/a/b"))
        XCTAssertTrue(
            FileTransferLogic.isSameOrDescendant("/a/b/\u{0301}report", of: "/a/b"),
            "a child beginning with a combining mark after '/' must still match as a descendant"
        )
        XCTAssertFalse(FileTransferLogic.isSameOrDescendant("/a/bc", of: "/a/b"))

        // Conservative (default) comparison treats NFC/NFD as overlapping for APFS/HFS+,
        // while exactBytes: true keeps byte-distinct S3/Ceph folders separate so NFC -> NFD
        // renames and cross-folder moves are not falsely blocked as move-into-self.
        let nfc = "/bucket/caf\u{00E9}"
        let nfd = "/bucket/cafe\u{0301}"
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant(nfd, of: nfc))
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("\(nfd)/sub", of: nfc))
        XCTAssertFalse(FileTransferLogic.isSameOrDescendant(nfd, of: nfc, exactBytes: true))
        XCTAssertFalse(FileTransferLogic.isSameOrDescendant("\(nfd)/sub", of: nfc, exactBytes: true))
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant(nfc, of: nfc, exactBytes: true))
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("\(nfc)/sub", of: nfc, exactBytes: true))
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("\(nfc)/\u{0301}sub", of: nfc, exactBytes: true))
    }

    func testByteLevelSlashBoundariesWithCombiningMarks() {
        let combiningPath = "/bucket/dir/\u{0301}report"
        XCTAssertEqual(
            Array(FileTransferLogic.lastComponent(of: combiningPath).utf8),
            Array("\u{0301}report".utf8),
            "slash followed by a combining mark must not fuse into a single Swift Character"
        )
        XCTAssertEqual(FileTransferLogic.lastComponent(of: "/bucket/dir/\u{0301}report/"), "\u{0301}report")
        XCTAssertEqual(FileTransferLogic.parent(of: combiningPath), "/bucket/dir")
        XCTAssertEqual(FileTransferLogic.parent(of: "/bucket/dir/\u{0301}report/"), "/bucket/dir")
        XCTAssertEqual(FileTransferLogic.parent(of: "/\u{0301}report"), "/")
        XCTAssertEqual(FileTransferLogic.pathComponents(of: combiningPath), ["bucket", "dir", "\u{0301}report"])
        XCTAssertEqual(FileTransferLogic.pathComponents(of: "/bucket/\u{0301}report"), ["bucket", "\u{0301}report"])
        XCTAssertEqual(FileTransferLogic.normalize("/bucket/dir//\u{0301}report/"), combiningPath)
        XCTAssertEqual(FileTransferLogic.join("/bucket/out", "\u{0301}report"), "/bucket/out/\u{0301}report")
        XCTAssertEqual(FileTransferLogic.join("/bucket/out/", "/\u{0301}report"), "/bucket/out/\u{0301}report")
        XCTAssertEqual(
            FileTransferLogic.destination(for: combiningPath, sourceRoot: "/bucket/dir", destinationRoot: "/bucket/out"),
            "/bucket/out/\u{0301}report"
        )
        XCTAssertEqual(
            FileTransferLogic.destination(for: combiningPath, sourceRoot: combiningPath, destinationRoot: "/bucket/out/\u{0301}report"),
            "/bucket/out/\u{0301}report"
        )
        XCTAssertFalse(FileTransferLogic.isSingleComponent("/\u{0301}evil"))
        XCTAssertFalse(FileTransferLogic.isSingleComponent("a/\u{0301}b"))
        XCTAssertTrue(FileTransferLogic.isSingleComponent("\u{0301}report"))
        let filled = FileTransferLogic.implicitPopulatedFolderBytes(fileDestinations: [combiningPath])
        XCTAssertTrue(filled.contains(FileTransferLogic.folderBytesKey("/bucket/dir")))
    }

    // MARK: - Keep both

    func testKeepBothNames() {
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "report.pdf", existing: ["report.pdf"]), "report 2.pdf")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "report.pdf", existing: ["report.pdf", "report 2.pdf"]), "report 3.pdf")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "backup.tar.gz", existing: []), "backup 2.tar.gz")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: ".bashrc", existing: []), ".bashrc 2")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "Makefile", existing: []), "Makefile 2")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: ".config.yml", existing: []), ".config 2.yml")
    }

    func testKeepBothSkipsNamesOtherItemsInTheJobWillTake() {
        // Destination holds a.txt; the job brings a.txt and "a 2.txt".
        var names = TransferNamePlanner(incomingNames: ["a.txt", "a 2.txt"])
        XCTAssertEqual(names.claimKeepBothName(for: "a.txt", existingOnDisk: ["a.txt"]), "a 3.txt")
        XCTAssertFalse(names.isClaimed("a 2.txt"))
        names.claim("a 2.txt")
        XCTAssertEqual(names.claimKeepBothName(for: "a.txt", existingOnDisk: ["a.txt"]), "a 4.txt")
    }

    func testDuplicateIncomingNamesAreClaimed() {
        var names = TransferNamePlanner(incomingNames: ["x", "x"])
        XCTAssertFalse(names.isClaimed("x"))
        names.claim("x")
        XCTAssertTrue(names.isClaimed("x"))
        XCTAssertEqual(names.claimKeepBothName(for: "x", existingOnDisk: []), "x 2")
    }

    func testTransferNamePlannerPreservesExactBytesAndTypeOnS3() {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        var s3Names = TransferNamePlanner(
            incomingEntries: [
                (name: "foo", isDirectory: true),
                (name: "foo", isDirectory: false),
                (name: nfc, isDirectory: false),
                (name: nfd, isDirectory: false),
            ],
            separatesByExactBytesAndType: true
        )

        // Same-named folder and file do not collide on S3 destinations.
        XCTAssertFalse(s3Names.isClaimed("foo", isDirectory: true))
        s3Names.claim("foo", isDirectory: true)
        XCTAssertFalse(s3Names.isClaimed("foo", isDirectory: false))
        s3Names.claim("foo", isDirectory: false)
        XCTAssertTrue(s3Names.isClaimed("foo", isDirectory: true))
        XCTAssertTrue(s3Names.isClaimed("foo", isDirectory: false))

        // Byte-distinct NFC and NFD siblings both keep their original names on S3.
        XCTAssertFalse(s3Names.isClaimed(nfc, isDirectory: false))
        s3Names.claim(nfc, isDirectory: false)
        XCTAssertFalse(s3Names.isClaimed(nfd, isDirectory: false))
        s3Names.claim(nfd, isDirectory: false)

        // Keep Both on S3 only skips collisions matching both exact bytes and entry type.
        let existing: Set<TransferNamePlanner.EntryKey> = [
            .init(name: "foo 2", isDirectory: true),
            .init(name: "foo", isDirectory: false),
        ]
        XCTAssertEqual(
            s3Names.claimKeepBothName(for: "foo", isDirectory: false, existingEntries: existing),
            "foo 2",
            "an existing folder named 'foo 2/' does not block a file named 'foo 2' on S3"
        )
        XCTAssertEqual(
            s3Names.claimKeepBothName(for: "foo", isDirectory: true, existingEntries: existing),
            "foo 3",
            "an existing folder named 'foo 2/' blocks another folder named 'foo 2/'"
        )
    }

    func testImplicitPopulatedFolderBytesDistinguishesNFCAndNFD() {
        let nfcDir = "/bucket/caf\u{00E9}"
        let nfdDir = "/bucket/cafe\u{0301}"
        let filled = FileTransferLogic.implicitPopulatedFolderBytes(
            fileDestinations: ["\(nfdDir)/a.txt"]
        )
        XCTAssertTrue(filled.contains(FileTransferLogic.folderBytesKey(nfdDir)))
        XCTAssertTrue(filled.contains(FileTransferLogic.folderBytesKey("/bucket")))
        XCTAssertFalse(
            filled.contains(FileTransferLogic.folderBytesKey(nfcDir)),
            "a populated NFD folder must not suppress an empty NFC sibling's folder marker"
        )
    }

    func testPathsOverlapEitherDirection() {
        XCTAssertTrue(FileTransferLogic.pathsOverlap("/d", "/d"))
        XCTAssertTrue(FileTransferLogic.pathsOverlap("/d", "/d/x"))
        XCTAssertTrue(FileTransferLogic.pathsOverlap("/d/x", "/d"))
        XCTAssertFalse(FileTransferLogic.pathsOverlap("/d/x", "/d/y"))
        XCTAssertFalse(FileTransferLogic.pathsOverlap("/d", "/dx"))
    }

    func testReplacingAnAncestorIsDetected() {
        // Moving /a/b/b into /a targets /a/b, which contains the source.
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("/a/b/b", of: "/a/b"))
        XCTAssertFalse(FileTransferLogic.isSameOrDescendant("/a/bb", of: "/a/b"))
    }

    func testS3MultiTenantOverlapGuards() {
        XCTAssertTrue(FileTransferLogic.s3BucketsMayAlias("logs", "logs"))
        XCTAssertTrue(FileTransferLogic.s3BucketsMayAlias("tenantB:logs", "logs"))
        XCTAssertTrue(FileTransferLogic.s3BucketsMayAlias("logs", "tenantB:logs"))
        XCTAssertFalse(FileTransferLogic.s3BucketsMayAlias("tenantA:logs", "tenantB:logs"))
        XCTAssertFalse(FileTransferLogic.s3BucketsMayAlias("logs", "archive"))

        XCTAssertTrue(FileTransferLogic.s3PathsMayAlias("/logs/in/report", "/logs/in/report"))
        XCTAssertTrue(FileTransferLogic.s3PathsMayAlias("/tenantB:logs/in/report", "/logs/in/report"))
        XCTAssertFalse(FileTransferLogic.s3PathsMayAlias("/logs/in/report", "/logs/archive/report"))
        XCTAssertFalse(FileTransferLogic.s3PathsMayAlias("/tenantA:logs/in/report", "/tenantB:logs/in/report"))
        XCTAssertFalse(FileTransferLogic.s3PathsMayAlias("/logs/caf\u{00E9}", "/logs/cafe\u{0301}"))

        XCTAssertTrue(FileTransferLogic.s3IsSameOrDescendantAssumingPossibleTenantAlias("/logs/dir/sub", of: "/tenantB:logs/dir"))
        XCTAssertTrue(FileTransferLogic.s3IsSameOrDescendantAssumingPossibleTenantAlias("/logs/dir/\u{0301}sub", of: "/tenantB:logs/dir"))
        XCTAssertFalse(FileTransferLogic.s3IsSameOrDescendantAssumingPossibleTenantAlias("/logs/archive", of: "/logs/in"))
        XCTAssertFalse(FileTransferLogic.s3IsSameOrDescendantAssumingPossibleTenantAlias("/logs/cafe\u{0301}", of: "/logs/caf\u{00E9}"))
    }

    // MARK: - Rate and throttle

    func testRateMeterSmoothsAndEstimates() {
        var meter = TransferRateMeter()
        XCTAssertNil(meter.eta(remainingBytes: 100))
        meter.record(totalBytes: 0, at: 0)
        meter.record(totalBytes: 1_000, at: 1)
        XCTAssertEqual(meter.bytesPerSecond, 1_000, accuracy: 0.001)
        meter.record(totalBytes: 3_000, at: 2)
        // 0.3 × 2000 + 0.7 × 1000
        XCTAssertEqual(meter.bytesPerSecond, 1_300, accuracy: 0.001)
        XCTAssertEqual(meter.eta(remainingBytes: 2_600) ?? 0, 2, accuracy: 0.001)
    }

    func testRateMeterIgnoresBackwardsSamples() {
        var meter = TransferRateMeter()
        meter.record(totalBytes: 500, at: 1)
        meter.record(totalBytes: 100, at: 2)
        XCTAssertEqual(meter.bytesPerSecond, 0)
    }

    func testPublishThrottle() {
        var throttle = PublishThrottle(interval: 0.1)
        XCTAssertTrue(throttle.shouldPublish(at: 0))
        XCTAssertFalse(throttle.shouldPublish(at: 0.05))
        XCTAssertTrue(throttle.shouldPublish(at: 0.05, force: true))
        XCTAssertFalse(throttle.shouldPublish(at: 0.1))
        XCTAssertTrue(throttle.shouldPublish(at: 0.16))
    }

    // MARK: - Selection

    private let paths = ["/a", "/b", "/c", "/d"]

    func testCursorMovesAndClamps() {
        var selection = FileListSelection()
        selection.moveCursor(by: 1, in: paths, extending: false)
        XCTAssertEqual(selection.cursor, "/a")
        selection.moveCursor(by: 10, in: paths, extending: false)
        XCTAssertEqual(selection.cursor, "/d")
        selection.moveCursor(by: -1, in: paths, extending: false)
        XCTAssertEqual(selection.cursor, "/c")
        XCTAssertTrue(selection.isEmpty)
    }

    func testShiftExtendsAndShrinksFromAnchor() {
        var selection = FileListSelection()
        selection.setCursor("/b")
        selection.moveCursor(by: 1, in: paths, extending: true)
        selection.moveCursor(by: 1, in: paths, extending: true)
        XCTAssertEqual(selection.selected, ["/b", "/c", "/d"])
        selection.moveCursor(by: -1, in: paths, extending: true)
        XCTAssertEqual(selection.selected, ["/b", "/c"])
    }

    func testClickModifiers() {
        var selection = FileListSelection()
        selection.click("/a", in: paths, modifier: .none)
        selection.click("/c", in: paths, modifier: .range)
        XCTAssertEqual(selection.selected, ["/a", "/b", "/c"])
        selection.click("/b", in: paths, modifier: .toggle)
        XCTAssertEqual(selection.selected, ["/a", "/c"])
        selection.click("/d", in: paths, modifier: .none)
        XCTAssertEqual(selection.selected, ["/d"])
    }

    func testEffectivePathsFallBackToCursorInListOrder() {
        var selection = FileListSelection()
        selection.setCursor("/b")
        XCTAssertEqual(selection.effectivePaths(in: paths), ["/b"])
        selection.toggle("/d")
        selection.toggle("/a")
        XCTAssertEqual(selection.effectivePaths(in: paths), ["/a", "/d"])
    }

    func testReconcileDropsVanishedPaths() {
        var selection = FileListSelection()
        selection.selectAll(paths)
        selection.setCursor("/d")
        selection.reconcile(with: ["/a", "/b"])
        XCTAssertEqual(selection.selected, ["/a", "/b"])
        XCTAssertEqual(selection.cursor, "/a")
    }

    func testFileEntryIDAndSelectionDistinguishUTF8SpellingsAndType() {
        let nfc = FileEntryID(path: "/b/caf\u{00E9}", isDirectory: false)
        let nfd = FileEntryID(path: "/b/cafe\u{0301}", isDirectory: false)
        let folder = FileEntryID(path: "/b/caf\u{00E9}", isDirectory: true)
        let rows = [folder, nfc, nfd]

        XCTAssertNotEqual(nfc, nfd)
        XCTAssertNotEqual(nfc, folder)
        XCTAssertEqual(Array(nfc.path.utf8), Array("/b/caf\u{00E9}".utf8))
        XCTAssertEqual(Array(nfd.path.utf8), Array("/b/cafe\u{0301}".utf8))

        var selection = FileRowSelection<FileEntryID>()
        selection.click(nfd, in: rows, modifier: .none)
        XCTAssertTrue(selection.contains(nfd))
        XCTAssertFalse(selection.contains(nfc))
        XCTAssertFalse(selection.contains(folder))
        XCTAssertEqual(selection.cursor, nfd)
        XCTAssertEqual(selection.effectiveIDs(in: rows), [nfd])

        // Moving cursor up from NFD lands on NFC, leaving them independently actionable.
        selection.moveCursor(by: -1, in: rows, extending: false)
        XCTAssertEqual(selection.cursor, nfc)
        selection.clear()
        XCTAssertEqual(selection.effectiveIDs(in: rows), [nfc])

        // Reconciling when NFC disappears keeps NFD selected.
        selection.click(nfd, in: rows, modifier: .none)
        selection.reconcile(with: [folder, nfd])
        XCTAssertEqual(selection.selected, [nfd])
        XCTAssertEqual(selection.cursor, nfd)
    }

    // MARK: - sftp-server launcher

    func testLauncherQuotesAndOrdersCandidates() {
        let command = SFTPServerLauncher.command(preferredPath: "/opt/it's/sftp-server")
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        // The preferred path is tried first and survives quoting.
        let preferred = command.range(of: "/opt/it")
        let debian = command.range(of: "/usr/lib/openssh/sftp-server")
        XCTAssertNotNil(preferred)
        XCTAssertNotNil(debian)
        XCTAssertLessThan(preferred!.lowerBound, debian!.lowerBound)
        XCTAssertTrue(command.contains("exit \(SFTPServerLauncher.notFoundExitStatus)"))
    }

    func testShellQuote() {
        XCTAssertEqual(SFTPServerLauncher.shellQuote("a b"), "'a b'")
        XCTAssertEqual(SFTPServerLauncher.shellQuote("it's"), "'it'\\''s'")
    }
}
