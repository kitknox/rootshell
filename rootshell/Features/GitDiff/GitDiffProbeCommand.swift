//
//  GitDiffProbeCommand.swift
//  rootshell
//
//  One POSIX sh script that answers the diff panel over a pane's existing
//  connection: repository facts, a change stamp, per-file counts and,
//  when asked, the patch. It never writes to the repository and takes no
//  index lock, so it is safe to run beside an agent's own git commands.
//

import Foundation

nonisolated struct GitDiffProbeRequest: Equatable, Sendable {
    /// Absolute directory on the host, when the pane reported one.
    var directory: String?
    var scope: GitDiffScope = .uncommitted
    var ignoreWhitespace = false
    /// Counts only when false, which is all the collapsed summary needs.
    var includePatch = true
    /// The stamp of the snapshot already held; the host answers "unchanged"
    /// instead of resending when it still matches.
    var knownStamp: String?
    var patchByteLimit = GitDiffProbeCommand.defaultPatchByteLimit
}

nonisolated enum GitDiffProbeResponse: Equatable, Sendable {
    case snapshot(GitDiffSnapshot)
    /// Nothing changed since `knownStamp`.
    case unchanged
    case unavailable(GitDiffUnavailable)
    /// The end marker never arrived: the transport cut the reply.
    case incomplete
    /// Git ran and could not read the repository (a damaged index, say).
    case failed
}

