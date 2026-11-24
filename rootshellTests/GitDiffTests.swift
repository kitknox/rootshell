import Foundation
import XCTest

final class GitDiffTests: XCTestCase {

    // MARK: - Patch parser

    private let patch = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,5 +10,6 @@ struct App {
         let name: String
    -    let count = 1
    +    let count = 2
    +    let extra = true
         func run() {
         }
    diff --git a/old name.txt b/new name.txt
    similarity index 100%
    rename from old name.txt
    rename to new name.txt
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 3333333..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -first
    -second
    \\ No newline at end of file
    diff --git a/logo.png b/logo.png
    index 4444444..5555555 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git a/notes.md b/notes.md
    new file mode 100644
    index 0000000..6666666
    --- /dev/null
    +++ b/notes.md
    @@ -0,0 +1 @@
    +hello

    """

    func testParsesFilesStatusesAndCounts() {
        let files = GitDiffPatchParser.parse(patch)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift", "new name.txt", "gone.txt", "logo.png", "notes.md"])
        XCTAssertEqual(files.map(\.status), [.modified, .renamed, .deleted, .modified, .added])
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[1].oldPath, "old name.txt")
        XCTAssertTrue(files[1].hunks.isEmpty)
        XCTAssertEqual(files[2].deletions, 2)
        XCTAssertTrue(files[3].isBinary)
        XCTAssertNil(files[3].additions)
        XCTAssertEqual(files[4].additions, 1)
    }

    func testNumbersLinesFromTheHunkHeader() {
        let hunk = GitDiffPatchParser.parse(patch)[0].hunks[0]
        XCTAssertEqual(hunk.context, "struct App {")
        XCTAssertEqual(hunk.lines.map(\.oldNumber), [10, 11, nil, nil, 12, 13])
        XCTAssertEqual(hunk.lines.map(\.newNumber), [10, nil, 11, 12, 13, 14])
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .deletion, .addition, .addition, .context, .context])
    }

    func testMarksAMissingFinalNewlineOnTheLineAbove() {
        let lines = GitDiffPatchParser.parse(patch)[2].hunks[0].lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].noNewlineAtEnd)
        XCTAssertTrue(lines[1].noNewlineAtEnd)
    }

    func testARemovedLineThatLooksLikeAHeaderStaysALine() {
        let files = GitDiffPatchParser.parse("""
        diff --git a/a.sql b/a.sql
        --- a/a.sql
        +++ b/a.sql
        @@ -1,2 +1,2 @@
        --- old comment
        +++ new comment
         select 1

        """)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "a.sql")
        XCTAssertEqual(files[0].hunks[0].lines.map(\.text), ["-- old comment", "++ new comment", "select 1"])
    }

    func testTruncationDropsThePartialLastLine() {
        let cut = String(patch.prefix(patch.count - 4))
        let files = GitDiffPatchParser.parse(cut, truncated: true)
        XCTAssertTrue(files.last?.isTruncated ?? false)
        XCTAssertEqual(files.last?.lineCount, 0)
        XCTAssertFalse(files[0].isTruncated)
    }

    func testUnquotesGitPaths() {
        XCTAssertEqual(GitDiffPatchParser.unquote("\"tab\\there\""), "tab\there")
        XCTAssertEqual(GitDiffPatchParser.unquote("\"caf\\303\\251.txt\""), "café.txt")
        XCTAssertEqual(GitDiffPatchParser.unquote("plain.txt"), "plain.txt")
        let paths = GitDiffPatchParser.headerPaths("\"a/sp ace\\t.txt\" \"b/sp ace\\t.txt\"")
        XCTAssertEqual(paths.new, "sp ace\t.txt")
    }

    func testEmphasisCoversOnlyTheChangedSpan() {
        let spans = GitDiffPatchParser.changedSpans("    let count = 1", "    let count = 22")
        XCTAssertEqual(spans?.old, 16..<17)
        XCTAssertEqual(spans?.new, 16..<18)
        XCTAssertNil(GitDiffPatchParser.changedSpans("alpha", "omega beta"))
    }

    func testUnevenRunsGetNoEmphasis() {
        let lines = GitDiffPatchParser.parse(patch)[0].hunks[0].lines
        XCTAssertNil(lines[1].emphasis)
        XCTAssertNil(lines[2].emphasis)
    }

    // MARK: - Probe reply

    private let nonce = "abc12345"

    private func reply(_ body: String) -> String {
        "noise from a profile\n::GDB_\(nonce)::\n\(body)\n::GDE_\(nonce)::\n"
    }

    func testParsesASummaryReply() {
        let request = GitDiffProbeRequest(includePatch: false)
        let output = reply("""
        R\t/home/me/project
        H\tfeature/x\tabc1234
        F\t
        # branch.upstream origin/feature/x
        # branch.ab +2 -1
        S\t123456
        N\t1
        ::GDN_\(nonce)::
        M\tSources/App.swift
        R100\told name.txt\tnew name.txt
        D\tgone.txt
        M\tlogo.png
        ::GDS_\(nonce)::
        2\t1\tSources/App.swift
        0\t0\told name.txt => new name.txt
        0\t2\tgone.txt
        -\t-\tlogo.png
        ::GDU_\(nonce)::
        notes: draft.md
        ::GDC_\(nonce)::
        /dev/null:0
        notes: draft.md:7

        """)
        guard case .snapshot(let snapshot) = GitDiffProbeCommand.parse(output, nonce: nonce, request: request) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.repositoryRoot, "/home/me/project")
        XCTAssertEqual(snapshot.repositoryName, "project")
        XCTAssertEqual(snapshot.branch, "feature/x")
        XCTAssertEqual(snapshot.upstream, "origin/feature/x")
        XCTAssertEqual(snapshot.ahead, 2)
        XCTAssertEqual(snapshot.behind, 1)
        XCTAssertEqual(snapshot.stamp, "123456")
        XCTAssertFalse(snapshot.includesPatch)
        XCTAssertEqual(snapshot.files.map(\.path),
                       ["Sources/App.swift", "new name.txt", "gone.txt", "logo.png", "notes: draft.md"])
        XCTAssertEqual(snapshot.files[1].oldPath, "old name.txt")
        XCTAssertTrue(snapshot.files[3].isBinary)
        XCTAssertEqual(snapshot.files[4].status, .untracked)
        XCTAssertEqual(snapshot.files[4].additions, 7)
        XCTAssertEqual(snapshot.additions, 9)
        XCTAssertEqual(snapshot.deletions, 3)
    }

    func testAttachesThePatchAndKeepsGitsCounts() {
        let request = GitDiffProbeRequest(includePatch: true)
        let output = reply("""
        R\t/repo
        H\tmain\tabc1234
        S\t9
        N\t0
        ::GDN_\(nonce)::
        M\tSources/App.swift
        ::GDS_\(nonce)::
        2\t1\tSources/App.swift
        ::GDU_\(nonce)::
        ::GDC_\(nonce)::
        ::GDP_\(nonce)::
        \(patch)
        """)
        guard case .snapshot(let snapshot) = GitDiffProbeCommand.parse(output, nonce: nonce, request: request) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertTrue(snapshot.includesPatch)
        XCTAssertFalse(snapshot.patchTruncated)
        XCTAssertEqual(snapshot.files[0].hunks.count, 1)
        XCTAssertTrue(snapshot.files[0].hasPatch)
        XCTAssertEqual(snapshot.files[0].additions, 2)
        // Files only the patch names still show up.
        XCTAssertTrue(snapshot.files.contains { $0.path == "notes.md" })
    }

    func testReportsUnchangedUnavailableAndCutReplies() {
        let request = GitDiffProbeRequest(includePatch: false, knownStamp: "9")
        XCTAssertEqual(
            GitDiffProbeCommand.parse(reply("R\t/repo\nH\tmain\tabc\nS\t9\nN\t0\nU"), nonce: nonce, request: request),
            .unchanged)
        XCTAssertEqual(
            GitDiffProbeCommand.parse(reply("E\tnogit"), nonce: nonce, request: request),
            .unavailable(.gitMissing))
        XCTAssertEqual(
            GitDiffProbeCommand.parse(reply("E\tnorepo\t/tmp"), nonce: nonce, request: request),
            .unavailable(.notARepository(directory: "/tmp")))
        XCTAssertEqual(
            GitDiffProbeCommand.parse(reply("E\tnodir"), nonce: nonce, request: request),
            .unavailable(.noDirectory))
        XCTAssertEqual(
            GitDiffProbeCommand.parse("::GDB_\(nonce)::\nR\t/repo\n", nonce: nonce, request: request),
            .incomplete)
    }

    func testAPathBothDeletedAndNewKeepsTwoEntries() {
        // `git rm --cached` leaves a file staged as deleted and present as new.
        let request = GitDiffProbeRequest(includePatch: true)
        let output = reply("""
        R\t/repo
        H\tmain\tabc1234
        S\t5
        N\t1
        ::GDN_\(nonce)::
        D\tkept.txt
        ::GDS_\(nonce)::
        0\t2\tkept.txt
        ::GDU_\(nonce)::
        kept.txt
        ::GDC_\(nonce)::
        kept.txt:3
        ::GDP_\(nonce)::
        diff --git a/kept.txt b/kept.txt
        deleted file mode 100644
        --- a/kept.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/kept.txt b/kept.txt
        new file mode 100644
        --- /dev/null
        +++ b/kept.txt
        @@ -0,0 +1,3 @@
        +one
        +two
        +three

        """)
        guard case .snapshot(let snapshot) = GitDiffProbeCommand.parse(output, nonce: nonce, request: request) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.files.map(\.status), [.deleted, .untracked])
        XCTAssertEqual(Set(snapshot.files.map(\.id)).count, 2)
        XCTAssertEqual(snapshot.files[0].hunks.first?.lines.map(\.kind), [.deletion, .deletion])
        XCTAssertEqual(snapshot.files[1].hunks.first?.lines.count, 3)
        XCTAssertEqual(snapshot.files[1].additions, 3)
    }

    func testRepeatedIdentitiesAreDropped() {
        var snapshot = GitDiffSnapshot(repositoryRoot: "/repo")
        snapshot.files = [
            GitDiffFile(path: "a", oldPath: nil, status: .modified),
            GitDiffFile(path: "a", oldPath: nil, status: .deleted),
            GitDiffFile(path: "a", oldPath: nil, status: .untracked),
        ]
        snapshot.removeDuplicateFiles()
        XCTAssertEqual(snapshot.files.map(\.status), [.modified, .untracked])
    }

    func testAGitFailureIsNotACleanTree() {
        let request = GitDiffProbeRequest(includePatch: false)
        XCTAssertEqual(
            GitDiffProbeCommand.parse(reply("R\t/repo\nH\tmain\tabc\nF\t\nS\t1\nN\t0\nE\tfailed"), nonce: nonce, request: request),
            .failed)
    }

    func testUntrackedNamesArriveRaw() {
        let request = GitDiffProbeRequest(includePatch: false)
        let output = reply(
            "R\t/repo\nH\tmain\tabc\nS\t1\nN\t3\n::GDN_\(nonce)::\n::GDS_\(nonce)::\n::GDU_\(nonce)::\n"
                + "tab\there.txt\n\"quoted\".txt\nline\u{01}break.txt\nlink\nhuge.log\n"
                + "::GDL_\(nonce)::\nhuge.log\n::GDC_\(nonce)::\n"
                + "/dev/null:0\ntab\there.txt:4\n\"quoted\".txt:2\nline\u{01}break.txt:6\nlink:1")
        guard case .snapshot(let snapshot) = GitDiffProbeCommand.parse(output, nonce: nonce, request: request) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.files.map(\.path),
                       ["tab\there.txt", "\"quoted\".txt", "line\nbreak.txt", "link", "huge.log"])
        // A newline name keeps its own count, a symlink is one line, and a
        // file over the limit is flagged instead of counted as nothing.
        XCTAssertEqual(snapshot.files.map(\.additions), [4, 2, 6, 1, nil])
        XCTAssertEqual(snapshot.files.map(\.isTooLarge), [false, false, false, false, true])
        XCTAssertTrue(snapshot.countsIncomplete)
        XCTAssertEqual(snapshot.additions, 13)
    }

    func testNamesNeverComeFromStatOutput() {
        let script = GitDiffProbeCommand.script(GitDiffProbeRequest(directory: "/work")).script
        // stat prints metadata only, with a sub-second mtime, and stops at `--`.
        XCTAssertTrue(script.contains("_sa='%f %s %y'"))
        XCTAssertTrue(script.contains("_sa='%Xp %z %Fm'"))
        XCTAssertFalse(script.contains("%n"))
        XCTAssertFalse(script.contains("%N"))
        XCTAssertTrue(script.contains("xargs -0 stat $_sf \"$_sa\" --;"))
        // Counting skips option parsing for odd names and never follows a link.
        XCTAssertTrue(script.contains("grep -Ic -e '' -- /dev/null"))
        XCTAssertTrue(script.contains("sed 's/$/:1/'"))
        // Patches take exact NUL-delimited names.
        XCTAssertTrue(script.contains("xargs -0 -n 1 git -c core.quotePath=false diff"))
    }

    func testUnpairedNamesAreReportedNotGuessed() {
        // A file that vanishes mid-probe is asked for again by name, and if
        // the lists still do not pair the reply says so.
        let script = GitDiffProbeCommand.script(GitDiffProbeRequest(directory: "/work")).script
        XCTAssertTrue(script.contains("stat $_sf \"$_sa\" -- \"$_f\" || { if [ -e \"$_f\" ] || [ -L \"$_f\" ]; then printf '? 0 0\\n'"))
        // An existing file whose metadata cannot be read fails the probe.
        XCTAssertTrue(script.contains("if(substr(m[i],1,1)==\"?\"){print \"!\";exit}"))
        XCTAssertTrue(script.contains("if(n!=k){print \"!\";exit}"))
        let request = GitDiffProbeRequest(includePatch: false)
        let output = reply(
            "R\t/repo\nH\tmain\tabc\nS\t1\nN\t2\n::GDN_\(nonce)::\n::GDS_\(nonce)::\n::GDU_\(nonce)::\n"
                + "a.txt\nb.txt\n::GDI_\(nonce)::\n::GDL_\(nonce)::\n::GDC_\(nonce)::")
        XCTAssertEqual(GitDiffProbeCommand.parse(output, nonce: nonce, request: request), .incomplete)

        // A name that is gone by the time it is read is not a change.
        let vanished = reply(
            "R\t/repo\nH\tmain\tabc\nS\t1\nN\t2\n::GDN_\(nonce)::\n::GDS_\(nonce)::\n::GDU_\(nonce)::\n"
                + "a.txt\ngone.txt\n::GDL_\(nonce)::\n::GDG_\(nonce)::\ngone.txt\n::GDC_\(nonce)::\na.txt:2")
        guard case .snapshot(let snapshot) = GitDiffProbeCommand.parse(vanished, nonce: nonce, request: request) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.files.map(\.path), ["a.txt"])
        XCTAssertEqual(snapshot.additions, 2)
    }

    func testLastCommitWithoutACommitComparesNothing() {
        let script = GitDiffProbeCommand.script(GitDiffProbeRequest(directory: "/work", scope: .lastCommit)).script
        XCTAssertTrue(script.contains("_to=HEAD;"))
        XCTAssertTrue(script.contains("[ -n \"$_head\" ] || _skip=1;"))
        XCTAssertFalse(script.contains("_to=${_head:+HEAD}"))
    }

    func testTheStampNamesTheRepositoryAndRef() {
        for scope in GitDiffScope.allCases {
            let script = GitDiffProbeCommand.script(GitDiffProbeRequest(directory: "/work", scope: scope)).script
            guard let stamp = script.range(of: "_stamp=$(printf '%s\\n' \"$_root\"") else {
                return XCTFail("\(scope) stamp does not start with the repository root")
            }
            let rest = script[stamp.upperBound...].prefix(60)
            XCTAssertTrue(rest.contains(scope == .lastCommit ? "\"$_br\"" : "\"$_st\""), "\(scope)")
            // Upstream counts are on screen in every scope, so a fetch must move the stamp.
            let tracked = scope == .lastCommit ? "\"$_base\" \"$_tr\" | cksum" : "\"$_st\""
            XCTAssertTrue(script.contains(tracked), "\(scope)")
        }
    }

    func testAPatchAtTheLimitIsMarkedTruncated() {
        var request = GitDiffProbeRequest(includePatch: true)
        request.patchByteLimit = patch.utf8.count - 6
        let cut = String(decoding: Array(patch.utf8).prefix(request.patchByteLimit), as: UTF8.self)
        let output = reply("R\t/repo\nH\tmain\tabc\nS\t1\nN\t0\n::GDN_\(nonce)::\n::GDS_\(nonce)::\n::GDP_\(nonce)::\n\(cut)")
        guard case .snapshot(let snapshot) = GitDiffProbeCommand.parse(output, nonce: nonce, request: request) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertTrue(snapshot.patchTruncated)
        XCTAssertTrue(snapshot.files.last?.isTruncated ?? false)
    }

    // MARK: - Probe script

    func testScriptCarriesTheRequest() {
        var request = GitDiffProbeRequest(directory: "/srv/it's here", scope: .branch, ignoreWhitespace: true)
        request.knownStamp = "777"
        let built = GitDiffProbeCommand.script(request, pathPrefix: "PATHPREFIX; ")
        XCTAssertTrue(built.script.hasPrefix("PATHPREFIX; exec 2>/dev/null; "))
        XCTAssertTrue(built.script.contains("_d='/srv/it'\"'\"'s here'"))
        XCTAssertTrue(built.script.contains("_ws=-w"))
        XCTAssertTrue(built.script.contains("git merge-base"))
        XCTAssertTrue(built.script.contains("= '777' ]"))
        XCTAssertTrue(built.script.contains("::GDP_\(built.nonce)::"))
        XCTAssertTrue(built.script.hasSuffix("exit 0"))

        request.includePatch = false
        let summary = GitDiffProbeCommand.script(request)
        XCTAssertFalse(summary.script.contains("::GDP_"))
        XCTAssertGreaterThan(GitDiffProbeCommand.responseByteLimit(for: GitDiffProbeRequest()),
                             GitDiffProbeCommand.defaultPatchByteLimit)
    }

    func testPaneDirectoryLookupOnlyRunsWithoutAUsableDirectory() {
        let built = GitDiffProbeCommand.script(GitDiffProbeRequest(directory: "/work"), paneDirectoryScript: " _d=found;")
        XCTAssertTrue(built.script.contains("if [ -z \"$_d\" ] || [ ! -d \"$_d\" ]; then _d=found; fi; "))
    }

    // MARK: - Model

    func testCompactCounts() {
        XCTAssertEqual(GitDiffFormat.compact(0), "0")
        XCTAssertEqual(GitDiffFormat.compact(999), "999")
        XCTAssertEqual(GitDiffFormat.compact(1234), "1.2k")
        XCTAssertEqual(GitDiffFormat.compact(2000), "2k")
        XCTAssertEqual(GitDiffFormat.compact(15_800), "16k")
        XCTAssertEqual(GitDiffFormat.compact(3_400_000), "3.4m")
    }

    func testNameStatusLetters() {
        XCTAssertEqual(GitDiffFileStatus(nameStatus: "R087"), .renamed)
        XCTAssertEqual(GitDiffFileStatus(nameStatus: "A"), .added)
        XCTAssertEqual(GitDiffFileStatus(nameStatus: "U"), .conflicted)
        XCTAssertEqual(GitDiffFileStatus(nameStatus: "M"), .modified)
    }

    // MARK: - Syntax

    private func kinds(_ line: String, path: String) -> [GitDiffSyntax.Token] {
        guard let language = GitDiffSyntax.language(forPath: path) else { return [] }
        return GitDiffSyntax.tokens(Array(line), language: language)
    }

    func testTokenizesKeywordsStringsNumbersAndComments() {
        let tokens = kinds("let x = \"hi\" + 42 // note", path: "a/b.swift")
        XCTAssertEqual(Array(tokens[0..<3]), [.keyword, .keyword, .keyword])
        XCTAssertEqual(tokens[4], .plain)
        XCTAssertEqual(Array(tokens[8..<12]), [.string, .string, .string, .string])
        XCTAssertEqual(Array(tokens[15..<17]), [.number, .number])
        XCTAssertEqual(tokens[18], .comment)
        XCTAssertEqual(tokens.last, .comment)
    }

    func testAnUnclosedQuoteIsNotAString() {
        let tokens = kinds("fn f<'a>(x: &'a str) {}", path: "lib.rs")
        XCTAssertFalse(tokens.contains(.string))
        XCTAssertEqual(tokens[0], .keyword)
    }

    func testHashCommentsNeedAWordBoundary() {
        XCTAssertFalse(kinds("url = http://x/#frag", path: "a.py").contains(.comment))
        XCTAssertEqual(kinds("x = 1  # why", path: "a.py").last, .comment)
        XCTAssertTrue(kinds("plain words", path: "README.md").isEmpty)
    }
}
