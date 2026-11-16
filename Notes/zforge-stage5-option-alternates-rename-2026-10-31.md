# Zforge stage 5 — Option alternates in menus, inline rename, double click (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Tool `45bfdc0`
(unchanged during this stage). Zforge `c127bca` (clean), same build as the earlier stages
(`Zforge.debug.dylib` `da557f4a8d41b160`). Zforge repository only read. Real runs announced before and after.

## Tests and new capabilities

| Test | New capabilities |
|---|---|
| `testFolderSelectionMenuAlternatesWithOptionInListMode` | Option pressed and released while a menu bar menu is open (flags-changed during menu tracking, alternate items) |
| `testNewFolderWithSelectionMenuAndShortcutInListMode` | ⌃⌥⌘ shortcut, Option-Return on a hovered alternate item, inline rename editor (typing, Return), double click opening a folder, two launches in one test |

## Results

| Test | Real | Simulated | Tree |
|---|---|---|---|
| testFolderSelectionMenuAlternatesWithOptionInListMode | pass 11.80 s | pass 12.68 s | identical (79) |
| testNewFolderWithSelectionMenuAndShortcutInListMode | pass 52.65 s | pass 56.60 s | identical (317) |

| Regression | Real | Simulated |
|---|---|---|
| optalt: "New Folder with Selection" alternate on Control instead of Option, `df78de96aaa53a50` | FolderSelection **passes** (its `exists` check does not depend on visibility); NewFolder fails `:58` "Not hittable" on the alternate | same in both tests; trees identical (79) / 398 = 398 |
| rename: Return does not commit, `51326ef04f677660` | fail `:71` | same; trees differ only in the polling after the failure |
| dblclick: double click handled as single click, `13a71f5b6d96597b` | fail `:73` "list" | same; same |

The menu item frames reported in the optalt failure differ by 4 pt in x (real 101, simulated 105):
menu bar menus open at the agent's approximated menu bar layout, not the real one.

Screen guard: real 2–7 frontmost changes, 220–1085 synthetic events; simulated 0. The user produced
104 hardware events during the unmodified real run; outcomes and trees matched anyway.

## Verdict

Both tests: **equivalent** (outcome, identical trees, all three regressions on the same assertions;
the optalt regression is only detected by the second test, in both modes).
