# Building under your own Apple Developer team

rootshell's identifiers — `com.kk2.*`, `iCloud.rootshell`,
`group.com.kk2.ghostty` — are registered to upstream's team `D97ZME3ET2` and
can't be reused. Building for real means substituting your own.

This was verified against a paid Apple Developer Program membership. The app
signs against App Groups, Keychain Sharing, and an iCloud container, none of
which a free "Personal Team" can register; that path is untested here.

## Setup

```bash
scripts/setup-dev-signing.sh
```

Writes `Configuration/DeveloperSettings.xcconfig`, gitignored like
`Secrets.xcconfig` beside it, and — without the multicast grant below —
derives `rootshell/Entitlements/AppStore-dev.entitlements`. Delete both to
build as upstream again.

Then build the `rootshell-Standalone` (macOS) or `rootshell-AppStore`
(iOS/iPadOS/visionOS) scheme in Xcode, signed in as your team. Automatic
signing registers the App ID, App Group, and iCloud container on first build.

Sign in at **Xcode → Settings → Accounts** first. With no account signed in,
device and Mac Catalyst builds failed here; after signing in, the same commands
succeeded.

From the command line, automatic signing also needs `-allowProvisioningUpdates`.
Without it every target fails with "Automatic signing is disabled and unable to
generate a profile".

Don't use a `No Accounts: Add a new account in Accounts settings` line to
diagnose this — Xcode also emits it alongside an unrelated capability failure
with an account signed in and a valid team profile in use.

```bash
xcodebuild -project rootshell.xcodeproj -scheme rootshell-AppStore \
  -configuration ReleaseAppStore -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```

## Variables

Defined in `Configuration/Identity.xcconfig`. Override any of them in
`DeveloperSettings.xcconfig`.

| Variable | Default | Feeds |
| --- | --- | --- |
| `ROOTSHELL_DEVELOPMENT_TEAM` | `D97ZME3ET2` | `DEVELOPMENT_TEAM`, every target |
| `ROOTSHELL_ORG_IDENTIFIER` | `com.kk2` | every `PRODUCT_BUNDLE_IDENTIFIER`, the app groups, the keychain group |
| `ROOTSHELL_ICLOUD_CONTAINER` | `iCloud.rootshell` | the CloudKit container |
| `ROOTSHELL_APP_ENTITLEMENTS_SUFFIX` | empty | which App Store entitlements file is signed |

Set `ROOTSHELL_APP_ENTITLEMENTS_SUFFIX` only alongside a matching derived
entitlements file; the script writes the two together.

`ROOTSHELL_ICLOUD_CONTAINER` is set wholesale rather than derived from the org
identifier: changing it repoints the shipping container, which is a user-data
migration, not a rename.

Derived from those, not set directly:

| Variable | Value | Used by |
| --- | --- | --- |
| `ROOTSHELL_DEFAULT_APP_GROUP` | `group.$(ROOTSHELL_ORG_IDENTIFIER).ghostty` | VPN extension, widget, tunnel, helper |
| `ROOTSHELL_APP_GROUP` | the same, `.cn`-suffixed by `China.xcconfig` | app, push service |
| `ROOTSHELL_KEYCHAIN_GROUP_SUFFIX` | `$(ROOTSHELL_ORG_IDENTIFIER).ghostty-ios` | `.entitlements`, with `$(AppIdentifierPrefix)` |
| `ROOTSHELL_KEYCHAIN_ACCESS_GROUP` | `$(ROOTSHELL_DEVELOPMENT_TEAM).$(ROOTSHELL_KEYCHAIN_GROUP_SUFFIX)` | Swift, Info.plist |

The two app groups stay distinct on purpose: the VPN extension, widget,
tunnel, and helper sign against the non-`.cn` group even in a China build.
Don't collapse them without checking the `.cn` group is enabled on those
App IDs.

## How it reaches every target

No target sets `DEVELOPMENT_TEAM` itself — the string appears zero times in
`project.pbxproj` and once in `Identity.xcconfig`. Every configuration reaches
it: the six variant configurations through
`Debug-*.xcconfig` → `Debug.xcconfig` → `Base.xcconfig`, the bare
`Debug`/`Release` through a direct `baseConfigurationReference`, all three at
the project level; and `Helper.xcconfig` / `HelperTests.xcconfig`, attached at
target level by the helper targets, through their own `#include`.

