# Ephemeral copies, cache cleanup and the 2-lane confirmation (2026-11-01)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), Apple M5 (10 cores), 24 GB, single display.
Tool at `ff22422` plus the changes below. No real (screen-taking) run. The Zforge repository was not
read or built; the Zforge build is the existing `c127bca` one (below). Follows
`Notes/copy-hygiene-2026-11-01.md`, whose open decision the user settled: delete copies after use.

## Why

macOS services (Spotlight `mds`, `com.apple.hiservices-xpcservice`, `siriknowledged`, Finder,
`sharedfilelistd`) re-register app bundles they already know, whatever their folder or name, as long
as the bundle exists on disk. A copy that has been launched once therefore came back to Launch Services
seconds to minutes after every unregistration, showed up in "Open With" and failed the whole-cache
check. A deleted copy cannot come back.

## Changes

- `Scripts/run-offscreen.sh [--real] <name> <build's xctestrun> <apps> [args]`: copies the build
  products directory into `$XCUISIM_WORK/runs/<name>-<time>-<pid>` (APFS clone), prepares the copy
  (simulated: `prepare-xctestrun.py`; `--real`: extensions stripped only), runs, and at the end (EXIT
  trap; also SIGINT/SIGTERM and the system-dialog abort) disposes of the copy. It refuses an
  `-offscreen` xctestrun (the variant is made on the copy) and refuses to start while a process of
  another run's copies is alive. `XCUISIM_KEEP_COPY=1` keeps the unregistered copy for diagnostics.
- `Scripts/run-lanes.py --products <build products> --lane <tests> …`: makes one lane copy per lane in a
  fresh run directory (`make-lane.py`, which now clones and refuses destinations outside the work
  directory), runs, and disposes of the run directory in `finally` (also on SIGTERM and when making a
  lane fails); `--keep-copies` for diagnostics. The summary records `copies` and `hygiene.deleted`.
- `copy_hygiene.dispose(dirs)`: cleanup (leftover processes terminated and reported, registrations
  removed and verified), then deletion, **refused while a process of the copies is still alive**
  (deleting a running bundle can crash it in front of the user). After deleting it removes records by
  path and checks again by the bundle identifiers the copies had: a service can re-register a copy
  between the last check and the deletion (seen once during the cleanup below: `lane3/Zforge.app`),
  and the final state is what `still_registered` reports. CLI: `copy_hygiene.py dispose [--thorough]`.

## One-time cleanup of the cache

Evidence first: every real reference and every artifact a note cites (242, 4.9 GB) moved to
`.local/results/cache-2026-11-01/` with their relative paths; notes updated; index in
`Notes/evidence-2026-11-01.md`. The Zforge `c127bca` build of every comparison (never launched; Finder
extension already removed; `Zforge.debug.dylib` SHA-256 `da557f4a8d41b160`) moved to
`~/Library/Caches/dev.xcuitestsim/builds/zforge-c127bca/Products` as the source for runs.

Then `copy_hygiene.py dispose --thorough` on `lanes/`, `cmp`, `cmp-s1`, `cmp-s4`, `cmp-s7`, `cmp-zf`,
`dd-sample`, `dd-zforge`, `dd-zforge-reg-{blankmenu,iconpref,shortcut}`: 0 leftover processes,
32 registrations removed, all deleted; 39 GB → 60 MB (`build/` with the tool binaries, `builds/`,
`runs/`). Afterwards the full Launch Services dump has no record under the cache and pluginkit has none;
pluginkit's only `io.libor.Zforge.FinderExtension` is the developer's DerivedData build. Nothing outside
the cache was deleted. Left outside the cache, untouched: the sandbox containers that the lane apps
created (`~/Library/Containers/io.libor.Zforge.laneN`, `io.libor.ZforgeUITests.xctrunner.laneN`,
group containers `FL2Y9U53SS.io.libor.Zforge.laneN`).

## Tests

