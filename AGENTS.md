# zforge-xcuitest-sim — agent instructions

Generic tool to run existing macOS XCUITest suites offscreen and in parallel. Read README.md first.

- Write all code, docs, logs and test strings in English.
- Keep the tool independent of Zforge: no Zforge paths, names or assumptions in the tool itself. Zforge-specific configuration lives in the Zforge repository.
- The tool depends on private XCTest/XCUIAutomation interfaces. Record the Xcode version (`xcodebuild -version`) next to every finding and keep reverse-engineered interface notes under `Notes/`.
- Never weaken a consumer app's Release build. Anything the agent needs (linking, entitlements) belongs only in a dedicated test build configuration.
- A simulated pass is not equivalent to a real XCUITest pass until the tool has been validated against real runs (same suite both ways, plus injected regressions that the simulated run must also catch). Report results with that distinction.
- Do not run UI tests in the real (screen-taking) mode without telling the user first.
- No automatic commit, push or publication.
