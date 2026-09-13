# Herdr notification testing — 0.2.9 candidate

The candidate is local only. Test with the updated rootshell app before
approving publication. Existing pairings and hook installations are unchanged.

From the rootshell repository root on an Apple silicon Mac:

```sh
export ROOTSHELL_NOTIFY_TEST_BIN="$PWD/push/dist/0.2.9/rootshell-notify_darwin_arm64"
"$ROOTSHELL_NOTIFY_TEST_BIN" version
```

For another host, copy its corresponding binary from `push/dist/0.2.9/` and
set `ROOTSHELL_NOTIFY_TEST_BIN` to that executable's absolute path. Run the
commands below inside the pane being tested, with the variable available there.
The candidate uses existing pairings; these commands send real test notifications.

## Ordinary herdr in a regular tab

1. Open an ordinary local or SSH tab and run the stock herdr TUI.
2. From a herdr pane, send:
   ```sh
   "$ROOTSHELL_NOTIFY_TEST_BIN" send --title "Herdr routing test" --body "Return to the source tab"
   ```
3. Switch to another rootshell tab, then tap the notification. It should
   return to the exact originating rootshell tab. Internal herdr pane
   selection stays under the TUI's control.
4. Repeat with socket lookup deliberately disabled for just this command:
   ```sh
   HERDR_SOCKET_PATH= "$ROOTSHELL_NOTIFY_TEST_BIN" send --title "Herdr ordinary-tab fallback"
   ```
   Delivery and ordinary-tab routing should still work.

## Regular and fallback control modes

Repeat with the Rootshell fork in regular control mode, the fork with Debug's
forced fallback enabled, and stock herdr using automatic fallback:

1. Send a notification from a split pane, switch to another tab/workspace,
   and tap it. The original terminal should become focused.
2. Send a notification, move its terminal to another tab/workspace, then
   tap it. The terminal's new location should open.
3. Keep the shell running across a move and send another notification.
   The inherited old pane ID should resolve to the moved terminal.
4. Test a named herdr session alongside the default session, including
   matching public pane IDs. Notifications must select the correct session.
5. Tap while the app is restoring/reconnecting. It may resolve for up to
   60 seconds. A closed/replaced terminal or an ambiguous duplicate control
   attachment must not select an unrelated pane or the control gateway.

## Agent alerts and regressions

Use the candidate directly to exercise a hook without changing installed hooks:

```sh
printf '%s\n' '{"hook_event_name":"Stop","session_id":"herdr-manual-test","cwd":"/work/example","last_assistant_message":"Test complete."}' |
  "$ROOTSHELL_NOTIFY_TEST_BIN" hook --agent codex
```

- With existing notification settings unchanged, check background delivery,
  viewed-pane suppression, and duplicate suppression when screen detection
  already reported the same agent status. Use a fresh `session_id` for each
  independent test so event deduplication does not hide it.
- Explicit `send` and `test` notifications should still appear while viewing
  their originating pane.
- Verify plain local/SSH tabs and tmux control panes still route normally.
- Confirm ordinary herdr still routes with the previously installed notifier.

## Publication gate

After testing and explicit approval, recheck the published version, build the
next unused patch release if needed, and publish using the relay repository's
`deploy/publish-client.sh`. That script updates the public installer and
`releases/LATEST`; do not run it during candidate testing.
