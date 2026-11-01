# Zforge simulated mode — parallel lanes, measured prototype (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), Apple M5 (10 cores), 24 GB, single display.
Zforge `7ea66ec470133c21025b53d7f64f6873c226a863` (clean; the repository was only read), the same
build as every earlier comparison (`Notes/zforge-coverage-summary-2026-10-31.md`). Tool at `23150cf`
plus the changes listed below. No real (screen-taking) run was needed or made in this phase.

Scope: the 14 tests that are equivalent in the simulated mode (summary note, table rows 1–3, 5–15
without 4), run serially and in 2, 3 and 4 parallel lanes, all simulated.

## Lane isolation

`Scripts/make-lane.py` (generic) copies the `build-for-testing` products and, per lane:

- renames the UI target app and the test runner (`CFBundleIdentifier` + `.laneN`), so each lane has its
  own Launch Services identity, sandbox container and preferences, and XCUITest's "terminate running
  instances of the target app" at launch never hits another lane's app;
- optionally renames app groups in the entitlements (`--app-group-suffix`) and Info.plist keys that name
  them (`--plist-suffix-key`); Zforge needs both (`ZforgeAppGroupIdentifier`), otherwise lanes share
  one group container;
- updates `application-identifier`, re-signs (`codesign -i <new id>`, hardened runtime, entitlements;
  the copies carry no provisioning profile and launch fine with the development identity), updates the
  xctestrun (`TestHostBundleIdentifier`, crash-report emphasis IDs) and runs `prepare-xctestrun.py`.

Zforge-specific arguments (`--app-group-suffix --plist-suffix-key ZforgeAppGroupIdentifier`) belong in
Zforge's configuration; the tool itself names no consumer.

`Scripts/run-lanes.py` (generic) starts one ScreenGuard for the whole run, one
`xcodebuild test-without-building` per lane with its xctestrun and `-only-testing` list, and samples
CPU/RSS of the watched processes once per second (`<name>.json`, `<name>.series.json`).

Lane assignment: fixed, longest-processing-time split of the serial simulated durations
(`.local/lane-plan-N.json`, spike files). Within a lane xcodebuild runs the tests in its own
deterministic order (class, then method name), independent of the `-only-testing` order.

## Finding: another process's menu tracking closes the open menu (fixed)

The first 2-lane run (`par2`) failed two tests that never failed serially:
`testBlankAreaUsesMoreMenuInEveryView` (`ZforgeUITests.swift:392`, "icons, selected: true") and
`testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode` (`:321`, "File menu must be visible").
Cause: when any process starts menu tracking, HIToolbox posts
`com.apple.HIToolbox.beginMenuTrackingNotification` and the window server delivers a
`ProcessNotification` event (`subtype` 0x4000) to the other apps, which AppKit uses to dismiss their open
menus — the real "only one menu open on the screen" rule. With two simulated apps, lane A opening a
menu closed lane B's menu. Reproduced 3/3 with two lane copies.

Fix (agent): the event loop drops window-server `ProcessNotification` events with subtype 0x4000. The
event type is private: it is learned once from the event description, so only non-public event types
are inspected. A first version read `-[NSEvent subtype]` on every event, which raises on key events;
the serial check run (`par1b`) failed 10/14 on shortcuts and was the evidence that caught it. With the
fix, both menus stay open 3/3 in the two-copy probe, and every later lane run passed.

Residual risk: a simulated app that opens a menu still posts the begin-tracking notification itself
(C call in `-[NSMenuTrackingSession sendBeginTrackingNotifications]`, not intercepted), so it can close
a menu the user has open in another app. Not observed, not fixed.

## Results

All runs: simulated, lane copies, fixed lane plans, no retries. Serial baselines: 457.3 s simulated
(consolidated note, original copy) and 409.8 s real.

