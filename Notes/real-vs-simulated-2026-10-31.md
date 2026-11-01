# Real vs simulated — sample suite, 2026-10-31

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display.
Follow-up to `Notes/feasibility-2026-10-29.md` ("No real run of the sample suite yet").
Real (screen-taking) runs were authorized by the user and announced immediately before starting.

## Method

- Four clean builds of `Sample/` (no agent, unmodified signatures) under
  `~/Library/Caches/dev.xcuitestsim/cmp/dd-{base,hover,menu,focus}` (deleted 2026-11-01; rebuilt with `Scripts/build-sample.sh`); the three regression builds compile
  `REGRESSION_HOVER`, `REGRESSION_MENU`, `REGRESSION_FOCUS` (the capabilities the agent emulates rather
  than merely delivers: tracking areas, menu bar, focus). The four app binaries differ (checked by hash).
- Each build's products were copied; the original ran **real** (stock xctestrun: only Xcode's own
  `libRPAC`/`libMainThreadChecker` insertions, no shim, no agent), the copy was prepared with
  `prepare-xctestrun.py` and ran **simulated**. Same test sources, same app code.
- Nothing the runner or app loads was under `~/Documents`; result bundles were written to
  `~/Library/Caches/dev.xcuitestsim/cmp/results`, moved on 2026-11-01 to
  `.local/results/cache-2026-11-01/cmp/results/` (real references and the runs cited here; logs also in
  `.local/results/2026-10-31/`; see `Notes/evidence-2026-11-01.md`).
- Comparison: outcome per test, failing assertion line and message, duration, and the full XCTest
  activity tree per test from the result bundle (attachments ignored; pids, addresses, durations and
  timestamps normalized).
- No retries, no timeout changes, no test changes.

## Results

### Unmodified build (8 tests)

| Test | Real | Simulated (run 1) | Simulated (run 2, after the fix below) | Activity tree real vs sim |
|---|---|---|---|---|
| testButtonClick | pass 5.85 s | pass 5.91 s | pass 5.83 s | identical |
| testContextMenu | pass 7.17 s | pass 7.39 s | pass 7.28 s | identical |
| testContextMenuEscapeCloses | pass 5.99 s | pass 6.41 s | pass 6.40 s | identical |
| testHover | pass 5.80 s | pass 6.13 s | pass 6.10 s | identical |
| testKeyboardShortcut | pass 4.38 s | pass 4.63 s | pass 4.54 s | identical |
| testMenuBar | pass 6.00 s | pass 6.99 s | pass 6.09 s | **differed in run 1**, identical in run 2 |
| testModifierClick | pass 6.29 s | pass 6.68 s | pass 6.63 s | identical |
| testTextFieldFocusAndTyping | pass 7.88 s | pass 8.25 s | pass 7.97 s | identical |
| total | 49.4 s | 52.4 s | 50.8 s | |

Simulated tests are 0.1–0.4 s slower each (agent round trips: the runner polls the agent every 5 ms until
the last event of a record is posted). The offscreen mode does not make the sample faster; its value is
not touching the screen (and, later, parallel lanes).

### Regression builds (full suite each)

| Regression | Real | Simulated | Same failing assertion |
|---|---|---|---|
| HOVER (`mouseEntered:` ignored) | only `testHover` fails, line 83 `"Hover: inside"` | only `testHover` fails, line 83 | yes |
| MENU (menu bar action ignored) | only `testMenuBar` fails, line 68 `"Menu actions: 1"` | only `testMenuBar` fails, line 68 | yes |
| FOCUS (focus state not reported) | only `testTextFieldFocusAndTyping` fails, line 38 `"Field focused: yes"` | same, line 38 | yes |

In each regression run the other 7 tests passed in both modes. The activity trees of the failing tests
are identical up to the failed assertion; after it they differ only in the number/order of polling
iterations of the 3 s wait and in triage steps ("Using snapshot previously cached by application"),
which are timing-dependent, not behavioral.

### Screen guard

Real runs: 16–18 frontmost-app changes, 53–61 cursor moves, 11 visible windows, 428–452 synthetic
events attributed to another process (testmanagerd) — this also shows the guard detects real
synthesis. Simulated runs: 0 / 0 / 0 / 0. No hardware (user) events during either.

## The divergence found, cause and fix

`testMenuBar`, simulated run 1: when clicking the item "Run Menu Action", XCTest first clicked the
"Sample" menu bar title **again** (extra "Click menu item 'Sample'" step); the real run went straight
to hovering the item. Cause: XCTest's menu traversal reads the menu bar item's `AXSelected`; in the real
menu bar it is 1 while the menu is open, but the agent opens menu bar menus as pop-ups and the item
kept `AXSelected = 0`. The test still passed only because the agent treated a click on the title of the
open menu as a no-op — which is not real behavior (a real click there closes the menu), so a test that
closes a menu that way would have diverged.

Fix (agent, not the test): main-menu items report `AXSelected = 1` while their menu is open, and a
click on the title of the open menu now closes it, as in the real menu bar. After the fix the activity
trees of all 8 tests are identical and the three Zforge tests still pass offscreen (15.1 s, 40.2 s,
80.3 s; screen untouched).

## Verdict

For these 8 sample tests and 3 regressions, the simulated mode is **equivalent to the real mode**: same
outcomes, same failing assertions, same XCTest action sequences (after the menu bar fix), similar
durations. Caveats:

- Equivalence is shown for these interactions only (click, shortcut, focus/typing, context menu,
  menu bar open/choose, modifier click, hover enter/exit) on a single display, with no user input
  during the run. Untested kinds (drag, scroll, cursor rects, sheets, key codes, multiple displays)
  have no equivalence evidence.
- The menu bar and tracking areas are emulated by the agent; the comparison already caught one
  emulation gap, so new kinds of menu interaction need their own real-vs-simulated check.
- The Zforge tests were compared only with the real baseline of 2026-10-27 (older working tree, loaded
  machine), not with a real run of the same build.
- One real run and one or two simulated runs per case; intermittency not ruled out beyond that.
