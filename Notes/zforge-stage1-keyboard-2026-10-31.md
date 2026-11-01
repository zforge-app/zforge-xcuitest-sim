# Zforge stage 1 — arrows, ⌘± zoom, toolbar search (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display.
Tool: zforge-xcuitest-sim at `929213b` plus the uncommitted changes listed under "Tool changes".
Every real (screen-taking) run was announced immediately before it started and when it ended.

## Build

- Zforge `7ea66ec470133c21025b53d7f64f6873c226a863`, working tree clean (checked with `git status`
  before starting); same build as `Notes/zforge-real-vs-simulated-2026-10-31.md`
  (`~/Library/Caches/dev.xcuitestsim/cmp-zf/dd`; since 2026-11-01 its products are
  `~/Library/Caches/dev.xcuitestsim/builds/zforge-7ea66ec/Products`, Finder extension removed, same
  `Zforge.debug.dylib`). Run results: `.local/results/cache-2026-11-01/cmp-zf/results-s1/` (see
  `Notes/evidence-2026-11-01.md`). `Zforge.debug.dylib` SHA-256 `da557f4a8d41b160`
  in the real copy; the simulated copy has an identical `__text` section (weak agent load command and
  new signature only). The Zforge repository was only read.
- Regression variants (one source line each, in copies of the copy): `zoomkey` (⌘= shortcut removed,
  `5da90c68617561cf`), `zoomout` (⌘- shortcut removed, `dce60ec3b60de6e4`), `arrows`
  (`handleMoveCommand` ignores arrows, `deccc1ef152c79ec`), `fileopen` (File ▸ Open does nothing,
  `4c248d783884d4e4`).

## Tests and capabilities

| Test | Interactions | Capabilities without previous evidence |
|---|---|---|
| `BrowserSearchUITests.testCommandFFocusesToolbarSearchAndEscapeCollapsesIt` | ⌘F, typeText, Escape | toolbar text field becoming first responder |
| `testListKeyboardZoomAndArrowNavigationAfterChangingView` | ⌘0 ⌘= ⌘-, toolbar view selector clicks, ⌘⇧H, ↓ | punctuation key equivalents, arrow keys, toolbar segmented control |
| `testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode` | ⌘-click, File menu, "Open with" submenu, ← , Back button | submenu in a menu bar menu, arrow keys during menu tracking, menu bar keyboard navigation |

No capability had to be implemented from scratch; two fidelity bugs were found and fixed (below).

## Results (final tool)

| Test | Real | Simulated | Failing assertion | XCTest activity tree |
|---|---|---|---|---|
| testCommandFFocusesToolbarSearchAndEscapeCollapsesIt | **fail** 11.39 s (no agent at all) | **fail** 12.16 s | both `BrowserSearchUITests.swift:32` `XCTAssertFalse(app.staticTexts["Welcome.txt"].exists)` | 74 = 74 steps; only async debug-description order differs |
| testListKeyboardZoomAndArrowNavigationAfterChangingView | pass 16.30 s | pass 17.02 s | — | identical (108) |
| testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode | pass 33.99 s | pass 38.39 s (37.00 s alone) | — | identical (259) when run alone; in the 3-test run one extra `Terminate` at launch (the failing search test left its app running) |

Screen guard — real: 2–4 frontmost-app changes and 112–833 synthetic events per run; simulated: 0 and
0 in every run.

The search test fails in the real mode on the unmodified build without any tool component
(`s1-search-real-pure`) and with the observer (`s1-observe-real`): a pre-existing failure of the app or
test at `7ea66ec` (⌘F shows the field but it never becomes first responder; no
`makeFirstResponder:` call in either mode). It is reported, not investigated in Zforge, and not
usable as a passing reference until fixed.

### Regressions (only the affected test run)

| Regression | Real | Simulated | Same assertion | Activity tree |
|---|---|---|---|---|
| zoomout (⌘- removed) | fail, `ZforgeUITests.swift:872` "110%" ≠ "100%" | same | yes | identical (79) |
| arrows (↓ ignored) | fail, `:889` contextual action never enabled | same | yes | 130 = 130; async debug-description order |
| fileopen (File ▸ Open no-op) | fail, `:287` "columns" (no "Dropped" window) | same | yes | 229 = 229; polling-order differences after the failure |
| zoomkey (⌘= removed) | **pass** — ⌘= still matches the shifted ⌘+ alternate | **fail before the fix**, pass after | n/a | identical (108) after the fix |

