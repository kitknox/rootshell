# rootshell push protocol v1

This document describes the wire format between a sender (`rootshell-notify`
on a computer), the relay (`push.rootshell.com`), and the rootshell app on a
device. The reference implementation is `envelope/` in this directory; the
Swift side lives in `Packages/RootshellPushKit`.

## Overview

```
computer ──(sealed envelope, sender credential)──> relay ──(APNs)──> device
```

The relay is stateless. The device registers its APNs token with the relay
and receives a signed device credential; from that it mints signed sender
credentials (`rsc1.`) for each computer. A sender credential carries, sealed
by the relay's own key, everything the relay needs to deliver: the device's
APNs token, a device id and a sender id. The relay stores nothing between
requests. The device hands each computer a pairing bundle containing the
relay URL, a sender credential and the device public key. The computer seals
every notification to that public key; the relay validates structure,
enforces quotas, and forwards the ciphertext inside an APNs payload. Only the
device can open it.

## Cryptography

HPKE (RFC 9180), base mode, single shot.

| Component | Value                                                   |
|-----------|---------------------------------------------------------|
| KEM       | X-Wing (ML-KEM-768 + X25519), HPKE id `0x647a`          |
| KDF       | HKDF-SHA256 (`0x0001`)                                  |
| AEAD      | AES-256-GCM (`0x0002`)                                  |
| info      | `rootshell-push/v1`                                     |
| AAD       | `eid:<event id>`                                        |

Sizes: public key 1216 bytes, private key seed 32 bytes, encapsulation
1120 bytes.

Binding the event id into the AAD means the relay (or anyone) cannot re-label
an envelope as a different event, and a replayed envelope keeps its original
dedupe key.

## Envelope

The object a sender posts:

```json
{"v":1,"enc":"<base64url, 1120 bytes>","ct":"<base64url>","eid":"<event id>"}
```

- `v`: protocol version, `1`.
- `enc`: HPKE encapsulated key, base64url without padding.
- `ct`: AEAD ciphertext of the header JSON, base64url without padding.
- `eid`: event id, `^[A-Za-z0-9._:-]{1,64}$`. Used for dedupe and as AAD.

Structural limits the relay checks without keys: `enc` decodes to exactly
1120 bytes; `ct` decodes to between 16 and 1616 bytes. The whole envelope
must fit within the 4 KiB APNs payload together with `aps`.

## APNs payload

The relay forwards the envelope under the `rs` key and adds the identity it
recovered from the sender credential:

```json
{"aps":{"alert":{"title":"rootshell","body":"Encrypted notification. Open rootshell to view."},
        "mutable-content":1,"sound":"default","category":"com.rootshell.push"},
 "rs":{"v":1,"enc":"...","ct":"...","eid":"...","sid":"<sender id>","did":"<device id>"}}
```

Sent as `apns-push-type: alert`. The alert text is a placeholder the
notification service extension replaces after decryption; it is only ever
seen if the extension fails to run, and the extension writes the same string
itself in that case.

The payload deliberately carries no `content-available`. Waking the app to
decrypt a push the extension is already decrypting makes both race on the
dedupe claim, and whichever loses blanks the notification.

`sid` lets the device attribute (and revoke) a sender; `did` lets it drop
pushes addressed to a previous registration. `eid` is also used as the
`apns-collapse-id`, so a retried push collapses on the device instead of
showing twice.

## Header (plaintext)

```json
{
  "v": 1,
  "kind": "agent",
  "agent": "claude-code",
  "status": "done",
  "title": "Claude Code · rootshell",
  "body": "Finished the refactor and ran the tests.",
  "thread": "3f1a9c0b2d4e5f60",
  "route": {
    "pane": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
    "tmux_pane": "%3",
    "tmux_server": "dev:/tmp/tmux-1000/default,42410,1788022920",
    "tmux_session": "main",
    "host": "user@dev.example",
    "cwd": "/home/user/example-project"
  }
}
```

| Field    | Required | Notes                                                    |
|----------|----------|----------------------------------------------------------|
| `v`      | yes      | `1`                                                      |
| `kind`   | yes      | `agent` or `generic`                                     |
| `agent`  | no       | `claude-code`, `codex`, ...                              |
| `status` | no       | `done`, `blocked`, `failed`, `info`                      |
| `title`  | yes      | at most 120 characters                                   |
| `body`   | no       | at most 600 characters (senders use 200 for summaries)   |
| `thread` | no       | opaque per-session id for grouping                       |
| `route`  | no       | all fields optional                                      |

For control-mode routing, `tmux_server` is the opaque tmux server-lifetime
identity `(host, socket_path, server pid, server start time)`. tmux pane IDs
are allocated server-wide, so the pair `(tmux_server, tmux_pane)` identifies
the same underlying pane through every `tmux -CC` client and on every paired
rootshell device. `pane` remains the rootshell surface UUID for ordinary
local and SSH panes.

Herdr routes add three optional fields:

