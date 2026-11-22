//
//  AgentUsageProbeCommand.swift
//  rootshell
//
//  Reads a coding agent's own sign-in credentials off the host it runs on,
//  so the app can ask the agent's provider how much of the subscription
//  window is used. One nonce-delimited `sh -lc` over a single exec channel,
//  never typed into the user's pane. Modelled on ProjectProbeCommand.
//
//  The script only READS: a credentials file, a Keychain item, an env var.
//  It never writes to the host and never refreshes a token.
//

import Foundation

/// A provider whose subscription usage the app can track. Raw values match
/// the AgentDetectionManifest agent ids, which is how live panes map here.
nonisolated enum AgentUsageProvider: String, CaseIterable, Sendable, Codable {
    case claude
    case codex
    case copilot
    /// oh-my-pi. Unlike the other three this lane does NOT yield a
    /// credential: `omp` is signed into many providers at once, so a single
    /// pane maps to N accounts and no single provider. Its section returns a
    /// finished `omp usage --json` report instead, and no token ever leaves
    /// the host. See `AgentUsageOMPReport`.
    case omp
    /// Antigravity (`agy` and the desktop app). A report lane like omp: the
    /// host asks the running language server, or hands back the saved
    /// sign-in so the app asks Google (`AgentUsageAPIClient`).
    case antigravity = "agy"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        // Not "GitHub Copilot": the footer row is narrow and the brand
        // mark already disambiguates.
        case .copilot: return "Copilot"
        case .omp: return "oh-my-pi"
        case .antigravity: return "Antigravity"
        }
    }

    /// True when the section returns a usage report rather than a credential.
    /// Such a lane must never reach the credential cache, the token store or
    /// the 401/digest machinery.
    var yieldsUsageReport: Bool { self == .omp || self == .antigravity }
}

/// One provider's credential-read outcome on one host.
///
/// The three cases are deliberately distinct from "no readout at all":
/// a section whose end marker never arrived is a transport failure and must
/// be retried, never cached as a negative answer.
nonisolated enum AgentUsageCredentialReadout: Equatable, Sendable {
    /// Raw credential JSON, exactly as the host stores it.
    case payload(String)
    /// No credentials exist on this host. A stable fact worth a long TTL.
    case absent
    /// Credentials exist but could not be read. `keychainLocked` is the one
    /// diagnosable reason worth surfacing: the macOS login keychain was
    /// locked in the exec channel's session.
    case unreadable(keychainLocked: Bool)
    /// Credentials were read but the provider refused them. Antigravity only:
    /// the host handed back a token Google already refused.
    case signInExpired
}

/// Antigravity's saved Google sign-in, for the app to call Google with.
/// Held in memory only; never persisted or logged.
nonisolated struct AgentUsageAntigravityToken: Equatable, Sendable {
    let accessToken: String
    /// The `agy` user agent for the host's OS and architecture.
    let userAgent: String
}

nonisolated struct AgentUsageProbeResult: Equatable, Sendable {
    /// Keyed by provider; a provider missing entirely means its section was
    /// truncated or never ran — retry, don't cache.
    var readouts: [AgentUsageProvider: AgentUsageCredentialReadout] = [:]
    /// The Antigravity section started a background `agy models` to renew
    /// an expired sign-in.
    var antigravityRenewed = false
    /// The desktop app did not answer, so the host sent its sign-in. Only set
    /// when the section ended with its marker.
    var antigravityToken: AgentUsageAntigravityToken?
}

