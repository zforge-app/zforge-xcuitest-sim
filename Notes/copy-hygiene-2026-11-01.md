# Copies, builds and the system: extensions, registration, leftover processes (2026-11-01)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), Apple M5, single display. Tool at `082043b`
plus the changes below. No real (screen-taking) run. Run artifacts named here: `.local/results/cache-2026-11-01/lanes/results/`
(see `Notes/evidence-2026-11-01.md`; the copies and builds described below were deleted afterwards). The Zforge repository was not read or built in
this phase; its first-consumer data comes from the existing copies of `7ea66ec` in the work
directory.

## Problem (reported by the Zforge thread)

Every copy and build the tool made in `~/Library/Caches/dev.xcuitestsim` carried Zforge's Finder Sync
extension with the real identifier (`io.libor.Zforge.FinderExtension`): lane copies, simulated and
real comparison copies (`cmp-zf/*`) and the `-derivedDataPath` builds (`dd-zforge*`, `cmp-zf/dd-*`).
Once registered (a launch or an Xcode build registers an app with Launch Services; pluginkit then
knows its extensions), the Finder loaded the extension of `lanes/lane4` and later of
`cmp-zf/dd-arrows` instead of the build under test, which broke Zforge's `FinderExtensionUITests`. A
`lane4` app and its extension stayed alive for about 50 minutes after the runs: XCUITest does not quit
the app of the last test. The Zforge thread unregistered 97 extension copies (about 60 from the tool)
with `lsregister -u` and kept the files (lists in `/tmp/zf-fix/ls-unregistered*.txt`).

## Changes

`Scripts/copy_hygiene.py` (generic; acts only inside `$XCUISIM_WORK`, so the developer's DerivedData
is never stripped, unregistered or killed):

- **Extensions.** `strip_tree(dir)` removes everything in `Contents/PlugIns` and `Contents/Extensions`
  of every bundle under the directory (keeping `.xctest` bundles, which the runner needs), deletes
  loose extension products (`.appex`, `.plugin`, `.qlgenerator`, `.mdimporter`, `.saver`,
  `.systemextension`; resource `.bundle`s stay), re-signs each changed bundle with the identity,
  entitlements and flags it had (innermost first), and drops references to removed products from every
  xctestrun (`DependentProductPaths`, `CodeCoverageBuildableInfos`). Build intermediates (`*.noindex`)
  are not touched.
- **Registration.** Launch Services records are found by the bundle identifiers inside the copy
  (`LSCopyApplicationURLsForBundleIdentifier`, ~1 s) or, with `--thorough`, in the whole database dump
  (10–70 s on this machine; also finds deleted copies). pluginkit records come from `pluginkit -mADvvv`.
  `unregister` removes both and repeats until a check 1.5 s later finds nothing: a registration still in
  flight (a launch, `lsregister -f`) lands about a second after `-u` and undoes it (reproduced).
- **Processes.** Processes whose executable lies inside a copy (libproc), terminated with SIGTERM and,
  after 5 s, SIGKILL; each one is reported.
- `preflight` (refuses while a copy process is alive; removes leftover registrations and verifies) and
  `cleanup` (terminates and reports leftovers, unregisters, verifies). CLI:
  `copy_hygiene.py check|cleanup|strip [--thorough] <dir or xctestrun>...`.

Callers:

- `prepare-xctestrun.py` refuses copies outside the work directory and strips the copy
  (`strip_tree`) before inserting the agent; both the copy's xctestrun and the offscreen one stop
  referring to the removed extension. `make-lane.py` goes through it.