| Field | Meaning |
|-------|---------|
| `herdr_server` | Lowercase SHA-256 of `hostname + NUL + effective numeric UID + NUL + socket path` (UTF-8, no trailing NUL). |
| `herdr_terminal` | Opaque `terminal_id` returned by herdr's `pane.get` API. |
| `herdr_pane` | Public pane ID, such as `w1:p2`; a hint, never sufficient for routing alone. |

The hostname is the full result of `gethostname` / `hostname`; the UID is
decimal without leading zeros. The socket path is the path herdr resolves
for the session, without additional symlink resolution. Raw socket paths and
UIDs are not included in the route. This namespace is shared across control
clients; the terminal ID distinguishes terminals within it, including across
server restarts. Public pane and tab IDs can change when a terminal moves.

The notifier queries `pane.get` at `HERDR_SOCKET_PATH` using `HERDR_PANE_ID`.
Herdr resolves old pane aliases after moves. Lookup is limited to one second
and 64 KiB; failure retains `herdr_pane` but omits the canonical identity.
`HERDR_BIN_PATH`, tab IDs, and workspace IDs are not required.

Receivers prefer a unique live match on `(herdr_server, herdr_terminal)` in
regular or fallback control mode. If no such match exists, an exact `pane`
UUID can still identify an ordinary local/SSH tab running the herdr TUI.
Control gateways and projected panes are excluded from this UUID path.
Ambiguous matches remain unresolved; descriptive host/cwd hints never select
a destination. The fields are optional additions to protocol version 1;
older receivers ignore them and retain ordinary-tab routing.

The serialized header must be at most 1600 bytes. Unknown fields are
ignored by receivers. There are no attachments.

## Credentials

Credentials are opaque strings minted and verified by the relay; senders and
devices never parse them.

| Prefix  | Holder   | Purpose                                                  |
|---------|----------|----------------------------------------------------------|
| `rsd1.` | device   | authenticates `POST /v1/senders`                         |
| `rsc1.` | computer | authenticates `POST /v1/push`; encodes device + sender id|

A device credential is bound to one APNs registration. Re-registering (new
APNs token, reinstall) yields a new device id, and sender credentials minted
under the old one are rejected with `410`; the computer must pair again.

## Pairing bundle

```
rspair1.<base64url(json)>
```

```json
{"server":"https://push.rootshell.com","label":"Test iPhone","cred":"rsc1....","pk":"<base64 std public key>"}
```

`server` must be `https` with no credentials, query or fragment. `cred` must
be non-empty and start with `rsc1.`. The bundle is shown once on the device;
the relay never receives `pk`.

## Relay endpoints

Errors are JSON `{"error":"<code>","message":"<text>"}`.

| Method | Path           | Auth                    | Body / Response |
|--------|----------------|-------------------------|-----------------|
| POST   | `/v1/devices`  | none                    | `{"apns_token","env"?}` → `201 {"cred":"rsd1....","did":"..."}` |
| POST   | `/v1/senders`  | `Bearer rsd1....`       | `{"label"?}` → `201 {"cred":"rsc1....","sid":"..."}` |
| POST   | `/v1/push`     | `Bearer rsc1....`       | `{"v","enc","ct","eid","priority"?}` → `202` |
| GET    | `/healthz`     | none                    | `200` |

`priority` is `high` or `normal` (default `high`). Push status codes: `401`
unknown or malformed credential; `410` device no longer registered (the
credential's device id is stale or APNs reports the token unregistered);
`429` rate limited (`Retry-After` seconds); `503` retry later; `400`/`502`
with a JSON error body. Senders retry once on `503` and network errors.

## Revocation

The relay keeps no sender list, so revocation happens on the device: it
records the `sid` of each credential it mints and ignores pushes whose `sid`
it has revoked. Dropping a device registration (`did` changes) invalidates
every sender at once.

## Idempotency

The relay sets `apns-collapse-id` to the `eid`, so a sender retry after a
timeout replaces rather than duplicates the notification. The device also
dedupes on `eid` across the notification extension and the app.

## Trust model

The relay is treated as honest-but-curious infrastructure. It never holds
device private keys or plaintext, so it cannot read titles, bodies or
routes. It does see, per request only:

- which sender id pushes to which device id, and when;
- envelope sizes, event ids and priority;
- APNs tokens (needed to deliver).

A compromised relay can drop, delay, or replay ciphertext, or forge metadata
(event ids are bound to the ciphertext, so a forged id fails to open). It
cannot forge readable notifications for a device without its public key, and
the public key alone lets anyone who obtains a pairing bundle send to that
device; treat bundles as secrets and revoke senders you no longer use.

Senders keep their credential and the device public key in
`~/.config/rootshell-push/config.json` (0600). The sender scrubs
credential-shaped substrings from summaries before sealing; this is a best
effort, not a guarantee, so users should treat notification text as they
would any summary of an agent's output.

## Limits

| Item                  | Limit          |
|-----------------------|----------------|
| header JSON           | 1600 bytes     |
| title / body          | 120 / 600 chars|
| event id              | 64 chars       |
| sender timeout        | 10 s, one retry|
