# Zforge stage 3 — window lifecycle (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Zforge `c127bca`
(clean), same build as the earlier stages (`Zforge.debug.dylib` `da557f4a8d41b160`; simulated copy:
same `__text`). Zforge repository only read. Real runs announced before and after.

## Test and new capabilities

`testViewModeIsPerWindowAndLastClosedWindowRestoresIt`: ⌘N second window, commands reaching the
focused window, toolbar control in a specific window, closing windows with their close buttons
(including the last one), ⌘Q and relaunch in the same test.

## Tool change

**⌘Q made the simulated delivery fail.** The runner polls the agent through the app's accessibility
attribute until the record's last event is posted; when the record quits the app, the poll fails
(`kAXErrorCannotComplete`), the shim reported a synthesis error, XCTest retried ⌘Q against a process
that had exited and the test failed (`Application io.libor.Zforge is not running`). Hardware synthesis
completes whatever the app does with the events, so the shim now treats a failed status poll as a
completed delivery when the target process terminates within 2 s.

The screen guard now also logs the time and position of each hardware (user) mouse-down and key-down,
to correlate failures with user input.

## Results

| | Real | Simulated | Assertion | Activity tree |
|---|---|---|---|---|
| unmodified | pass 31.65 s | pass 33.51 s | — | identical (195) |
| closesave regression: closing a window no longer saves its mode, `2b608ae29b376186` | fail `ZforgeUITests.swift:193` | fail `:193` | same (`restored.waitForExistence`) | 167 = 167; async debug-description order |

Screen guard: real 2–4 frontmost changes, 202–306 synthetic events; simulated 0.

## Revalidation after the tool change (simulated, no screen)

- Sample suite 8/8 pass; HOVER/MENU/FOCUS regressions fail on the same lines as their real runs (one
  test each); failing-test trees differ from the real ones only in post-failure polling.
- All validated Zforge tests pass with trees identical to their real references, except as follows.
- `testCompactToolbarMenusOpenFromTheirToolbarButtons` failed when the validated tests ran together.
  Cause: test-order dependency in Zforge `c127bca` — when it runs right after
  `testBlankAreaUsesMoreMenuInEveryView`, the overflow menu lacks "Compress Selected"
  (`ZforgeUITests.swift:914`). Confirmed in the **real** mode with the same pair (fails the same way,
  identical trees 656 + 71 steps), so it is pre-existing, not a tool divergence; alone it passes in
  both modes. Reported for separate handling; the revalidation script now runs it alone, as in its
  real reference.

## Verdict

`testViewModeIsPerWindowAndLastClosedWindowRestoresIt`: **equivalent** after the ⌘Q fix (outcome,
identical tree, regression on the same assertion). Simulated 6 % slower.
