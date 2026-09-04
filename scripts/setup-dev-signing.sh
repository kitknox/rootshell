#!/bin/bash
#
# setup-dev-signing.sh
#
# Generates Configuration/DeveloperSettings.xcconfig so this checkout builds
# under your own paid Apple Developer team instead of upstream's (com.kk2 /
# team D97ZME3ET2). See docs/contributor-signing.md for how the override
# mechanism works.
#
# Without Apple's multicast grant it also derives a stripped copy of the App
# Store configuration's entitlements.
#
# Both files are gitignored, like Configuration/Secrets.xcconfig, so your Team
# ID and org identifier stay out of commits and PRs.
#
# Runs interactively by default. Every value can also be passed as a flag,
# for an agent that already has the answers (from its operator, or from a
# prior run) to call non-interactively. Run --help for details.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: setup-dev-signing.sh [OPTIONS]

Writes Configuration/DeveloperSettings.xcconfig (gitignored) so this checkout
signs under your own Apple Developer team instead of upstream's. With no
options, prompts interactively for each value. Any value given as a flag
skips its prompt; supply all of them for a fully non-interactive run.

Assumes a PAID Apple Developer Program membership. This app signs against
App Groups, Keychain Sharing, and an iCloud container; the free "Personal
Team" path is untested here.

OPTIONS
  -t, --team TEAM_ID           Apple Developer Team ID: exactly 10 uppercase
                                letters/digits (developer.apple.com, under
                                Membership). Required -- no default.

  -o, --org ORG_ID              Org identifier, domain-reversed, e.g.
                                org.yourname. Two or more dot-separated parts
                                of letters, digits, and hyphens (no
                                underscores). Required -- no default.

  -i, --icloud CONTAINER_ID     iCloud container ID to register.
                                Default: iCloud.<org_id>.rootshell

  -m, --multicast yes|no        Whether Apple has granted this team the
                                multicast networking entitlement. "no"
                                (default) writes a derived
                                AppStore-dev.entitlements with that one
                                capability stripped, so the App Store
                                configuration still signs. Re-run with "yes"
                                once the grant arrives.

  -y, --yes                     Overwrite an existing DeveloperSettings.xcconfig
                                without prompting.

  -h, --help                    Print this message and exit 0.

Also accepted with --flag=value.

NON-INTERACTIVE MODE
  --team and --org are always required somehow -- they identify a specific
  human's paid developer account and cannot be inferred from the repo. If
  stdin is not a terminal (e.g. an agent invoking this as a subprocess) and
  either is missing, the script exits 1 immediately naming the missing flag,
  rather than hanging on a read. --icloud and --multicast fall back
  to their defaults instead of prompting when stdin is not a terminal.

EXIT STATUS
  0  DeveloperSettings.xcconfig (and, if needed, the derived App Store
     entitlements) were written.
  1  Bad input, a required value is missing in non-interactive mode, or the
     existing settings file was left in place (declined overwrite, or
     --yes was not passed in non-interactive mode).

EXAMPLES
  # Interactive (a human at a terminal):
  scripts/setup-dev-signing.sh

  # Fully non-interactive, e.g. an agent that already gathered the answers
  # from its operator:
  scripts/setup-dev-signing.sh --team ABCDE12345 --org org.yourname \
      --multicast no --yes

  # Re-run to pick up the multicast grant once Apple approves it, keeping
  # the same team/org:
  scripts/setup-dev-signing.sh --team ABCDE12345 --org org.yourname \
      --multicast yes --yes
USAGE
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
    echo "error: not inside a git repository" >&2
    exit 1
fi

settings_file="$repo_root/Configuration/DeveloperSettings.xcconfig"
relative_path="Configuration/DeveloperSettings.xcconfig"

app_entitlements="$repo_root/rootshell/Entitlements/AppStore.entitlements"
app_dev_entitlements="$repo_root/rootshell/Entitlements/AppStore-dev.entitlements"
app_dev_relative="rootshell/Entitlements/AppStore-dev.entitlements"

