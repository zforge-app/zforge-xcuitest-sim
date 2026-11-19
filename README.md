# zforge-xcuitest-sim

Runs existing macOS XCUITest suites without taking over the user's screen, and in parallel.

XCUITest normally asks `testmanagerd` to synthesize real HID events through the window server, which moves the cursor, activates the app and steals focus. This tool intercepts that private event-synthesis path in the test runner and delivers the events inside the app under test (offscreen windows, simulated activation). Element queries keep using the real accessibility tree, so existing tests run unchanged.

## Status

Experimental, in daily use. It is [Zforge](https://github.com/zforge-app/zforge)'s offscreen UI test runner: 19 of Zforge's 31 UI tests run through it in three parallel lanes; the others leave the app process and run as real XCUITests (see [Known limits](#known-limits)).

- **Validated on:** Xcode 27.1 (27A9275) with macOS 27.0.1, and Xcode 27.2 (27B52) with macOS 27.2, on Apple silicon. Xcode 27.2 broke the launch hooks; `Notes/xcode-27.2-27B52-macos-27.2-2026-11-09.md` records what changed and the fixes.
- **Private interfaces:** the tool depends on private XCTest and XCUIAutomation interfaces, so any Xcode release can break it. `Notes/` keeps the reverse-engineered interfaces per Xcode version.
- **Evidence:** a simulated pass counts only where it was shown to match a real run. Each capability was checked with the same build run both ways and with an injected regression that both modes must catch (`Notes/real-vs-simulated-2026-10-31.md`, `Notes/zforge-coverage-summary-2026-10-31.md`). The result bundles the notes cite were kept on the development machine (`.local/`, ignored by Git) and are not in this repository.

It is generic for macOS apps built on AppKit (including SwiftUI); nothing in the tool is specific to Zforge.

## How it works

- **Runner shim** (`Sources/RunnerShim/`, `libXCUISimRunnerShim.dylib`): inserted into the UI test runner through the xctestrun. It wraps the runner's session with `testmanagerd` and sends event synthesis (`_XCT_synthesizeEvent:`), launch and activation to the app agent over a private channel instead.
- **App agent** (`Sources/AppAgent/`, `libXCUISimAgent.dylib`): loaded into the app under test. It turns the requests into `NSEvent`s, keeps the app's windows offscreen and makes the app behave as the active app without taking the user's keyboard or front window.
- **Throwaway copies:** the app is never rebuilt or changed. Each run copies the build products, adds a weak load command for the agent to the copy's app and re-signs it (`prepare-xctestrun.py`), runs the copy and deletes it.
- **ScreenGuard** (`Tools/ScreenGuard/`): records frontmost-app changes, cursor movement, visible windows and synthetic events during a run, as evidence that the screen was not touched.
- **Parallel lanes** (`Scripts/run-lanes.py`): one copy per lane with distinct app and runner bundle identifiers (`make-lane.py`, optional app group rename), all lanes under one ScreenGuard, with CPU and memory sampled. Each lane writes its own result bundle.
- **Sample app** (`Sample/`): a small AppKit/SwiftUI app with unchanged XCUITests and compile-time regressions that the offscreen run must catch (`Scripts/run-sample-regressions.sh`).

## Requirements

- Apple silicon, Xcode 27.1 or 27.2 (see [Status](#status)).
- A code-signing identity of the app's team (`XCUISIM_SIGN_IDENTITY`, for example `Apple Development`): under the hardened runtime, library validation only loads the agent when it is signed by the same team.
- An unlocked login session.

Work products go to `$XCUISIM_WORK` (default `~/Library/Caches/dev.xcuitestsim`). Never build or load test products from `~/Documents`, `~/Desktop` or `~/Downloads`: the runner reading them makes macOS show a permission prompt.

## Usage

```sh
XCUISIM_SIGN_IDENTITY="Apple Development" Scripts/build-tools.sh
XCUISIM_TEAM=<team> Scripts/build-sample.sh                         # prints the build's xctestrun path
# simulated (offscreen) run on a throwaway copy of the build; --real for a real XCUITest run (takes the screen)
Scripts/run-offscreen.sh [--real] <name> <build's xctestrun> <app>,<runner> [-only-testing:...]
```

Runs never touch the build itself: each run copies the build products into `$XCUISIM_WORK/runs/<name>-<time>-<pid>`, prepares the copy there (`prepare-xctestrun.py`: weak load command for the agent, re-signing, offscreen xctestrun) and deletes it at the end. Build your own app into `$XCUISIM_WORK` with `Scripts/build-for-testing.sh <derived data path> <xcodebuild args>`.

Parallel lanes (`Notes/zforge-parallel-lanes-2026-10-31.md`):

```sh
Scripts/run-lanes.py --name <run> --results <dir> --watch <app> --watch <runner> --products <build products dir> \
    [--identity "Apple Development"] [--app-group-suffix] [--plist-suffix-key <Info.plist key naming the app group>] \
    [--env XCUISIM_NO_AUTOMATION_MODE=1] \
    --lane <test id>,<test id> --lane <test id>
```

Choosing which tests run offscreen and which run real is up to the consumer; Zforge does it in its `Scripts/affected-tests.py`. Two runs of the same build at the same time would share the lanes' bundle identifiers, so a run refuses to start while another run's copies are alive.

### Copies and the system

Copies and builds are kept from leaking into the rest of the system (`Scripts/copy_hygiene.py`, `Notes/copy-hygiene-2026-11-01.md`, `Notes/ephemeral-copies-2026-11-01.md`):

- **No app extensions.** Copies keep the original bundle identifiers of their extensions, and the system can load a copy's extension instead of the developer's (a Finder Sync extension did). `build-for-testing.sh` and `prepare-xctestrun.py` remove `Contents/PlugIns` and `Contents/Extensions` from the apps (test bundles stay) and loose extension products, re-sign, and prune the xctestruns. Tests that need an extension run in the real group, from the developer's own build.
- **Ephemeral copies.** `run-offscreen.sh` and `run-lanes.py` create their copies at the start of a run and, at the end (also after an abort), terminate and report leftover processes of the copies (such as the app XCUITest leaves running after the last test), unregister them from Launch Services and pluginkit and delete them. A launched copy kept on disk would be re-registered by macOS services (Spotlight, Finder, HIServices) later. A run does not start while another run's copies are in use. Builds made by `build-for-testing.sh` are unregistered after the build and never launched.
- `copy_hygiene.py check|cleanup|strip|dispose [--thorough] <dir>` inspects or cleans any directory of the work directory; tests: `python3 -m unittest discover -s Tests -v` (the last test checks the whole work directory: no extension on disk, nothing registered, no process).

## Known limits

- **Out of process:** anything that leaves the app process cannot be simulated and must run as a real XCUITest: Finder and other system apps, drag and drop through the window server, out-of-process open/save panels, permission dialogs.
- **Keyboard focus:** the agent keeps menu tracking's key-focus requests (`CPSStealKeyFocus*`) from reaching the window server, so a simulated app never takes the user's keyboard (`Notes/keyboard-focus-2026-11-02.md`). ScreenGuard does not watch keyboard focus; check the WindowServer log for `key thief updated`.
- **App switches:** the user's own app switches do not close a simulated app's open menus (AppKit's `_applicationDidSwitch` dismissal is skipped; `Notes/menus-app-switch-2026-11-02.md`). `XCUISIM_APP_TRACE_MENU=1` logs menu dismissals with their callers.
- **Automation Mode:** by default, queries and snapshots go through testmanagerd, which turns on macOS Automation Mode (its indicator and, after a while, an authentication prompt). With `run-lanes.py --env XCUISIM_NO_AUTOMATION_MODE=1` the agent answers them from XCTest's own in-app engine through a direct port, and Automation Mode stays off (`Notes/no-automation-mode-spike-2026-11-02.md`); real-only tests still need it.
- **Xcode releases:** the interception relies on private Xcode protocols and can break with any Xcode release.

## Layout

- `Sources/RunnerShim/` — runner shim.
- `Sources/AppAgent/` — app agent.
- `Tools/ScreenGuard/` — screen guard.
- `Sample/` — sample app, UI tests and regression switches.
- `Scripts/` — build, prepare and run scripts.
- `Tests/` — tests of the copy hygiene.
- `Notes/` — reverse-engineered interfaces per Xcode version and findings, with their dates.

## License

MIT. See [LICENSE](LICENSE).