## Divergences found and fixed in the tool

1. **Keypad key codes.** For `=`, the agent typed key code 81 (keypad =) instead of 24: its
   character→key-code table let later key codes overwrite earlier ones, so keypad keys won. AppKit
   derives the shifted character from the key code; with the keypad code ⌘= no longer matched
   Zforge's `⌘+` (Shift alternate) key equivalent, which real hardware events do. Found with the
   `zoomkey` regression (real passed, simulated failed). Fix: first match wins, fewest modifiers and
   main-block keys first. Key events also carry the keyboard type now (`kCGKeyboardEventKeyboardType`),
   like hardware events; that alone did not fix it.
2. **Menu bar keyboard navigation and hover switching.** In the real File ▸ Open path, after clicking
   "Open with" the keyboard stays in the File menu, so ← moves along the menu bar (File closes, the
   app menu opens); `AXSelected` of File becomes 0, XCTest clicks the File title again (which closes
   the menu), hovering "Open" fails three times and XCTest's internal retry repeats the click. The
   agent kept File open and selected, so XCTest went straight to the item (test passed by a different
   path). Established with an observe-only agent in two real runs, sampling `AXSelected` every 20 ms
   and correlating with the ScreenGuard's synthetic-event timestamps. Fix: while a menu bar menu is
   open, ←/→ with no highlighted item in an open submenu switch to the previous/next menu bar menu,
   and moving the pointer over another title switches to its menu; menus open one at a time in a
   session (never nested). After the fix the real and simulated trees are identical, including the
   three failed hovers and the retry.

Investigation dead ends, recorded so they are not retried: reporting `NSRunningApplication.isActive`
/`ownsMenuBar` as true and forcing `occlusionState` visible did not change anything; both were based
on the assumption that the search test should pass, and were reverted. Sample scenarios for
programmatic focus (`.task { focused = true }`) failed in both modes and were removed.

## Tool changes (uncommitted)

- Agent: main-block key codes preferred; keyboard type on key events; menu bar session with arrow
  navigation and hover switching; diagnostics only on request (`XCUISIM_DIAG=1`, commands
  `diagfocus`, `diagactive`); observe-only mode `XCUISIM_OBSERVE=1` (no simulation; logs responder,
  activation and menu bar AX state) for real runs.
- `prepare-xctestrun.py`: refuses to modify an app that is running (rewriting a mapped binary made the
  kernel kill a debug instance and macOS show a "quit unexpectedly" dialog on the user's screen during
  this session; the user dismissed it) and replaces the agent atomically.

After the last change, re-run simulated (no screen): sample suite 8/8 pass with activity trees identical
to the 2026-10-31 real run; sample regressions HOVER/MENU/FOCUS fail on the same lines as their real
runs, one test each; the three Zforge tests validated earlier pass with trees identical to today's
real run (one asynchronous runtime-note position aside).

## Durations

Simulated is 4–13 % slower: zoom 17.0 vs 16.3 s, File ▸ Open 38.4 vs 34.0 s (the simulated run now
reproduces the real retries; it was 31.5 s before the menu bar fix, faster than real because it
skipped them).

## Verdict

- testListKeyboardZoomAndArrowNavigationAfterChangingView: **equivalent** (outcome, tree, both
  regressions).
- testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode: **equivalent after the menu bar fix**
  (outcome, tree including XCTest's retries, regression).
- testCommandFFocusesToolbarSearchAndEscapeCollapsesIt: **fails identically in both modes**
  (same assertion, same tree); equivalence of the passing path is unproven until the app/test is fixed.

New capabilities with evidence: arrow keys in a focused content view; arrow keys inside menu tracking
and menu bar keyboard navigation; punctuation key equivalents including Shift alternates (main-block
key codes); submenu opening in a menu bar menu; menu bar hover switching; toolbar segmented control and
toolbar button clicks; ⌘-click.

Caveats: one or two real runs per case; menu bar navigation does not include the Apple menu (← from the
app menu wraps to the last menu instead); the search field's passing path is untested.

## Pending for stage 2

- `testCompactToolbarMenusOpenFromTheirToolbarButtons` — menus opened from toolbar buttons/overflow.
- `testFileOpenPrecedesOpenWithAndTracksSelectionInListMode` — modifier-click multi-selection and menu
  contents following the selection.
- Re-check `testCommandFFocusesToolbarSearchAndEscapeCollapsesIt` once it passes in the real mode.