| Run | Lanes | Wall | Passed | vs 457 s sim | vs 410 s real | Σ test time | Peak test CPU | Mean test CPU | Peak test RSS | Peak system mem (base) |
|---|---|---|---|---|---|---|---|---|---|---|
| par1c | 1 | 452.3 s | 14/14 | 1.01× | 0.91× | 443.2 s | 302 % | 51 % | 0.71 GB | 15.82 (15.52) GB |
| par2c | 2 | 248.4 s | 14/14 | 1.84× | 1.65× | 472.4 s | 226 % | 96 % | 1.16 GB | 15.81 (15.49) GB |
| par2d | 2 | 247.9 s | 14/14 | 1.84× | 1.65× | 474.7 s | 296 % | 94 % | 1.16 GB | 15.92 (15.19) GB |
| par3c | 3 | 182.0 s | 14/14 | 2.51× | 2.25× | 526.6 s | 259 % | 132 % | 1.52 GB | 16.81 (15.45) GB |
| par3d | 3 | 194.5 s | 14/14 | 2.35× | 2.11× | 566.4 s | 294 % | 144 % | 1.57 GB | 15.87 (15.25) GB |
| par3e | 3 | 202.6 s | 14/14 | 2.26× | 2.02× | 587.3 s | 309 % | 139 % | 1.59 GB | 16.04 (15.26) GB |
| par4a | 4 | 189.0 s | 14/14 | 2.42× | 2.17× | 717.0 s | 360 % | 170 % | 2.11 GB | 15.99 (15.44) GB |

CPU in % of one core (10 cores = 1000 %); "test" = all app and runner processes of all lanes, plus
xcodebuild and testmanagerd. System CPU averaged 13 % (1 lane) to 30 % (4 lanes) of the machine.

- Per-test slowdown (Σ test time vs the serial 443.2 s): +7 % with 2 lanes, +19 % to +33 % with 3,
  +62 % with 4. The machine is far from CPU- or memory-bound; the lanes queue on shared serial
  services. In `par3e` (separate 1 s sampling) testmanagerd averaged 61 % and peaked at 90 % of one core,
  WindowServer averaged 26 %; every XCTest query, snapshot and wait-for-idle goes through the single
  testmanagerd. 4 lanes gave no wall-time gain over 3.
- Earlier runs before the fixes: `par1` 450.3 s 14/14 (serial, before the menu fix), `par2` 222.7 s
  12/14 (the two cross-process menu failures), `par1b` 320.5 s 4/14 (the subtype exception).
- Order dependency BlankArea → CompactToolbar (summary note): not reproduced, because in no lane plan
  does CompactToolbar run right after BlankArea (serially `testColumnPreviewRefits…` runs between them;
  in the 2- and 3-lane plans they are in different lanes). Results are equal to the serial simulated
  run: 14/14 in every run after the fixes.

### Screen guard

Every lane run: 0 synthetic events in the session, 0 visible windows of the watched processes, no
cursor movement by the tool. Other entries were the user's own input or the system: `par1c` recorded
3 mouse moves and 134 hardware events, and `par1` 54 hardware events (the user at the machine);
`par3e` recorded one frontmost change to loginwindow, the screen locking from idle (the display goes
to sleep once XCTest releases its assertion at the end of a lane).

**The simulated mode needs an unlocked session.** With the console session locked
(`CGSSessionScreenIsLocked`), the app under test exposes an empty, disabled application element (no
menu bar, no windows) and every test fails at its first query: `par3f` (3 lanes, final agent) 0/14,
`lock-probe` (one test, serial) failed, minutes after the same agent passed the whole revalidation.
Every earlier run started with the session unlocked (the guard logs show the frontmost app at start;
in `pv-orig-container` loginwindow was in front for 2 s and the session was unlocked before the test
ran). `run-lanes.py` now refuses to start when the session is locked, so a lock is not mistaken for a
regression. A lock in the middle of a run is still possible; keep the session unlocked for the batch
(for example by running it under `caffeinate -d`, a user decision since it keeps the display awake).

### Fidelity: activity trees vs the real references

All 14 tests of every lane run were diffed against their real reference trees (lane suffix,
pids, addresses, durations, timestamps and UUIDs normalized). `=` identical; `=T` differs only by a
`Terminate` of a previous instance at launch (depends on what ran before in the same lane); `=o`
same steps, one asynchronous step in a different position; `D±n` real divergence (step count delta).

| Test | par1c | par2c | par2d | par3c | par3d | par3e | par4a |
|---|---|---|---|---|---|---|---|
| testKeyboardShortcutHelpOpensAndFilters | = | = | = | = | = | = | =T |
| testSettingsToggleUpdatesTheOpenGridAndKeepsSelection | =o | =o | =o | =o | =o | =o | D+1 |
| testBlankAreaUsesMoreMenuInEveryView | = | = | = | = | = | = | = |
| testListKeyboardZoomAndArrowNavigationAfterChangingView | = | = | = | = | = | = | = |
| testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode | =T | =T | =T | =T | D−41 | D−41 | D−42 |
| testFileOpenPrecedesOpenWithAndTracksSelectionInListMode | =T | = | = | = | = | = | =T |
| testCompactToolbarMenusOpenFromTheirToolbarButtons | =T | = | = | = | = | = | = |
| testViewModeIsPerWindowAndLastClosedWindowRestoresIt | =T | =T | =T | =T | =T | =T | = |
| testTagEditorIsSharedByToolbarAndContextMenu | = | = | = | =T | =T | =T | =T |
| testFolderSelectionMenuAlternatesWithOptionInListMode | = | = | = | = | = | = | = |
| testNewFolderWithSelectionMenuAndShortcutInListMode | =T | = | = | = | = | = | =T |
| testLanguageSelectionUpdatesOpenMenuAndPersists | = | = | = | = | = | = | = |
| testColumnPreviewRefitsAfterUserScrollsLeft | = | = | = | = | = | = | = |
| testListColumnsReorderByDragging | D−4 | D−4 | D−4 | D−4 | D−4 | D−4 | D−4 |