- New `Scripts/build-for-testing.sh <derived data path> <xcodebuild args>`: refuses a path outside the
  work directory, builds, then strips and unregisters everything under the path, also when the build
  fails (keeps xcodebuild's status). `build-sample.sh` and the spike's Zforge build helpers use it.
- `run-offscreen.sh` (when the xctestrun belongs to a copy in the work directory) and `run-lanes.py`:
  preflight before the run; cleanup after it in a trap/`finally`, also on SIGINT/SIGTERM and on the
  system-dialog abort; `run-lanes.py` records it under `hygiene` in the summary and refuses to start
  without `--watch`.

## One-time cleanup of the existing work directory

`copy_hygiene.py strip --thorough ~/Library/Caches/dev.xcuitestsim`: **126 extension bundles removed**
(two per copy or build: the embedded one and the loose product), 33 Launch Services registrations
removed; signatures verified afterwards (`codesign --verify --strict` on lane, simulated, real and
`dd-zforge` apps). No extension bundle remains on disk outside build intermediates (none there either).
pluginkit now lists only the developer's extension
(`~/Library/Developer/Xcode/DerivedData/Zforge-…/Zforge.app/Contents/PlugIns/ZforgeFinderExtension.appex`)
and no record under the work directory.

## Finding: macOS re-registers copies it already knows

After a clean `unregister` (verified with the full dump), the main apps of the copies that had been
launched before (33 `Zforge.app`/`SampleApp.app` records; runners and extensions do not come back)
reappear within 5 s to 2 minutes, without any action of the tool. `lsd` logs the requesters:
`mds` (Spotlight), `com.apple.hiservices-xpcservice` (`HIS_XPC_CopyApplicationPolicyForURLs`),
`siriknowledged`, `Finder` and `sharedfilelistd`. Moving a copy into a `*.noindex` folder or renaming
the bundle (`X.app.parked`) did not stop it: the record came back at the new path. New copies that were
never launched were not re-registered (2 minutes observed). So, while a launched copy exists on disk,
the tool can unregister it at the end of each run (and does) but cannot keep it unregistered
afterwards. Such a record has no extension any more, so it can no longer replace the developer's; it
can still appear in "Open With" lists and receive files opened by app name. Each unregister/re-register
cycle also wakes several daemons (Spotlight, Siri actions, network service proxy).

## Tests

`Tests/test_copy_hygiene.py` (fake bundles in `$XCUISIM_WORK/selftest-*`, ad-hoc signed; no XCTest) and
`Tests/test_zz_cache_clean.py` (runs last, checks the whole work directory):

| Area | Tests |
|---|---|
| Extensions | stripping keeps `.xctest` and resource bundles, prunes the xctestrun and coverage entries; idempotent; `prepare-xctestrun.py` end to end strips the copy and both xctestruns; `strip_tree` on a `-derivedDataPath` layout keeps signatures valid and intermediates untouched; refusals outside the work directory |
| Builds | `build-for-testing.sh` with a fake xcodebuild that creates an extension and registers the app as Xcode does: nothing left on disk or registered, also after a failed build (status 65 kept); refusal outside the work directory |
| Registration | real `lsregister -f` of a fake app found and removed; preflight removes leftovers; pluginkit output parsing |
| Processes | leftover processes terminated (SIGTERM) or killed (a binary that ignores SIGTERM), reported; preflight refuses while one is alive |
| Runners | `run-lanes.py` with a fake xcodebuild that leaves the app running: cleanup after a normal end and after SIGTERM (exit 130, `interrupted` in the summary); refusal while a copy process is alive (and that process survives); `run-offscreen.sh` cleanup |
| Whole work directory | no extension bundle on disk; nothing in pluginkit or Launch Services (thorough); no process |

Result: 20 of 21 pass, repeatedly. **`test_nothing_registered_with_pluginkit_or_launch_services`
fails**: pluginkit part clean, Launch Services lists the 32–33 re-registered main apps of old launched
copies (finding above). The test is left strict on purpose. `test_run_offscreen_cleans_up_after_a_normal_end`
failed once in about 13 runs (not reproduced in 8 isolated and 2 full runs afterwards); most likely
the same re-registration of the fake app, which the test launches.

## 2-lane confirmation (14 tests)

Lane copies 1 and 2 of `7ea66ec`, stripped, current agent; session unlocked; no `xcodebuild` or test
runner of the Zforge thread running at the start of each round (checked). The machine was heavily
loaded during this phase by other work: 51 `jest-worker` processes of an unrelated project (~680 % CPU)
earlier, then Spotlight (`mds_stores` 150–200 %, after the 126 re-signed bundles and the registration
churn), Docker/Virtualization and node; load average 11–60.

| Round | Wall | Result | Screen guard | Hygiene at the end |
|---|---|---|---|---|
| `par2-hyg` | 522 s (248 s on 2026-10-31) | 13/14 | 0 synthetic events, 0 visible windows | 0 leftover processes; 4 records unregistered; nothing registered or running |
| `par2-hyg-b` | 444 s | 12/14 | same | same; preflight removed 1 re-registered record |

Failures, all timing under load, not reproduced alone on the same stripped lanes:

- `testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode` (both rounds), `ZforgeUITests.swift:282`
  `("ArchiveDragFixture-…") is not equal to ("Recents")`: the test reads the window title right after
  launch, before the app has switched the window from "Recents" to its fixture folder (created by the
  test's own `--ui-archive-drag-fixtures`). Alone on lane 2: pass 2/2 (56 s and 52 s).
- `testSettingsToggleUpdatesTheOpenGridAndKeepsSelection` (second round), line 111, 5 s wait timeout.
  Alone on lane 1: pass (62 s).

Every test took 1.2–4.8× its 2026-10-31 duration. The passing tests' activity trees are unchanged
against the real references (identical or `Terminate` only; `testListColumnsReorderByDragging` −3/−4
steps as before), so removing the extension did not change their behavior. **The 2-lane confirmation
is not clean**: it should be repeated on a quiet machine.

At the end: no process from the work directory; pluginkit lists only the developer's Finder extension.

## Open decision

Keeping launched copies on disk means macOS re-registers their main apps. Options: accept records of
extension-less copies (the harmful part is gone), or delete copies after use and recreate lanes per run
(`make-lane.py` takes seconds per lane), and remove the old comparison copies and builds (`cmp*`,
`dd-*`) once they are no longer needed for re-runs. Not done without the user's decision.