24 tests (`python3 -m unittest discover -s Tests`): the runner tests now go through the real
`make-lane.py` and `prepare-xctestrun.py` on a fake build (app with an extension, runner with an
`.xctest`, ad-hoc signing) with a fake xcodebuild that launches the copy's app and leaves it running:

- `run-lanes.py` (2 lanes): copies made, leftovers reported (one per lane), copies deleted, nothing
  registered (also checked in the full Launch Services dump for the deleted paths), source build
  untouched; after SIGTERM: exit 130, same disposal; refused while another run's copy process is alive
  (that process survives, no run directory is left);
- `run-offscreen.sh`: simulated run copied, prepared and deleted; `--real` run stripped (the fake
  xcodebuild sees no extension) and deleted; disposal after SIGTERM; `-offscreen` xctestrun refused;
- the whole-cache check (`test_zz_cache_clean`): no extension bundle on disk, nothing registered in
  pluginkit or Launch Services (full dump), no process.

Result: 24/24 in each of 3 consecutive full runs (ResourceWarning as error). The intermittent `test_run_offscreen_cleans_up_after_a_normal_end`
of the previous note ran on a copy that stayed on disk; its successor
(`test_run_offscreen_copies_prepares_and_deletes`) deletes the copy and has not failed.

## 2-lane confirmation (14 tests)

**Run under high load; repetition on a quiet machine pending.** The round waited for the 1-minute
load average to fall below 8 (background monitor); it started at 5.8 (`par2-eph`, 19:09), but load
from other projects (Claude desktop, a virtual machine, node, `chrome-headless-shell`, `next-server`)
rose during the round: CPU outside the test processes averaged 379–507 % (103–143 % in the quiet rounds
of 2026-10-31), load average 15 at the end. A second wait for a sustained quiet period (1- and 5-minute
averages below 8) ran from 19:17 to 20:30 without the load ever falling below 10 (it reached 150) and
was stopped at the user's request.

Fresh lane copies of `builds/zforge-c127bca/Products` (distinct bundle identifiers, own app group, no
extension); no foreign `xcodebuild` or test runner; session unlocked. Results in
`~/Library/Caches/dev.xcuitestsim/lanes-results/par2-eph*`.

| Lane | Wall | Result |
|---|---|---|
| 1 | 340.0 s | 5/6: `testListKeyboardZoomAndArrowNavigationAfterChangingView` failed at `ZforgeUITests.swift:889`, 2 s wait for `archive-contextual-action` to become enabled after ↓ |
| 2 | 366.5 s | **8/8, including `testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode`** |

Wall 367 s (248 s on 2026-10-31); each test took 1.03–2.12× its 2026-10-31 duration, the failing one
2.12×. Alone on fresh copies (`run-offscreen.sh`, still under load 15–21): the keyboard test passed 2/2
(31 s and 71 s; 17 s normally).

Activity trees against the real references (now read from `.local/results/cache-2026-11-01/`): 12 of
14 identical or differing only by a `Terminate` at launch or an asynchronous wait position, as on
2026-10-31; `testFileOpenNavigates…` **equal to the real tree, including the real hover-failure and
retry path** that earlier diverged under load; `testListColumnsReorderByDragging` −4 (lane state, as
before); the failing keyboard test has the same actions as the real run up to its last wait, plus the
debug descriptions XCTest captures for slow and failing queries (+10 steps).

Screen guard: 0 synthetic events, 0 visible windows; 2 frontmost-app changes, 106 mouse moves and 734
hardware events from the user working at the machine. Hygiene: 0 leftover processes, nothing registered,
copies deleted; `runs/` empty afterwards.

Reading: `testFileOpenNavigates…` passed with the real tree when the timing allowed it, so its earlier
failures (`:282`, title read before the window shows its folder) are load-sensitive, a property of the
test that applies to the real mode too; the keyboard test's 2 s wait is load-sensitive in the same way.
Neither is a fidelity difference of the tool. **Pending: repeat the 2-lane round on a quiet machine.**