`.entitlements` files reference the variables directly, and each target's
`Info.plist` carries the resolved strings. Code needing one at runtime reads it
back from the bundle rather than repeating the literal, so runtime values match
what was signed:

| Reader | Keys |
| --- | --- |
| `rootshell/Core/Security/AppIdentifiers.swift` | `RootshellDefaultAppGroup`, `RootshellKeychainAccessGroup`, `RootshellICloudContainer` |
| `rootshell-helper/Sources/SocketCommandServer.swift` | `RootshellAppBundleIdentifier`, `RootshellDevelopmentTeam` |
| `Packages/RootshellPushKit/.../PushConfiguration.swift` | `RootshellAppGroup` |

`rootshell-helper`'s source tree is separate from the app's, so it carries its
own copy of that lookup rather than importing one.

## Multicast

`AppStore.entitlements` asks for `com.apple.developer.networking.multicast`,
the one capability here that Apple grants by
[request](https://developer.apple.com/help/account/capabilities/capability-requests)
rather than by checkbox — it isn't in the [supported-capabilities
table](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
at all. Without the grant the whole app fails to sign under the App Store
configuration — clearing the override below and building for a device gives:

```
error: Provisioning profile "iOS Team Provisioning Profile: <your bundle id>"
doesn't include the Multicast Networking capability.
error: Entitlement com.apple.developer.networking.multicast requires approval
from Apple to include in a profile. Please request access to the associated
capability. To continue building for device during request processing, remove
entitlement and add upon approval.
```

Removing it until approval is what Apple's own message prescribes, and is what
the override does.

`ROOTSHELL_APP_ENTITLEMENTS_SUFFIX = -dev` signs `AppStore-dev.entitlements`,
which the script derives from the real file by dropping that one capability.
It is gitignored, not tracked. Clear the variable and delete the file once you
have the grant.

The derived copy holds `$(VARIABLE)` references, not literals, so upstream
renaming the app group or keychain group flows through with no regeneration.
Re-run the script only if the app starts failing to sign, or to pick up a
capability upstream has added. Note that the script strips exactly one key: a
second request-gated capability would need this mechanism revisited.

`Standalone.entitlements` and `China.entitlements` don't ask for multicast, so
those configurations need no derived file.

## VPN

Nothing about the VPN is gated. Network Extensions is an ordinary capability
that automatic signing enables for any paid team, so both paths run under your
own: `VPNTunnelExtension` on iOS, and on macOS the `rootshellvpn` host app with
its `tunnel` system extension.

The macOS side is worth knowing about, because no shared scheme builds it.
`rootshellvpn` embeds `tunnel` and owns `NETunnelProviderManager`; the Catalyst
app is a client that drives it over a Unix socket in the shared App Group
container (see `rootshell/Features/VPN/VPNControlProtocol.swift`). Building
`rootshell-Standalone` alone doesn't exercise either target.

Building those two directly doesn't currently work, for reasons unrelated to
signing. `tunnel` compiles app sources through
`rootshell/rootshell-Bridging-Header.h`, which imports `ghostty.h`; the
`GhosttyKitStandalone` xcframework ships only an
`ios-arm64_x86_64-maccatalyst` slice, while `rootshellvpn`'s only build
destinations are plain macOS. The bridging-header scan fails and every Swift
package module fails to resolve behind it. This reproduces on a clean checkout
of upstream with no `DeveloperSettings.xcconfig`, so it is not something these
overrides introduce.

Shipping a VPN app is a separate matter: App Review guideline 5.4 allows that
only from an organization account. That restricts distribution; an individual
account still signs the NetworkExtension entitlement, which is what building
for a device requires.

## What still won't work

- **croc's LAN peer discovery** — `com.apple.developer.networking.multicast` is
  what the override drops, so anything depending on it is gone until you have
  the grant.
- **Push and associated domains** — the entitlements name `push.rootshell.com`
  and `beta.rootshell.com`, which are upstream's domains.
- **`rootshellvpn` and `tunnel`** — they don't build at all, for the
  `ghostty.h` reason under VPN above.

## For maintainers

With no `DeveloperSettings.xcconfig` present, every resolved build setting is
identical to before this existed — compared with `-alltargets -showBuildSettings`
across all 8 configurations, nothing removed and nothing changed. Checkout needs
no extra steps.

If a build ever signs under an unexpected team, check for a stray
`Configuration/DeveloperSettings.xcconfig`.