nonisolated enum AgentUsageProbeCommand {

    /// Builds the credential probe for a set of providers on one host.
    ///
    /// Providers are batched deliberately: claude and codex on the same host
    /// cost ONE exec channel, not one each.
    /// - Parameter pathPrefix: shell prologue that widens `PATH` (callers pass
    ///   `SSHConfig.remoteExecPathPrefix`). An exec channel does NOT get the
    ///   interactive shell's PATH. Defaulted so the pure test harness need
    ///   not link SSHConfig.
    /// - Parameter antigravityRenewal: Google refused the saved token, so the
    ///   Antigravity section starts `agy models` in the background.
    /// - Parameter antigravitySkipLocal: skips the desktop app and reads the
    ///   sign-in, for a host whose desktop app last answered with nothing usable.
    static func command(
        providers: [AgentUsageProvider],
        pathPrefix: String = "",
        antigravityRenewal: Bool = false,
        antigravitySkipLocal: Bool = false
    ) -> (command: String, nonce: String) {
        let built = script(
            providers: providers, pathPrefix: pathPrefix,
            antigravityRenewal: antigravityRenewal,
            antigravitySkipLocal: antigravitySkipLocal)
        // `sh -lc`: the login shell gives $CLAUDE_CODE_OAUTH_TOKEN (and any
        // profile-set CLAUDE_CONFIG_DIR / CODEX_HOME) a chance to exist.
        return ("sh -lc \(ProjectProbeCommand.singleQuoted(built.script))", built.nonce)
    }

    /// The inner script, before it is wrapped for `sh -lc`.
    ///
    /// Exposed so tests can syntax-check what the remote shell ACTUALLY
    /// parses; `sh -n` against the wrapped command only parses the outer
    /// line. Same guard as ProjectProbeCommand.
    static func script(
        providers: [AgentUsageProvider],
        pathPrefix: String = "",
        antigravityRenewal: Bool = false,
        antigravitySkipLocal: Bool = false
    ) -> (script: String, nonce: String) {
        let nonce = String(UUID().uuidString.prefix(8))

        var script = pathPrefix
        for provider in providers {
            switch provider {
            case .claude: script += claudeSection(nonce: nonce)
            case .codex: script += codexSection(nonce: nonce)
            case .copilot: script += copilotSection(nonce: nonce)
            case .omp: script += ompSection(nonce: nonce)
            case .antigravity:
                script += antigravitySection(
                    nonce: nonce, renewal: antigravityRenewal, skipLocal: antigravitySkipLocal)
            }
        }
        // Always succeed. A non-zero exit makes Citadel raise CommandFailed
        // and DISCARD the output, so one failing step would throw away the
        // sections that did answer. Markers make partial output safe.
        script += " exit 0"

        return (script, nonce)
    }

    /// Claude Code stores its OAuth credentials in `.credentials.json` under
    /// `$CLAUDE_CONFIG_DIR` (default `~/.claude`) on Linux, or in the macOS
    /// login Keychain under the service "Claude Code-credentials". A token
    /// from `claude setup-token` lands in $CLAUDE_CODE_OAUTH_TOKEN instead.
    /// Tried in that order; the env var also covers a Mac whose Keychain item
    /// is missing.
    private static func claudeSection(nonce: String) -> String {
        let service = "\"Claude Code-credentials\""
        var s = "printf '::CLB_\(nonce)::\\n';"
        s += " _cf=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json\";"
        // `_got` flips only when a payload is actually PRINTED, and the
        // failure is remembered rather than emitted on the spot. An earlier
        // version marked the provider answered as soon as a store existed,
        // so on a Mac (where a keychain item always exists) the env-var
        // fallback below was unreachable and the documented workaround for
        // a locked keychain could never have worked.
        s += " _got=0; _fail='';"
        s += " if [ -e \"$_cf\" ]; then"
        // `cat` prints the payload while the `if` tests its exit status; the
        // trailing printf keeps the end marker on its own line even when the
        // file has no final newline.
        s += " if [ -r \"$_cf\" ] && cat \"$_cf\" 2>/dev/null; then printf '\\n'; _got=1;"
        s += " else _fail=err; fi;"
        s += " elif [ \"$(uname -s 2>/dev/null)\" = Darwin ]"
        s += " && command -v security >/dev/null 2>&1"
        // WITHOUT -w this is a metadata query and succeeds on a locked
        // keychain, so "item exists" and "item is readable" stay separate
        // facts: a missing item is a stable negative, a locked keychain is a
        // retryable condition the user may fix by unlocking.
        s += " && security find-generic-password -s \(service) >/dev/null 2>&1; then"
        // Classify by EXIT CODE, not by stderr text: a `-w` read refused in
        // a detached session (any SSH/tsshd exec channel on a Mac) exits 36
        // = errSecInteractionNotAllowed and prints NOTHING to stderr. The
        // "User interaction is not allowed" string only ever comes back
        // from show-keychain-info, so matching on it never fired and every
        // remote Mac read as a generic error.
        s += " _t=$(security find-generic-password -s \(service) -w 2>/dev/null); _rc=$?;"
        s += " if [ \"$_rc\" = 0 ] && [ -n \"$_t\" ]; then printf '%s\\n' \"$_t\"; _got=1;"
        s += " elif [ \"$_rc\" = 36 ]; then"
        // rc 36 means this session is not allowed to unlock the item, which
        // is EVERY exec channel on a Mac: sshd and tsshd children live in a
        // different security session from the desktop login.
        //
        // A tmux server started from the desktop session is not, though, and
        // `run-shell` executes in the SERVER's context — so when the user has
        // one (the common case for anyone reaching a Mac this way), the
        // secret is legitimately readable after all. Verified on macOS: the
        // identical read that exits 36 directly succeeds through run-shell.
        // This runs a command on the server, never types into a pane.
        s += " _tt='';"
        s += " if command -v tmux >/dev/null 2>&1; then"
        s += " _tt=$(tmux run-shell 'security find-generic-password -s \(service) -w'"
        s += " 2>/dev/null); fi;"
        // Match on the payload's own shape so a tmux error or banner can
        // never be mistaken for a credential.
        s += " case \"$_tt\" in"
        s += " *claudeAiOauth*) printf '%s\\n' \"$_tt\"; _got=1;;"
        s += " *) _fail=locked;;"
        s += " esac;"
        s += " else _fail=err; fi;"
        s += " fi;"
        // An explicitly exported token outranks a store we could not read:
        // it is the documented way out of a locked keychain, so it has to
        // win over one. `sh -lc` reads ~/.profile, which is what makes this
        // reachable over an exec channel at all.
        s += " if [ \"$_got\" = 0 ] && [ -n \"$CLAUDE_CODE_OAUTH_TOKEN\" ]; then"
        // Synthesize the file shape so the app has one Claude parser.
        s += " printf '{\"claudeAiOauth\":{\"accessToken\":\"%s\"}}\\n' \"$CLAUDE_CODE_OAUTH_TOKEN\";"
        s += " _got=1; fi;"
        s += " if [ \"$_got\" = 0 ]; then case \"$_fail\" in"
        s += " locked) printf '::CLLOCKED_\(nonce)::\\n';;"
        s += " err) printf '::CLERR_\(nonce)::\\n';;"
        s += " *) printf '::CLNONE_\(nonce)::\\n';;"
        s += " esac; fi;"
        s += " printf '::CLE_\(nonce)::\\n';"
        return s
    }

    /// Codex keeps everything in `auth.json` under `$CODEX_HOME` (default
    /// `~/.codex`). No Keychain involved on any platform.
    private static func codexSection(nonce: String) -> String {
        var s = " printf '::CXB_\(nonce)::\\n';"
        s += " _cx=\"${CODEX_HOME:-$HOME/.codex}/auth.json\";"
        s += " if [ -e \"$_cx\" ]; then"
        s += " if [ -r \"$_cx\" ] && cat \"$_cx\" 2>/dev/null; then printf '\\n';"
        s += " else printf '::CXERR_\(nonce)::\\n'; fi;"
        s += " else printf '::CXNONE_\(nonce)::\\n'; fi;"
        s += " printf '::CXE_\(nonce)::\\n';"
        return s
    }

    /// oh-my-pi signs into many providers at once, so there is no single
    /// credential to read and no single account to attribute a pane to. It
    /// ships `omp usage --json`, which reports every authenticated account in
    /// one normalized payload and caches each provider's answer for five
    /// minutes internally, so this asks omp rather than reading its store.
    ///
    /// Consequences worth keeping in mind:
    ///   - no token ever leaves the host, so there is nothing to hold, digest
    ///     or blacklist for this lane;
    ///   - providers omp adds later work with no change here;
    ///   - a cold cache makes omp fetch live, so this section can be slow.
    ///
    /// `--json` writes its payload and returns BEFORE the no-credentials
    /// exit-1 path, so an install with nothing signed in emits a valid
    /// `{"reports": [], ...}` and exits 0. That absence is therefore carried
    /// in the PAYLOAD, not in the exit code, and the parser reports it.
    ///
    /// A non-zero exit with no report on stdout is consequently a real
    /// failure (a wrapper, an older omp without the subcommand, a crash) and
    /// takes the transport backoff rather than being cached as an absence.
    ///
    /// Never `omp usage invalidate`: that would drop the cache omp keeps for
    /// its own foreground use and turn every poll into a live fan-out.
    private static func ompSection(nonce: String) -> String {
        var s = " printf '::OMB_\(nonce)::\\n';"
        s += " if command -v omp >/dev/null 2>&1; then"
        s += " _om=$(omp usage --json 2>/dev/null); _orc=$?;"
        // Require the payload's own shape, not just a zero exit: a wrapper
        // script or a login banner on stdout must not be parsed as a report.
        s += " case \"$_om\" in"
        s += " *'\"reports\"'*) printf '%s\\n' \"$_om\";;"
        s += " *) printf '::OMERR_\(nonce)::\\n';;"
        s += " esac;"
        s += " else printf '::OMNONE_\(nonce)::\\n'; fi;"
        s += " printf '::OME_\(nonce)::\\n';"
        return s
    }

    /// Separates the answers inside an Antigravity payload. Payload structure,
    /// not protocol framing, so no nonce (same as `copilotSourceSeparator`).
    static let antigravityPartPrefix = "::AGPART:"

    /// Bytes the host keeps from any one Antigravity HTTP response, status
    /// marker included. At most three parts are emitted, so they stay under
    /// the app's 1 MiB read cap; an oversized response loses its marker and
    /// counts as a failed call.
    static let antigravityResponseMaxBytes = 256 * 1024

    /// Antigravity's quota, or the token the app needs to ask Google itself.
    ///
    /// 1. The running desktop app's language server: found by its command
    ///    line (`--csrf_token`), its listening ports from lsof or ss, then the
    ///    quota summary over HTTPS on 127.0.0.1 (self-signed, so `-k`, local
    ///    only). The `agy` CLI keeps its token in-process, so it never answers
    ///    here. A port's three calls run in parallel (a temp dir holds the
    ///    answers), so a dead port costs one timeout, not three.
    /// 2. Otherwise the saved sign-in goes back to the app (`::AGTOKEN_`),
    ///    which calls Google and holds it in memory only: the macOS Keychain
    ///    item `gemini`/`antigravity` (tmux bridge on rc 36, as for Claude),
    ///    the Secret Service on Linux, or the token file `agy` writes on hosts
    ///    without a keyring.
    ///
    /// The CSRF token reaches curl on stdin (`-H @-`), never in argv, and
    /// loopback calls skip any proxy so it stays on the machine. Each
    /// response passes through `head -c` before the shell holds it, and the
    /// desktop scan stops calling after 10 s. `renewal` is set after Google
    /// refused the token: `agy models` then starts in the BACKGROUND to renew
    /// it, far too slow to wait for, and a later probe reads the new token.
    private static func antigravitySection(
        nonce: String, renewal: Bool, skipLocal: Bool
    ) -> String {
        #"""

        printf '::AGB_\#(nonce)::\n'
        _agsvc=/exa.language_server_pb.LanguageServerService
        _agbody='{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}'
        _agout=''; _aglocked=0; _agfound=0; _agren=0; _agvia=''; _agtok=''; _agcap=\#(antigravityResponseMaxBytes)
        _aglend=$(($(date +%s) + 10))
        _agtime() { _agleft=$(($2 - $(date +%s))); [ "$_agleft" -gt 0 ] || return 1; [ "$_agleft" -lt "$1" ] || _agleft=$1; }
        _agwatch() { _agws=$1; shift; "$@" 2>/dev/null & _agwp=$!; ( sleep "$_agws"; kill "$_agwp" ) >/dev/null 2>&1 & _agww=$!; wait "$_agwp"; _agwr=$?; kill "$_agww" 2>/dev/null; return "$_agwr"; }
        _aglspost() {
          _agtime 3 "$_aglend" || return 1
          _agr=$(printf 'X-Codeium-Csrf-Token: %s\n' "$2" | curl -sk --noproxy '*' --max-time "$_agleft" -X POST "$1" -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' -H @- -d "$_agbody" -w '\n::AGHTTP:%{http_code}::' 2>/dev/null | head -c "$_agcap")
          _agc=${_agr##*::AGHTTP:}; _agc=${_agc%%::*}; _agr=${_agr%::AGHTTP:*}
          [ "$_agc" = 200 ] || return 1
          case "$_agr" in *"$3"*|*"${5:-$3}"*) printf '::AGPART:%s::\n%s\n' "$4" "$_agr"; return 0;; esac
          return 1
        }
        _agjob() { _agn=$1; shift; "$@" > "$_agd/$_agn" 2>/dev/null & }
        _agserver() {
          _agjob ls-summary _aglspost "$1$_agsvc/RetrieveUserQuotaSummary" "$2" '"remainingFraction"' ls-summary '"remaining_fraction"'
          _agjob ls-status _aglspost "$1$_agsvc/GetUserStatus" "$2" '"userStatus"' ls-status
          _agjob ls-configs _aglspost "$1$_agsvc/GetCommandModelConfigs" "$2" '"quotaInfo"' ls-configs
          wait
          _ags=$(cat "$_agd/ls-summary"); _agu=$(cat "$_agd/ls-status"); _agm=$(cat "$_agd/ls-configs")
          # Every quota source goes back; the parser picks what it can read.
          # Status alone is account metadata, not an answer.
          case "$_ags$_agm$_agu" in *'"remainingFraction"'*|*'"remaining_fraction"'*|*'"quotaInfo"'*) ;; *) return 1;; esac
          printf '%s\n%s\n%s\n' "$_ags" "$_agu" "$_agm"
        }
        _agports() {
          if command -v lsof >/dev/null 2>&1; then
            lsof -nP -a -iTCP -sTCP:LISTEN -p "$1" 2>/dev/null | awk 'NR>1 { n=split($9,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n] }'
          elif command -v ss >/dev/null 2>&1; then
            ss -ltnpH 2>/dev/null | awk -v p="pid=$1," 'index($0,p) { n=split($4,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n] }'
          fi | sort -un | head -n 8
        }
        _aglocal() {
          command -v curl >/dev/null 2>&1 || return 1
          ps -A -ww -o pid= -o args= 2>/dev/null | awk '/language_server/ && /--csrf_token/ && !/AGPART/ && tolower($0) ~ /antigravity/ { c=""; e=""; for (i=2; i<=NF; i++) { if ($i=="--csrf_token") c=$(i+1); else if (index($i,"--csrf_token=")==1) c=substr($i,14); if ($i=="--extension_server_port") e=$(i+1); else if (index($i,"--extension_server_port=")==1) e=substr($i,25); }; if (c!="") print $1, c, e }' | sort -n | while read -r _agp _agk _age; do
            for _agpt in $(_agports "$_agp"); do _agserver "https://127.0.0.1:$_agpt" "$_agk" && exit 0; done
            case "$_age" in ''|*[!0-9]*) ;; *) _agserver "http://127.0.0.1:$_age" "$_agk" && exit 0;; esac
          done
        }
        _agread() {
          _agj=''
          if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v security >/dev/null 2>&1 && security find-generic-password -s gemini -a antigravity >/dev/null 2>&1; then
            _agfound=1
            _agj=$(security find-generic-password -s gemini -a antigravity -w 2>/dev/null); _agrc=$?
            if [ "$_agrc" = 0 ] && [ -n "$_agj" ]; then _agvia=direct
            else
              _agj=''
              if [ "$_agrc" = 36 ] && command -v tmux >/dev/null 2>&1; then
                _agj=$(_agwatch 5 tmux run-shell 'security find-generic-password -s gemini -a antigravity -w')
              fi
              case "$_agj" in *go-keyring*|*ccess_token*|*ccessToken*) _agvia=tmux;; *) _agj=''; [ "$_agrc" = 36 ] && _aglocked=1;; esac
            fi
          fi
          if [ -z "$_agj" ] && [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && command -v secret-tool >/dev/null 2>&1; then
            _agj=$(_agwatch 5 secret-tool lookup service gemini username antigravity)
            [ -n "$_agj" ] && { _agfound=1; _agvia=direct; }
          fi
          if [ -z "$_agj" ]; then
            for _agf in "$HOME/.gemini/antigravity-cli"/* "$HOME/.gemini/antigravity"/*; do
              [ -f "$_agf" ] && [ -r "$_agf" ] || continue
              _agsz=$(wc -c < "$_agf" 2>/dev/null); [ $((${_agsz:-0} + 0)) -le 65536 ] || continue
              grep -q '"access_token"[[:space:]]*:[[:space:]]*"ya29\.' "$_agf" 2>/dev/null || continue
              _agj=$(cat "$_agf" 2>/dev/null); _agfound=1; _agvia=direct; break
            done
          fi
          case "$_agj" in
            go-keyring-base64:*) _agj=$(printf '%s' "${_agj#go-keyring-base64:}" | tr -d '\r\n' | base64 --decode 2>/dev/null);;
            go-keyring-encoded:*) _agj=$(printf '%s' "${_agj#go-keyring-encoded:}" | tr -d '\r\n' | xxd -r -p 2>/dev/null);;
          esac
          _agtok=$(printf '%s' "$_agj" | tr -d '\r\n' | sed -n 's/.*"access_\{0,1\}[tT]oken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        }
        _agos=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$(uname -m 2>/dev/null)" in x86_64|amd64) _agarch=amd64;; aarch64|arm64) _agarch=arm64;; *) _agarch=$(uname -m 2>/dev/null);; esac
        _agua="antigravity/cli/1.4.12 (aidev_client; os_type=${_agos:-linux}; arch=${_agarch}; auth_method=consumer)"
        if [ \#(skipLocal ? "1" : "0") = 0 ]; then
          # The parallel local calls write here, one file per answer.
          _agd=$(mktemp -d 2>/dev/null) || { _agd="${TMPDIR:-/tmp}/rootshell-agy.$$"; mkdir -m 700 "$_agd" 2>/dev/null || _agd=''; }
          if [ -n "$_agd" ]; then
            _agout=$(_aglocal)
            { rm -f "$_agd"/ls-summary "$_agd"/ls-status "$_agd"/ls-configs; rmdir "$_agd"; } 2>/dev/null
          fi
        fi
        [ -n "$_agout" ] || _agread
        if [ \#(renewal ? "1" : "0") = 1 ] && [ -z "$_agout" ] && [ -n "$_agtok" ] && _agbin=$(command -v agy 2>/dev/null) && [ -n "$_agbin" ]; then
          if [ "$_agvia" = tmux ]; then
            tmux run-shell -b "\"$_agbin\" models </dev/null >/dev/null 2>&1" >/dev/null 2>&1 && _agren=1
          elif command -v setsid >/dev/null 2>&1; then
            ( setsid nohup "$_agbin" models </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1; _agren=1
          else
            ( nohup "$_agbin" models </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1; _agren=1
          fi
        fi
        if [ -n "$_agout" ]; then printf '%s\n' "$_agout"
        elif [ -n "$_agtok" ]; then printf '::AGTOKEN_\#(nonce)::\n%s\n%s\n' "$_agtok" "$_agua"
        elif [ "$_aglocked" = 1 ]; then printf '::AGLOCKED_\#(nonce)::\n'
        elif [ "$_agfound" = 0 ]; then printf '::AGNONE_\#(nonce)::\n'
        else printf '::AGERR_\#(nonce)::\n'; fi
        [ "$_agren" = 1 ] && printf '::AGRENEWED_\#(nonce)::\n'
        printf '::AGE_\#(nonce)::\n'

        """#
    }

    /// Separates candidate credentials inside a copilot payload. Static on
    /// purpose (no nonce): it is payload structure, not protocol framing.
    static let copilotSourceSeparator = "::CPSRC::"

    /// Copilot's GitHub token can live in several places. Unlike claude,
    /// EVERY available source is emitted, `::CPSRC::`-separated, rather
    /// than only the first: a revoked token in one store would otherwise
    /// shadow a perfectly good one elsewhere forever — the app blacklists
    /// the refused token, re-probes, and the probe would hand it the same
    /// store again. The app selects the first candidate it has not already
    /// seen rejected.
    ///
    /// Emission order mirrors Copilot CLI's own documented resolution —
    /// env tokens FIRST, then the stored OAuth credential, then gh —
    /// because attribution follows it: a valid-but-wrong-account token is
    /// never rejected, so ranking a source above one the CLI actually
    /// resolves would pin usage to an account the running CLI is not even
    /// using. Editor sign-in files are not part of the CLI's chain at all,
    /// so they come after everything the CLI would use, as final fallbacks.
    private static func copilotSection(nonce: String) -> String {
        var s = " printf '::CPB_\(nonce)::\\n';"
        s += " _cd=\"${XDG_CONFIG_HOME:-$HOME/.config}/github-copilot\";"
        s += " _got=0; _fail='';"
        // Copilot CLI's documented env precedence, first. Reachable because
        // `sh -lc` reads ~/.profile.
        s += " for _v in \"$COPILOT_GITHUB_TOKEN\" \"$GH_TOKEN\" \"$GITHUB_TOKEN\"; do"
        s += " case \"$_v\" in"
        s += " gh?_*|github_pat_*)"
        s += " printf '\(copilotSourceSeparator)\\n{\"github.com\":{\"oauth_token\":\"%s\"}}\\n' \"$_v\"; _got=1;;"
        s += " esac;"
        s += " done;"
        // Copilot CLI stores its OAuth token in the login Keychain under
        // the service "copilot-cli". Same structure as the Claude leg:
        // metadata query first (succeeds on a locked keychain, so exists
        // and readable stay separate facts), then classify the -w read by
        // EXIT CODE — 36 = errSecInteractionNotAllowed, which is every
        // detached SSH/tsshd exec channel on a Mac.
        s += " if [ \"$(uname -s 2>/dev/null)\" = Darwin ]"
        s += " && command -v security >/dev/null 2>&1"
        s += " && security find-generic-password -s copilot-cli >/dev/null 2>&1; then"
        s += " _t=$(security find-generic-password -s copilot-cli -w 2>/dev/null); _rc=$?;"
        s += " if [ \"$_rc\" = 0 ] && [ -n \"$_t\" ]; then"
        s += " printf '\(copilotSourceSeparator)\\n%s\\n' \"$_t\"; _got=1;"
        s += " elif [ \"$_rc\" = 36 ]; then"
        // A tmux server started from the desktop session retains keychain
        // access, and run-shell executes in the SERVER's context — the
        // read that exits 36 directly succeeds through it. Validate by
        // token shape so a tmux error can never be mistaken for a
        // credential. The item's content shape is undocumented (bare token
        // or JSON), so the payload is printed raw, not synthesize-wrapped.
        s += " _tt='';"
        s += " if command -v tmux >/dev/null 2>&1; then"
        s += " _tt=$(tmux run-shell 'security find-generic-password -s copilot-cli -w'"
        s += " 2>/dev/null); fi;"
        s += " case \"$_tt\" in"
        s += " *gho_*|*ghu_*|*github_pat_*)"
        s += " printf '\(copilotSourceSeparator)\\n%s\\n' \"$_tt\"; _got=1;;"
        s += " *) _fail=locked;;"
        s += " esac;"
        s += " else _fail=err; fi;"
        s += " fi;"
        // The CLI's plaintext store completes its stored-OAuth tier.
        // Token-sniff BEFORE cat: Copilot CLI's config.json exists on every
        // host that ever ran it but only carries a token in plaintext mode.
        // Printing a tokenless config would mark the provider answered and
        // hide the real store behind an unparseable payload.
        s += " for _f in \"${COPILOT_HOME:-$HOME/.copilot}/config.json\"; do"
        s += " if [ -e \"$_f\" ]; then"
        s += " if [ ! -r \"$_f\" ]; then _fail=err;"
        s += " elif grep -Eq 'gh[a-z]_[A-Za-z0-9_]|github_pat_' \"$_f\" 2>/dev/null; then"
        s += " printf '\(copilotSourceSeparator)\\n';"
        s += " if cat \"$_f\" 2>/dev/null; then printf '\\n'; _got=1; else _fail=err; fi;"
        s += " fi;"
        s += " fi;"
        s += " done;"
        // gh is Copilot CLI's own documented fallback. It manages its own
        // keyring, which a detached channel cannot unlock either — so the
        // same tmux bridge applies. A missing or signed-out gh sets no
        // _fail: that is ordinary absence, not an error. Bare tokens are
        // shape-validated ([A-Za-z0-9_] only, JSON-safe) and synthesized
        // into the hosts.json shape so the app has one Copilot parser.
        s += " if command -v gh >/dev/null 2>&1; then"
        s += " _t=$(gh auth token 2>/dev/null);"
        s += " case \"$_t\" in"
        s += " gh?_*|github_pat_*)"
        s += " printf '\(copilotSourceSeparator)\\n{\"github.com\":{\"oauth_token\":\"%s\"}}\\n' \"$_t\"; _got=1;;"
        s += " *)"
        s += " if command -v tmux >/dev/null 2>&1; then"
        s += " _tt=$(tmux run-shell 'gh auth token' 2>/dev/null);"
        s += " case \"$_tt\" in"
        s += " gh?_*|github_pat_*)"
        s += " printf '\(copilotSourceSeparator)\\n{\"github.com\":{\"oauth_token\":\"%s\"}}\\n' \"$_tt\"; _got=1;;"
        s += " esac;"
        s += " fi;;"
        s += " esac;"
        s += " fi;"
        // Editor sign-in files LAST: they are not in Copilot CLI's chain
        // at all, so anything the CLI would actually use — including gh —
        // must outrank them. They still matter as the final fallback (and
        // as the only login-bearing source for cross-host account keys).
        s += " for _f in \"$_cd/apps.json\" \"$_cd/hosts.json\"; do"
        s += " if [ -e \"$_f\" ]; then"
        s += " if [ ! -r \"$_f\" ]; then _fail=err;"
        s += " elif grep -Eq 'gh[a-z]_[A-Za-z0-9_]|github_pat_' \"$_f\" 2>/dev/null; then"
        s += " printf '\(copilotSourceSeparator)\\n';"
        s += " if cat \"$_f\" 2>/dev/null; then printf '\\n'; _got=1; else _fail=err; fi;"
        s += " fi;"
        s += " fi;"
        s += " done;"
        s += " if [ \"$_got\" = 0 ]; then case \"$_fail\" in"
        s += " locked) printf '::CPLOCKED_\(nonce)::\\n';;"
        s += " err) printf '::CPERR_\(nonce)::\\n';;"
        s += " *) printf '::CPNONE_\(nonce)::\\n';;"
        s += " esac; fi;"
        s += " printf '::CPE_\(nonce)::\\n';"
        return s
    }

    /// Parses the probe output. Tolerant by design: a truncated response
    /// yields whatever sections arrived intact, and a section cut off before
    /// its end marker yields NO readout for that provider rather than a
    /// false negative.
    static func parse(output: String, nonce: String) -> AgentUsageProbeResult {
        var result = AgentUsageProbeResult()

        // `isNewline`, never a comparison against "\n": in Swift "\r\n" is a
        // single Character, so searching for "\n" would parse CRLF output as
        // one line.
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)

        var current: AgentUsageProvider?
        var marker: AgentUsageCredentialReadout?
        var payloadLines: [String] = []
        var tokenLines: [String]?

        func close(_ provider: AgentUsageProvider) {
            // A marker beats accumulated payload: a partial `cat` followed by
            // an error marker is unreadable, not a half-credential.
            if let marker {
                result.readouts[provider] = marker
            } else if !payloadLines.isEmpty {
                result.readouts[provider] = .payload(payloadLines.joined(separator: "\n"))
            }
            // An empty, marker-less section stays a non-answer.
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "::CLB_\(nonce)::":
                current = .claude; marker = nil; payloadLines = []
            case "::CXB_\(nonce)::":
                current = .codex; marker = nil; payloadLines = []
            case "::CPB_\(nonce)::":
                current = .copilot; marker = nil; payloadLines = []
            case "::OMB_\(nonce)::":
                current = .omp; marker = nil; payloadLines = []
            case "::CLE_\(nonce)::":
                if current == .claude { close(.claude) }
                current = nil
            case "::CXE_\(nonce)::":
                if current == .codex { close(.codex) }
                current = nil
            case "::CPE_\(nonce)::":
                if current == .copilot { close(.copilot) }
                current = nil
            case "::OME_\(nonce)::":
                if current == .omp { close(.omp) }
                current = nil
            case "::AGB_\(nonce)::":
                current = .antigravity; marker = nil; payloadLines = []; tokenLines = nil
            case "::AGE_\(nonce)::":
                if current == .antigravity {
                    close(.antigravity)
                    if let tokenLines, tokenLines.count == 2, !tokenLines[0].isEmpty {
                        result.antigravityToken = AgentUsageAntigravityToken(
                            accessToken: tokenLines[0], userAgent: tokenLines[1])
                    }
                }
                current = nil
            case "::AGRENEWED_\(nonce)::":
                if current == .antigravity { result.antigravityRenewed = true }
            case "::AGTOKEN_\(nonce)::":
                if current == .antigravity { tokenLines = [] }
            case _ where tokenLines.map { $0.count < 2 } == true && current == .antigravity:
                // The token and user agent, never part of a payload.
                tokenLines?.append(trimmed)
            case "::CLNONE_\(nonce)::", "::CXNONE_\(nonce)::", "::CPNONE_\(nonce)::",
                 "::OMNONE_\(nonce)::", "::AGNONE_\(nonce)::":
                if current != nil { marker = .absent }
            case "::CLERR_\(nonce)::", "::CXERR_\(nonce)::", "::CPERR_\(nonce)::",
                 "::OMERR_\(nonce)::", "::AGERR_\(nonce)::":
                if current != nil { marker = .unreadable(keychainLocked: false) }
            case "::CLLOCKED_\(nonce)::", "::CPLOCKED_\(nonce)::", "::AGLOCKED_\(nonce)::":
                if current != nil { marker = .unreadable(keychainLocked: true) }
            default:
                if current != nil, !trimmed.isEmpty { payloadLines.append(line) }
            }
        }
        // A section still open here never saw its end marker: truncated
        // output, so no readout is recorded and the caller retries.

        return result
    }
}
