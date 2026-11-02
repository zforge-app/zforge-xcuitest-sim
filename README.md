# zforge-xcuitest-sim

Runs existing macOS XCUITest suites without taking over the user's screen, and in parallel.

XCUITest normally asks `testmanagerd` to synthesize real HID events through the window server, which moves the cursor, activates the app and steals focus. This tool intercepts that private event-synthesis path in the test runner and delivers the events inside the app under test (offscreen windows, simulated activation). Element queries keep using the real accessibility tree, so existing tests run unchanged.

Status: feasibility spike. See `Notes/feasibility-2026-10-29.md` for what was proven and what was not.

## Layout

- `Sources/RunnerShim/` — runner shim (`libXCUISimRunnerShim.dylib`).
- `Sources/AppAgent/` — app agent (`libXCUISimAgent.dylib`).
- `Tools/ScreenGuard/` — records frontmost-app changes, cursor movement, visible windows and synthetic events during a run (evidence that the screen was not touched).
- `Sample/` — sample AppKit/SwiftUI app with unchanged XCUITests and compile-time regressions for negative controls.
- `Scripts/` — build, prepare and run scripts.
- `Notes/` — reverse-engineered interface notes per Xcode version and spike findings.

Work products go to `$XCUISIM_WORK` (default `~/Library/Caches/dev.xcuitestsim`). Never build or load test products from `~/Documents`, `~/Desktop` or `~/Downloads`: the runner reading them makes macOS show a permission prompt.

## Spike usage

```sh
XCUISIM_SIGN_IDENTITY="Apple Development" Scripts/build-tools.sh
XCUISIM_TEAM=<team> Scripts/build-sample.sh                         # prints the build's xctestrun path
# simulated (offscreen) run on a throwaway copy of the build; --real for a real XCUITest run (takes the screen)
Scripts/run-offscreen.sh [--real] <name> <build's xctestrun> <app>,<runner> [-only-testing:...]
```

Runs never touch the build itself: each run copies the build products into `$XCUISIM_WORK/runs/<name>-<time>-<pid>`, prepares the copy there (`prepare-xctestrun.py`: weak load command for the agent, re-signing, offscreen xctestrun) and deletes it at the end. Build into `$XCUISIM_WORK` with `Scripts/build-for-testing.sh <derived data path> <xcodebuild args>`.

### Copies and the system

Copies and builds are kept from leaking into the rest of the system (`Scripts/copy_hygiene.py`, `Notes/copy-hygiene-2026-11-01.md`, `Notes/ephemeral-copies-2026-11-01.md`):

- **No app extensions.** Copies keep the original bundle identifiers of their extensions, and the system can load a copy's extension instead of the developer's (a Finder Sync extension did). `build-for-testing.sh` and `prepare-xctestrun.py` remove `Contents/PlugIns` and `Contents/Extensions` from the apps (test bundles stay) and loose extension products, re-sign, and prune the xctestruns. Tests that need an extension run in the real group, from the developer's own build.
- **Ephemeral copies.** `run-offscreen.sh` and `run-lanes.py` create their copies at the start of a run and, at the end (also after an abort), terminate and report leftover processes of the copies (such as the app XCUITest leaves running after the last test), unregister them from Launch Services and pluginkit and delete them. A launched copy kept on disk would be re-registered by macOS services (Spotlight, Finder, HIServices) later. A run does not start while another run's copies are in use. Builds made by `build-for-testing.sh` are unregistered after the build and never launched.
- `copy_hygiene.py check|cleanup|strip|dispose [--thorough] <dir>` inspects or cleans any directory of the work directory; tests: `python3 -m unittest discover -s Tests -v` (the last test checks the whole work directory: no extension on disk, nothing registered, no process).

Parallel lanes (prototype, see `Notes/zforge-parallel-lanes-2026-10-31.md`): one throwaway copy per lane (`make-lane.py`: distinct app and runner bundle IDs, optional app group rename), all lanes under one ScreenGuard, CPU and memory sampled.

```sh
Scripts/run-lanes.py --name <run> --results <dir> --watch <app> --watch <runner> --products <build products dir> \
    [--identity "Apple Development"] [--app-group-suffix] [--plist-suffix-key <Info.plist key naming the app group>] \
    --lane <test id>,<test id> --lane <test id>
```

## Planned parts

- **Runner shim:** loaded into the UI test runner; replaces `_XCT_synthesizeEvent:` (and, where needed, launch/terminate) with delivery over a private channel.
- **App agent:** a library linked only into a test build configuration of the app; turns the requests into `NSEvent`s, keeps windows offscreen and makes the app behave as active.
- **CLI:** builds per-lane app copies with distinct bundle IDs, runs `xcodebuild test-without-building` lanes in parallel, keeps real-only tests in a real lane and merges `.xcresult` bundles.
- **Sample app:** a small AppKit/SwiftUI app with its own UI tests that proves delivery of clicks, keyboard, menus and focus on each Xcode version.

## Known limits

- **Keyboard focus:** the agent keeps menu tracking's key-focus requests (`CPSStealKeyFocus*`) from reaching the window server, so a simulated app never takes the user's keyboard (`Notes/keyboard-focus-2026-11-02.md`). ScreenGuard does not watch keyboard focus; check the WindowServer log for `key thief updated`.
- **Automation Mode:** queries, snapshots and launch monitoring still go through testmanagerd, which turns on macOS Automation Mode (and its indicator) for every run, offscreen included.

Anything that leaves the app process cannot be simulated and stays in the real lane: Finder and other system apps, drag and drop through the window server, out-of-process open/save panels, permission dialogs. The interception relies on private Xcode protocols and can break with any Xcode release.

It is generic for macOS apps built on AppKit (including SwiftUI). Zforge is the first consumer.