The three divergences:

1. **`testListColumnsReorderByDragging` D−4 in every lane copy, including the serial one.** It is not
   caused by parallelism: the same test with the current agent on the original copy (`pv-orig-container`)
   is identical to the real reference (198 steps). In the lane copy the loop
   `for _ in 0..<20 where !rowsOnScreen() { scroll(byDeltaX: 0, deltaY: -120) }` needs one scroll fewer:
   at the first check the "modificationDate" row is already inside the Settings window, so there is less
   content above the List Columns section. Most likely cause: per-bundle state shown above that section
   (the Automation folder list stored in the app's group container, empty for a new bundle ID). The group
   containers are protected by macOS app-data protection, so this was not inspected directly. This is a
   consequence of lane isolation (fresh app state), not of event delivery; the test passes in both.
   Real references recorded against a clean container would make the comparison exact.
2. **`testFileOpenNavigates…` D−41/−42 in 2 of 3 three-lane runs and in the 4-lane run; never with 1 or
   2 lanes.** It also reproduces serially, without lanes, under artificial CPU load (10 × `yes`, 2/2
   runs, `stress-fileopen`, `stress-fileopen2`), and not without load (`calm-fileopen`, identical). The
   agent's event handling is the same in both cases (agent log): the ← key moves from File to the app
   menu; XCTest's "Click Open" traversal clicks the File title; the pointer passing over File opens it
   (menu bar hover switching), and the click closes it ~0.5 s later. The difference is when XCTest
   polls: unloaded, its existence check of the Open item lands while File is still open, then three
   "Hover" attempts fail as not hittable and the traversal is retried (as in the real tree); under load
   the check lands after the close and fails with "open menu during menu traversal", and the traversal
   is retried directly. Same outcome (pass), shorter path. This is a race inside XCTest's own
   menu-traversal retries; whether the real mode takes the same branch under load is unverified
   (it would need a real run under load).
3. **`testSettingsToggle…` D+1 in the 4-lane run**: one extra "Get number of matches … (retry 1)", an
   XCTest query retry under load. Same outcome.

### Revalidation after the agent change

The lane measurements above ran with the first working version of the menu-notification filter. A
review before the commit found that it would loop forever if the ignored event was only peeked
(`dequeue == NO`): the event is now taken off the queue first, like the real-pointer filter does. No
measured run hung, so that path was not hit in them. With the final agent (`lanes-final2`, serial,
original copies, session unlocked):

- sample suite 8/8 pass, activity trees identical to the real run; sample regressions HOVER, MENU and
  FOCUS fail on the same lines as their real runs (lines 83, 68, 38), one test each;
- stage 4 and stage 7 sample tests and their regressions: same outcome as real, trees identical (the
  scroll regression differs only after its failure, as before);
- `testCompactToolbarMenusOpenFromTheirToolbarButtons` alone: pass, identical (106);
- the 13 other validated Zforge tests together: 13/13 pass; 8 identical, 4 differ only by a `Terminate`
  at launch, 1 (`testSettingsToggle…`) by one asynchronous wait position; screen guard 0 synthetic
  events, 0 visible windows (one frontmost change: the screen locking at the end).

### Confirmation with the final agent (2026-10-31, 23:30–23:40)

Run after the user unlocked the session, on the existing lane copies of `7ea66ec` (no rebuild from
the Zforge repository) holding the final agent (CDHash `a7f1fa42…`, the committed source). The session
was checked unlocked before each step and stayed unlocked. Another agent thread was working in the
Zforge repository at the same time (builds into `/tmp/zf-fix/dd`, then a unit-test run); a watcher
sampled foreign `xcodebuild`, test runner and `Zforge` processes every 2 s.

1. **Two-copy menu probe** (`menuprobe-final`): lane 1 and lane 2 copies launched directly with the
   agent, File opened in A, then in B, open menus counted through accessibility. 3/3 trials: A keeps its
   menu open after B opens one (A=1, B=1); before the fix the same probe gave A=0 in 3/3. The agent
   logged 3 ignored menu-tracking notifications. Screen guard: 0 synthetic events, 0 visible windows, no
   frontmost change. No foreign process was running.
2. **3 lanes, 14 tests** (`par3g`): **14/14 pass** (lane 1 4/4, lane 2 5/5, lane 3 5/5), wall 240.1 s.
   Screen guard: 0 synthetic events, 0 frontmost changes, no cursor movement, **1 visible window that
   was not ours**: a `Zforge` window of 1082 × 708 at 1793500750.3, when the watcher saw the other
   thread's unit-test host (`/tmp/zf-fix/dd/.../Zforge.app`, pid 84075) running. The guard matched it by
   process name only; it now also logs the owner pid and executable path.
   Activity trees (same matrix as above): identical to the earlier 3-lane runs: 12 tests `=`, `=T` or
   `=o`; `testListColumnsReorderByDragging` D−4 (lane state, divergence 1);
   `testFileOpenNavigates…` D−38 (the same "open menu during menu traversal" branch as divergence 2,
   plus one extra polling iteration on the "Sample.zip" window).

   **Timing is interference, not a result.** CPU outside the test processes averaged 229 % before the
   other thread's unit-test run appeared (113 s into the run) and 304 % while it ran (about 127 s of
   the 240 s), against 103–143 % in `par3c`–`par3e`; Σ test time 698 s against 560 s on average in those
   runs, with the largest slowdowns in tests that overlapped the unit-test run (+47 % to +123 %). The
   unit-test run does not use UI automation; no sign of testmanagerd contention, but its CPU was not
   sampled separately. The 3-lane timing of record stays 182–203 s (`par3c`–`par3e`).

