# Keyboard focus taken by simulated apps — 2026-11-02

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display.

## Symptom

During offscreen runs the user could type in another app, but every so often the keyboard stopped
responding until they clicked the text field again. ScreenGuard reported no frontmost-application
change, no visible window and no synthetic event, because it does not watch keyboard focus.

## Cause

Menu tracking in AppKit and HIToolbox asks the window server for the keyboard with
`CPSStealKeyFocusReturningID` / `CPSStealKeyFocus` (CoreGraphics, implemented by SkyLight's
`SLPS*`). The process becomes the session's **key thief**: the window server routes every key to it
while another application stays frontmost. The simulated app opens its menus (context, toolbar,
emulated menu bar) in-process, so each one took the user's keyboard.

WindowServer log (unified log, `process == "WindowServer"`), lane run `affected-20261102-070959`,
user in ChatGPT:

```
[com.apple.SkyLight.processes:Focus] …[StealKeyFocusReturningID]: [DeferringManager] Updating policy {
    advicePolicy: .keyThief; frontmostProcess: … (ChatGPT) …
} for reason: key thief updated … (Zforge)
[com.apple.SkyLight:KeyboardEvent] active key thief - delivery manager destinations for kCGSEventKeyDown event: <keyboardFocus; pid: 54193; …>
```

Over 4 hours, all 153 `key thief updated` entries named the app under test (about 30 per minute
during lane runs); 43 of the user's key presses went to lane copies at 07:10–07:11.

## Fix

The app agent interposes (dyld `__interpose`; the agent is loaded at launch) `CPSStealKeyFocusReturningID`,
`CPSReleaseKeyFocusWithID`, `CPSStealKeyFocus` and `CPSReleaseKeyFocus`. When the agent is enabled the
requests are answered in-process (success, with IDs from the agent's own range that the release
accepts) and never reach the window server; when it is disabled they pass through. A simulated app
gets its keys from the agent, so menu keyboard navigation does not need the window server's focus.

Signatures, from the `SLPS*` disassembly: `StealKeyFocusReturningID(connection, options, uint32_t *outID)`
writes the ID on success; `ReleaseKeyFocusWithID(id)`.

## Evidence

Measure: count of WindowServer `key thief updated … (Zforge)` entries during a run (does not need
anyone to type).

| Run | Build | Tests | Outcome | Key thief updates |
|---|---|---|---|---|
| `keyfocus-before` (old agent) | `zforge-7fe52d8` | folder selection menu Option alternate + compact toolbar menus, 1 lane | 2/2 passed | **11** in 36 s |
| `keyfocus-after` (new agent) | same | same | 2/2 passed | **0** in 38 s; agent logged the requests it kept |
| `keyfocus-16` (new agent) | same | the 16 simulable Zforge tests, 3 lanes | 16/16 passed, guard clean for the lanes | **0** in 230 s |

Zforge change run (`affected-20261102-074729`, Zforge worktree build with the quiet unit-test host): 14 offscreen
tests in 3 lanes, 14/14 passed, **0** key thief updates in 191 s; the guard's 2 front changes are testmanagerd's
Automation Mode authentication (`coreautha`, 3 s).

The 4 visible windows in the `keyfocus-16` guard belong to a unit-test host started from another
build at the same time (`/private/tmp/zf-host-probe`), not to the lanes.

## Limits

- Activity trees were not diffed against real references in this change; outcomes match the earlier
  equivalence runs.
- ScreenGuard still does not watch keyboard focus; the WindowServer log is the check.
- Automation Mode (testmanagerd) is unchanged: offscreen runs still turn it on and show its indicator.