nonisolated enum GitDiffProbeCommand {

    static let defaultPatchByteLimit = 1_500_000
    /// Untracked files beyond this are counted but not listed.
    static let untrackedFileLimit = 400
    /// Untracked files larger than this are listed without a patch or count.
    static let untrackedByteLimit = 1_048_576
    /// New files whose patch is fetched; the rest show counts only.
    static let untrackedPatchLimit = 150

    /// Builds the script.
    /// - Parameters:
    ///   - paneDirectoryScript: sh that sets `_d` to the pane's directory,
    ///     used when the request carries none that exists on the host.
    ///   - pathPrefix: PATH prologue; an exec channel does not get the
    ///     interactive shell's PATH.
    static func script(
        _ request: GitDiffProbeRequest,
        paneDirectoryScript: String? = nil,
        pathPrefix: String = ""
    ) -> (script: String, nonce: String) {
        let nonce = String(UUID().uuidString.prefix(8))
        func marker(_ name: String) -> String { "'::GD\(name)_\(nonce)::'" }
        let quote = LoginShellCommand.singleQuoted

        var s = pathPrefix
        // Citadel fails the whole reply if anything reaches stderr.
        s += "exec 2>/dev/null; "
        s += "export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0; unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; "
        s += "_d=\(quote(request.directory ?? "")); "
        if let paneDirectoryScript {
            // A reported directory can be stale, or belong to another host.
            s += "if [ -z \"$_d\" ] || [ ! -d \"$_d\" ]; then\(paneDirectoryScript) fi; "
        }
        s += "_g() { git -c core.quotePath=false \"$@\"; }; "
        // Paths travel NUL-delimited so tabs, quotes and backslashes stay
        // literal. A shell variable cannot hold NUL, so a list is stored one
        // name per line with a newline inside a name swapped for \001.
        s += "_enc() { tr '\\n\\0' '\\001\\n'; }; _dec() { tr '\\001\\n' '\\n\\0'; }; "
        s += "printf '%s\\n' \(marker("B")); "
        s += "if ! command -v git >/dev/null 2>&1; then printf 'E\\tnogit\\n'; "
        s += "elif [ -z \"$_d\" ] || ! cd \"$_d\"; then printf 'E\\tnodir\\n'; "
        s += "else _root=$(git rev-parse --show-toplevel); "
        s += "if [ -z \"$_root\" ] || ! cd \"$_root\"; then printf 'E\\tnorepo\\t%s\\n' \"$_d\"; else "

        s += "_head=$(git rev-parse -q --verify HEAD); _br=$(git symbolic-ref --short -q HEAD); "
        s += "_empty=$(git hash-object -t tree /dev/null); "
        s += "_ws=\(request.ignoreWhitespace ? "-w" : ""); _to=; _bref=; _skip=; _err=; "
        switch request.scope {
        case .uncommitted:
            s += "_base=${_head:-$_empty}; _unt=1; "
        case .branch:
            // The remote's default branch first, so a branch cut from it
            // compares against where a pull request would land.
            s += "for _c in \"$(git symbolic-ref -q --short refs/remotes/origin/HEAD)\" origin/main origin/master main master; do "
            s += "[ -n \"$_c\" ] || continue; git rev-parse -q --verify \"$_c^{commit}\" >/dev/null || continue; _bref=$_c; break; done; "
            s += "_base=; [ -n \"$_bref\" ] && [ -n \"$_head\" ] && _base=$(git merge-base \"$_bref\" HEAD); "
            s += "_base=${_base:-${_head:-$_empty}}; _unt=1; "
        case .lastCommit:
            // Without a commit there is nothing to show; an empty `_to`
            // would compare against the working tree instead.
            s += "_base=$(git rev-parse -q --verify 'HEAD~1^{commit}'); _base=${_base:-$_empty}; _to=HEAD; _unt=; "
            s += "[ -n \"$_head\" ] || _skip=1; "
        }

        // A git that cannot read the repository must not look like a clean
        // tree. The pipe hides git's exit status, so failure leaves a mark.
        let failure = "::GDX_\(nonce)::"
        s += "_st=$({ _g status --porcelain=v2 --branch -z || printf '\\0%s\\0' '\(failure)'; } | _enc); "
        s += "case \"$_st\" in *'\(failure)'*) _err=1;; esac; "
        // In -z output a rename's original path is a record of its own.
        s += "_mod=$(printf '%s\\n' \"$_st\" | awk 'skip{skip=0;next}"
        s += "/^1 /{for(i=0;i<8;i++)sub(/^[^ ]+ /,\"\");print;next}"
        s += "/^2 /{for(i=0;i<9;i++)sub(/^[^ ]+ /,\"\");print;skip=1;next}"
        s += "/^u /{for(i=0;i<10;i++)sub(/^[^ ]+ /,\"\");print;next}'); "
        s += "_ul=; _uc=0; if [ -n \"$_unt\" ]; then "
        s += "_ul=$(_g ls-files --others --exclude-standard -z | _enc | head -n \(untrackedFileLimit + 1)); "
        s += "[ -n \"$_ul\" ] && _uc=$(printf '%s\\n' \"$_ul\" | wc -l | tr -d ' '); "
        s += "_ul=$(printf '%s\\n' \"$_ul\" | head -n \(untrackedFileLimit)); fi; "
        // GNU and BSD stat disagree on every flag; pick one up front. It
        // prints mode, size and a sub-second mtime, and never the name: a
        // name can hold a newline, so names and metadata pair by position.
        s += "if stat -c %s / >/dev/null 2>&1; then _sf=-c; _sa='%f %s %y'; else _sf=-f; _sa='%Xp %z %Fm'; fi; "
        // With no stat that takes either form, content changes cannot be
        // seen, so the stamp is made unrepeatable and every probe reads afresh.
        s += "_sx=; stat $_sf \"$_sa\" -- / >/dev/null 2>&1 || _sx=\"$$.$(date +%s)\"; "
        s += "_stl() { [ -n \"$1\" ] && printf '%s\\n' \"$1\" | _dec | xargs -0 stat $_sf \"$_sa\" --; }; "
        s += "_ms=$(_stl \"$_mod\"); _us=$(_stl \"$_ul\"); "
        // A file that vanished between the listing and stat leaves the two
        // lists unpaired. Ask again one name at a time, so every name keeps
        // a line and the files still there keep their counts and patches.
        // Only a name that is really absent is marked gone (`0`); one that
        // exists but cannot be read is marked `?`, which fails the probe
        // instead of passing for an unchanged tree.
        s += "_cn() { if [ -n \"$1\" ]; then printf '%s\\n' \"$1\" | wc -l | tr -d ' '; else echo 0; fi; }; "
        s += "if [ \"$(_cn \"$_us\")\" != \"$(_cn \"$_ul\")\" ]; then "
        s += "_us=$(printf '%s\\n' \"$_ul\" | while IFS= read -r _n; do [ -n \"$_n\" ] || continue; "
        s += "_f=$(printf '%sx' \"$_n\" | tr '\\001' '\\n'); _f=${_f%x}; "
        s += "stat $_sf \"$_sa\" -- \"$_f\" || { if [ -e \"$_f\" ] || [ -L \"$_f\" ]; then printf '? 0 0\\n'; else printf '0 0 0\\n'; fi; }; done); fi; "
        s += "_tr=$(printf '%s\\n' \"$_st\" | grep '^# branch\\.[ua]'); "
        // The stamp covers everything the panel shows: which repository and
        // ref, the upstream counts, the refs compared, and the size and mtime
        // of every changed or new file. Cheap, and it moves when content does.
        if request.scope == .lastCommit {
            s += "_stamp=$(printf '%s\\n' \"$_root\" \"$_br\" \"$_head\" \"$_base\" \"$_tr\" | cksum | tr -d ' \\t'); "
        } else {
            s += "_stamp=$(printf '%s\\n' \"$_root\" \"$_st\" \"$_head\" \"$_base\" \"$_bref\" \"$_ms\" \"$_ul\" \"$_us\" \"$_sx\""
            s += " | cksum | tr -d ' \\t'); "
        }

        s += "printf 'R\\t%s\\n' \"$_root\"; "
        s += "printf 'H\\t%s\\t%s\\n' \"$_br\" \"$(git rev-parse --short HEAD)\"; "
        s += "printf 'F\\t%s\\n' \"$_bref\"; "
        s += "[ -n \"$_tr\" ] && printf '%s\\n' \"$_tr\"; "
        s += "printf 'S\\t%s\\n' \"$_stamp\"; "
        s += "printf 'N\\t%s\\n' \"$_uc\"; "

        let known = request.knownStamp ?? ""
        s += "if [ -n \"$_err\" ]; then printf 'E\\tfailed\\n'; "
        s += "elif [ \"$_stamp\" = \(quote(known)) ]; then printf 'U\\n'; else "
        s += "_ns=; _nm=; if [ -z \"$_skip\" ]; then "
        s += "_ns=$(_g diff -M --name-status $_ws \"$_base\" $_to --) || _err=1; "
        s += "_nm=$(_g diff -M --numstat $_ws \"$_base\" $_to --) || _err=1; fi; "
        s += "if [ -n \"$_err\" ]; then printf 'E\\tfailed\\n'; else "
        s += "printf '%s\\n' \(marker("N")); [ -n \"$_ns\" ] && printf '%s\\n' \"$_ns\"; "
        s += "printf '%s\\n' \(marker("S")); [ -n \"$_nm\" ] && printf '%s\\n' \"$_nm\"; "
        s += "printf '%s\\n' \(marker("U")); [ -n \"$_ul\" ] && printf '%s\\n' \"$_ul\"; "
        // Sort new files by what may be read: `f` a regular file within the
        // limit, `b` one over it, `l` a symlink (never followed), `g` one that
        // is gone and so is not a change. Lists that still fail to pair are
        // reported, never guessed at.
        let split = "::GDZ_\(nonce)::"
        s += "_tg=$({ printf '%s\\n' \"$_us\"; printf '%s\\n' '\(split)'; printf '%s\\n' \"$_ul\"; }"
        s += " | awk -v lim=\(untrackedByteLimit) '!z{if($0==\"\(split)\"){z=1;next}m[++n]=$0;next}{f[++k]=$0}"
        s += "END{if(n!=k){print \"!\";exit}for(i=1;i<=n;i++)if(substr(m[i],1,1)==\"?\"){print \"!\";exit}for(i=1;i<=n;i++){split(m[i],a,\" \");t=tolower(substr(a[1],1,1));"
        s += "if(t==\"0\")print \"g \" f[i];else if(t==\"a\")print \"l \" f[i];else if(t==\"8\"){p=(a[2]+0<=lim)?\"f \":\"b \";print p f[i]}}}'); "
        s += "[ \"$_tg\" = '!' ] && printf '%s\\n' \(marker("I")); "
        s += "_cf=$(printf '%s\\n' \"$_tg\" | sed -n 's/^f //p'); _cl=$(printf '%s\\n' \"$_tg\" | sed -n 's/^l //p'); "
        s += "printf '%s\\n' \(marker("L")); printf '%s\\n' \"$_tg\" | sed -n 's/^b //p'; "
        s += "printf '%s\\n' \(marker("G")); printf '%s\\n' \"$_tg\" | sed -n 's/^g //p'; "
        // Line counts. Ordinary names go through one grep; -I reports
        // binaries as 0. A name holding a newline is counted alone and
        // reported in its one-line form. A symlink is one line, its target.
        s += "printf '%s\\n' \(marker("C")); _c1=$(printf '\\001'); "
        s += "_cg=$(printf '%s\\n' \"$_cf\" | grep -v \"$_c1\"); "
        s += "[ -n \"$_cg\" ] && printf '%s\\n' \"$_cg\" | tr '\\n' '\\0' | xargs -0 grep -Ic -e '' -- /dev/null; "
        s += "printf '%s\\n' \"$_cf\" | grep \"$_c1\" | while IFS= read -r _n; do "
        s += "_f=$(printf '%sx' \"$_n\" | tr '\\001' '\\n'); _f=${_f%x}; "
        s += "printf '%s:%s\\n' \"$_n\" \"$(grep -Ic -e '' < \"$_f\")\"; done; "
        s += "[ -n \"$_cl\" ] && printf '%s\\n' \"$_cl\" | sed 's/$/:1/'; "
        if request.includePatch {
            let flags = "--no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/"
            s += "printf '%s\\n' \(marker("P")); { "
            s += "[ -z \"$_skip\" ] && _g -c diff.suppressBlankEmpty=false diff \(flags) -M --submodule=short $_ws \"$_base\" $_to --; "
            s += "{ printf '%s\\n' \"$_cf\"; printf '%s\\n' \"$_cl\"; } | sed '/^$/d' | head -n \(untrackedPatchLimit) | _dec"
            s += " | xargs -0 -n 1 git -c core.quotePath=false diff \(flags) --no-index -- /dev/null; "
            s += "} | head -c \(max(1, request.patchByteLimit)); "
        }
        s += "fi; fi; "

        s += "fi; fi; "
        // The patch may end mid-line; the marker still starts its own.
        s += "printf '\\n%s\\n' \(marker("E")); exit 0"
        return (s, nonce)
    }

    /// The script wrapped for whatever login shell the host runs.
    static func command(
        _ request: GitDiffProbeRequest,
        paneDirectoryScript: String? = nil,
        pathPrefix: String = ""
    ) -> (command: String, nonce: String) {
        let built = script(request, paneDirectoryScript: paneDirectoryScript, pathPrefix: pathPrefix)
        return (LoginShellCommand.runInPOSIXShell(built.script), built.nonce)
    }

    /// Reply bytes to allow for a request: the patch plus the listings.
    static func responseByteLimit(for request: GitDiffProbeRequest) -> Int {
        (request.includePatch ? request.patchByteLimit : 0) + 512 * 1024
    }

    // MARK: - Parsing

    static func parse(_ output: String, nonce: String, request: GitDiffProbeRequest) -> GitDiffProbeResponse {
        func marker(_ name: String) -> String { "::GD\(name)_\(nonce)::" }
        guard let begin = output.range(of: marker("B")),
              let end = output.range(of: "\n" + marker("E"), range: begin.upperBound..<output.endIndex)
        else { return .incomplete }
        let body = output[begin.upperBound..<end.lowerBound]

        // The patch is raw text, so it is cut out before anything is split by line.
        var head = body
        var patch: Substring?
        if let patchMarker = body.range(of: marker("P") + "\n") {
            head = body[..<patchMarker.lowerBound]
            patch = body[patchMarker.upperBound...]
        } else if let patchMarker = body.range(of: marker("P")) {
            head = body[..<patchMarker.lowerBound]
            patch = ""
        }

        var snapshot = GitDiffSnapshot(repositoryRoot: "")
        var unchanged = false
        var untrackedTotal = 0
        var section = ""
        var nameStatus: [[Substring]] = []
        var numstat: [[Substring]] = []
        var untracked: [String] = []
        var untrackedCounts: [String: Int] = [:]
        var oversized: Set<String> = []
        var gone: Set<String> = []
        func decodedName(_ name: Substring) -> String { name.replacingOccurrences(of: "\u{01}", with: "\n") }

        for line in head.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("::GD") {
                // The host could not pair names with their metadata.
                if line == marker("I") { return .incomplete }
                for name in ["N", "S", "U", "L", "G", "C"] where line == marker(name) { section = name }
                continue
            }
            switch section {
            case "N": nameStatus.append(line.split(separator: "\t", omittingEmptySubsequences: false))
            case "S": numstat.append(line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false))
            // Raw names, with a newline inside one sent as \u{01}.
            case "U": untracked.append(decodedName(line))
            case "L": oversized.insert(decodedName(line))
            case "G": gone.insert(decodedName(line))
            case "C":
                // `path:count`; split at the last colon, paths may hold one.
                guard let colon = line.lastIndex(of: ":"), let count = Int(line[line.index(after: colon)...]) else { continue }
                untrackedCounts[decodedName(line[..<colon])] = count
            default:
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                switch fields.first {
                case "E":
                    switch fields.count > 1 ? fields[1] : "" {
                    case "nogit": return .unavailable(.gitMissing)
                    case "failed": return .failed
                    case "norepo": return .unavailable(.notARepository(directory: fields.count > 2 ? String(fields[2]) : ""))
                    default: return .unavailable(.noDirectory)
                    }
                case "R": snapshot.repositoryRoot = fields.count > 1 ? String(fields[1]) : ""
                case "H":
                    if fields.count > 1, !fields[1].isEmpty { snapshot.branch = String(fields[1]) }
                    if fields.count > 2, !fields[2].isEmpty { snapshot.headSHA = String(fields[2]) }
                case "F": if fields.count > 1, !fields[1].isEmpty { snapshot.baseRef = String(fields[1]) }
                case "S": snapshot.stamp = fields.count > 1 ? String(fields[1]) : ""
                case "N": untrackedTotal = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
                case "U": unchanged = true
                default:
                    if line.hasPrefix("# branch.upstream ") {
                        snapshot.upstream = String(line.dropFirst("# branch.upstream ".count))
                    } else if line.hasPrefix("# branch.ab ") {
                        for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                            if part.first == "+" { snapshot.ahead = Int(part.dropFirst()) ?? 0 }
                            if part.first == "-" { snapshot.behind = Int(part.dropFirst()) ?? 0 }
                        }
                    }
                }
            }
        }

        guard !snapshot.repositoryRoot.isEmpty else { return .incomplete }
        if unchanged { return .unchanged }

        snapshot.files = trackedFiles(nameStatus: nameStatus, numstat: numstat)
        for path in untracked where !gone.contains(path) {
            let count = untrackedCounts[path]
            var file = GitDiffFile(path: path, oldPath: nil, status: .untracked,
                                   additions: count, deletions: count == nil ? nil : 0)
            file.isTooLarge = oversized.contains(path)
            snapshot.files.append(file)
        }
        snapshot.untrackedTruncated = untrackedTotal > untracked.count
        snapshot.removeDuplicateFiles()
        snapshot.includesPatch = patch != nil

        if let patch {
            let truncated = patch.utf8.count >= request.patchByteLimit
            snapshot.patchTruncated = truncated
            merge(GitDiffPatchParser.parse(String(patch), truncated: truncated), into: &snapshot)
        }
        return .snapshot(snapshot)
    }

    /// Zips `--name-status` with `--numstat`. Both walk the same diff queue,
    /// so they agree by position; by path is the fallback if they ever differ.
    static func trackedFiles(nameStatus: [[Substring]], numstat: [[Substring]]) -> [GitDiffFile] {
        let aligned = nameStatus.count == numstat.count
        var countsByPath: [String: (Int?, Int?)] = [:]
        if !aligned {
            for fields in numstat where fields.count == 3 {
                countsByPath[GitDiffPatchParser.unquote(String(fields[2]))] = (Int(fields[0]), Int(fields[1]))
            }
        }
        var files: [GitDiffFile] = []
        for (index, fields) in nameStatus.enumerated() {
            guard fields.count >= 2 else { continue }
            let status = GitDiffFileStatus(nameStatus: String(fields[0]))
            let hasOrigin = (status == .renamed || status == .copied) && fields.count >= 3
            let path = GitDiffPatchParser.unquote(String(fields[hasOrigin ? 2 : 1]))
            var file = GitDiffFile(path: path, oldPath: hasOrigin ? GitDiffPatchParser.unquote(String(fields[1])) : nil,
                                   status: status)
            let counts: (Int?, Int?)? = aligned
                ? (numstat[index].count >= 2 ? (Int(numstat[index][0]), Int(numstat[index][1])) : nil)
                : countsByPath[path]
            if let counts {
                file.additions = counts.0
                file.deletions = counts.1
                // numstat prints "-" for both counts of a binary file.
                file.isBinary = counts.0 == nil && counts.1 == nil
            }
            files.append(file)
        }
        return files
    }

    /// Attaches parsed hunks to the listed files. Counts stay git's own, so
    /// totals are right even where the patch was cut.
    static func merge(_ patches: [GitDiffFile], into snapshot: inout GitDiffSnapshot) {
        var indicesByPath: [String: [Int]] = [:]
        for (index, file) in snapshot.files.enumerated() { indicesByPath[file.path, default: []].append(index) }
        for patch in patches {
            let candidates = indicesByPath[patch.path] ?? []
            // One path can be both a staged deletion and a new file. The
            // deletion's patch goes to the tracked entry, the other to the new one.
            let match = candidates.count > 1
                ? candidates.first { (snapshot.files[$0].status == .untracked) == (patch.status != .deleted) }
                : candidates.first
            guard let index = match else {
                // Listed by the patch only: a file that changed between the two git calls.
                indicesByPath[patch.path, default: []].append(snapshot.files.count)
                snapshot.files.append(patch)
                continue
            }
            snapshot.files[index].hunks = patch.hunks
            snapshot.files[index].maxColumns = patch.maxColumns
            snapshot.files[index].hasPatch = true
            snapshot.files[index].isTruncated = patch.isTruncated
            if patch.isBinary { snapshot.files[index].isBinary = true }
            if snapshot.files[index].additions == nil, !patch.isBinary {
                snapshot.files[index].additions = patch.additions
                snapshot.files[index].deletions = patch.deletions
            }
        }
    }
}