With this, the final agent is confirmed in parallel (outcome, screen guard, trees) and for the
cross-process menu case.

## Recommendation

**3 lanes on this machine** (with the session kept unlocked): about 2.3× the serial simulated throughput (182–203 s vs 457 s) and about
2.1× faster than the real serial run (410 s), 14/14 in every run, screen guard clean. A 4th lane adds no
wall-time gain (189 s) and makes per-test slowdown (+62 %) and load-dependent XCTest retry paths more
likely. Use 2 lanes (248 s, 1.84×, +7 % per test, trees identical to the 1-lane runs) when a run is
meant as equivalence evidence against real trees.

## Risks

- Throughput is capped by testmanagerd (one per user session, serial); more lanes mostly add queueing.
- Higher load changes timing: XCTest's internal retries take different branches (divergence 2) and
  timeout-based assertions get closer to their limits. No failure was observed; no retries or timeouts
  were changed.
- Lane copies start with fresh app state (preferences, group container), which can change paths in
  tests that read persisted state (divergence 1). Real references should be recorded on lane copies
  or clean state.
- Cross-process menu rules: the incoming notification is suppressed in the agent, but simulated apps
  still post their own begin-tracking notification and can close a menu the user has open.
- The screen locks from idle at the end of a lane run (XCTest's display assertion is released), and a
  locked session makes every simulated test fail (as it would block a real run). Lanes now refuse to
  start when locked; a batch must keep the session unlocked.
- testmanagerd's Automation Mode authentication prompt (summary note) can appear when UI tests have not
  run for a while; `run-lanes.py` aborts all lanes when a system dialog comes to the front.
- Sample size: 2 runs with 2 lanes, 3 timed (plus 1 under interference) with 3, 1 with 4.
- Other work on the same machine (builds, unit tests, real UI tests) shares CPU, the screen and
  testmanagerd; timings taken next to it are not comparable, and a guard that watches by process name
  also sees another build of the same app.

## Tool changes in this phase

- Agent: drops window-server `ProcessNotification` events with subtype 0x4000 (another process
  started menu tracking); `XCUISIM_TRACE_POINTER` also logs AppKit-defined and system-defined events;
  `XCUISIM_NO_POINTER_FILTER` disables the real-pointer filter (diagnostics only).
- Agent: on a peek, the ignored notification is dequeued before the loop continues (see revalidation).
- New `Scripts/make-lane.py` and `Scripts/run-lanes.py` (refuses to start with a locked session);
  README usage.
- ScreenGuard: a visible window line also carries the owner pid and executable path (added after
  `par3g`, where another app with the same process name showed a window).
