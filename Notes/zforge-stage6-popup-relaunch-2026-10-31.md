# Zforge stage 6 — pop-up button menus and relaunch (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Tool `02c5136`
(unchanged during this stage). Zforge `7ea66ec` (clean), same build as the earlier stages
(`Zforge.debug.dylib` `da557f4a8d41b160`). Zforge repository only read. Real runs announced before and after.

## Test and new capabilities

`testLanguageSelectionUpdatesOpenMenuAndPersists`: Settings window opened with ⌘, for each language,
the language pop-up button (NSPopUpButton menu) and a choice in it, Settings closed with its close
button, localized menu bar menu contents, terminate and relaunch in the same test with persistence.

## Results

| | Real | Simulated | Assertion | Tree |
|---|---|---|---|---|
| unmodified | pass 32.14 s | pass 41.33 s | — | identical (214) |
| langpicker: picker bound to a constant, `3fddad11c824f4cd` | fail `LocalizationUITests.swift:48` "File Open must follow Português (Brasil) in mode 2" | same | same | 112 = 112; async debug-description order |
| langsave: language not saved, `c6398e45f858a974` | fail `:60` "The final language must survive relaunch" | same | same | 238 = 238; differences only in waits and debug descriptions |

Screen guard: real 2–4 frontmost changes, 164–360 synthetic events; simulated 0.

## Verdict

**Equivalent** (outcome, identical tree, both regressions on the same assertions). The simulated run
is 29 % slower here (many short menu and window actions; each costs the agent round trips).