for path in "$relative_path" "$app_dev_relative"; do
    if ! git -C "$repo_root" check-ignore -q "$path"; then
        echo "error: $path is not gitignored -- refusing to write" >&2
        echo "       account-specific settings into a trackable file. Restore" >&2
        echo "       the .gitignore entry first." >&2
        exit 1
    fi
done

validate_team_id() {
    printf '%s' "$1" | grep -Eq '^[A-Z0-9]{10}$'
}

validate_org_id() {
    # Bundle identifiers accept only alphanumerics, '.' and '-'; an
    # underscore here fails at signing time with a much less obvious error.
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
}

team_id=""
org_id=""
icloud_container=""
mc_answer=""
assume_yes=0

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--team)
            team_id="${2:?--team requires a value}"; shift 2 ;;
        --team=*)
            team_id="${1#*=}"; shift ;;
        -o|--org)
            org_id="${2:?--org requires a value}"; shift 2 ;;
        --org=*)
            org_id="${1#*=}"; shift ;;
        -i|--icloud)
            icloud_container="${2:?--icloud requires a value}"; shift 2 ;;
        --icloud=*)
            icloud_container="${1#*=}"; shift ;;
        -m|--multicast)
            mc_answer="${2:?--multicast requires yes or no}"; shift 2 ;;
        --multicast=*)
            mc_answer="${1#*=}"; shift ;;
        -y|--yes)
            assume_yes=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "error: unrecognized argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

if [ -n "$team_id" ] && ! validate_team_id "$team_id"; then
    echo "error: --team must be exactly 10 uppercase letters and digits" >&2
    exit 1
fi
if [ -n "$org_id" ] && ! validate_org_id "$org_id"; then
    echo "error: --org must be two or more dot-separated parts of letters," >&2
    echo "       digits, and hyphens only (no underscores)" >&2
    exit 1
fi
if [ -n "$mc_answer" ]; then
    case "$mc_answer" in
        y|Y|yes|YES|Yes) mc_answer="yes" ;;
        n|N|no|NO|No)    mc_answer="no" ;;
        *)
            echo "error: --multicast must be 'yes' or 'no'" >&2
            exit 1 ;;
    esac
fi

interactive=0
[ -t 0 ] && interactive=1

if [ -z "$team_id" ]; then
    if [ "$interactive" -ne 1 ]; then
        echo "error: --team is required (no TTY on stdin for a prompt)." >&2
        echo "       Pass --team <TEAMID>. Run with --help for details." >&2
        exit 1
    fi
    cat <<BANNER
rootshell dev-signing setup
============================
This writes $relative_path -- gitignored, like
Configuration/Secrets.xcconfig beside it -- so Xcode signs every target under
your own Apple Developer team and bundle-identifier namespace instead of
upstream's.

BANNER
    cat <<'WARNING'
This assumes a PAID Apple Developer Program membership. This app signs
against App Groups, Keychain Sharing, and an iCloud container. The free
Apple ID "Personal Team" path is untested here, so if a build fails on
entitlements under one, suspect the account before this script.

WARNING
    read -r -p "1. Your Apple Developer Team ID (developer.apple.com, e.g. ABCDE12345): " team_id
    if ! validate_team_id "$team_id"; then
        echo "error: a Team ID is exactly 10 uppercase letters and digits" >&2
        exit 1
    fi
fi

if [ -z "$org_id" ]; then
    if [ "$interactive" -ne 1 ]; then
        echo "error: --org is required (no TTY on stdin for a prompt)." >&2
        echo "       Pass --org <org.identifier>. Run with --help for details." >&2
        exit 1
    fi
    read -r -p "2. Your org identifier, domain-reversed (e.g. org.yourname): " org_id
    if ! validate_org_id "$org_id"; then
        echo "error: an org identifier must be two or more dot-separated parts of" >&2
        echo "       letters, digits, and hyphens only (no underscores)" >&2
        exit 1
    fi
fi

default_icloud="iCloud.${org_id}.rootshell"
if [ -z "$icloud_container" ]; then
    if [ "$interactive" -eq 1 ]; then
        read -r -p "3. iCloud container ID to register [$default_icloud]: " icloud_container
    fi
    icloud_container="${icloud_container:-$default_icloud}"
fi

if [ -z "$mc_answer" ]; then
    if [ "$interactive" -eq 1 ]; then
        # AppStore.entitlements asks for
        # com.apple.developer.networking.multicast, the only capability in
        # this project that Apple grants by request rather than by checkbox.
        # Without it the whole app fails to sign under the App Store
        # configuration, so default to the stripped-down entitlements: the
        # cost is croc's LAN peer discovery, nothing else.
        read -r -p "4. Has Apple granted your team the multicast entitlement? [y/N] " has_mc
        case "$has_mc" in
            y|Y) mc_answer="yes" ;;
            *)   mc_answer="no" ;;
        esac
    else
        mc_answer="no"
    fi
fi
if [ "$mc_answer" = "yes" ]; then
    app_suffix=""
else
    app_suffix="-dev"
fi

cat <<EOF

About to write:

  Team ID:           $team_id
  Org identifier:    $org_id
  iCloud container:  $icloud_container
  App entitlements:  $([ -n "$app_suffix" ] && echo "a derived copy with multicast dropped" || echo "AppStore.entitlements, unchanged")
  App Store Connect: not touched -- this only affects local builds
EOF

if [ -e "$settings_file" ]; then
    if [ "$assume_yes" -eq 1 ]; then
        echo
        echo "$relative_path already exists -- overwriting (--yes)."
    elif [ "$interactive" -eq 1 ]; then
        echo
        read -r -p "That file already exists. Overwrite it? [y/N] " confirm
        case "$confirm" in
            y|Y) ;;
            *) echo "Aborted -- nothing written."; exit 0 ;;
        esac
    else
        echo "error: $relative_path already exists. Pass --yes to overwrite" >&2
        echo "       in non-interactive mode." >&2
        exit 1
    fi
fi

{
    echo "// DeveloperSettings.xcconfig -- generated by scripts/setup-dev-signing.sh"
    echo "// Gitignored. Re-run the script to regenerate; delete it to build as upstream."
    echo
    echo "ROOTSHELL_DEVELOPMENT_TEAM = $team_id"
    echo "ROOTSHELL_ORG_IDENTIFIER = $org_id"
    echo "ROOTSHELL_ICLOUD_CONTAINER = $icloud_container"
    if [ -n "$app_suffix" ]; then
        echo
        echo "// Signs AppStore$app_suffix.entitlements, which drops the"
        echo "// request-gated multicast capability so the App Store"
        echo "// configuration still signs. Clear this line once you have"
        echo "// the grant."
        echo "ROOTSHELL_APP_ENTITLEMENTS_SUFFIX = $app_suffix"
    fi
} > "$settings_file"
echo
echo "Wrote $relative_path"

# AppStore-dev.entitlements is derived, not tracked: a copy of the real file
# with the one request-gated capability removed. Every other value in it is a
# $(VARIABLE) reference, so it keeps tracking upstream renames without being
# regenerated.
if [ -n "$app_suffix" ]; then
    cp "$app_entitlements" "$app_dev_entitlements"
    plutil -remove 'com\.apple\.developer\.networking\.multicast' \
        "$app_dev_entitlements"
    echo "Wrote $app_dev_relative"
elif [ -e "$app_dev_entitlements" ]; then
    # You have the grant now; the stripped copy is no longer referenced.
    rm "$app_dev_entitlements"
    echo "Removed the stale $app_dev_relative"
fi

cat <<EOF

Next steps:
  - Open rootshell.xcodeproj in Xcode, sign in with the Apple ID for team
    $team_id, and build the rootshell-Standalone or rootshell-AppStore
    scheme. Automatic signing registers the new App ID / App Group / iCloud
    container on first build.
  - "git status" in this repo should show nothing new.
EOF

if [ -n "$app_suffix" ]; then
    cat <<'EOF'
  - Re-run this script if the app ever fails to sign after a pull. The
    derived copy holds variable references, not literals, so it survives
    renames -- only a changed set of capabilities calls for regenerating it.
EOF
fi
