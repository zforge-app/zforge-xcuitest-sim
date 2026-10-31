#!/bin/zsh
# Builds the runner shim, the app agent and the screen guard into $XCUISIM_WORK/build.
# XCUISIM_WORK defaults to ~/Library/Caches/dev.xcuitestsim: test runners and apps must not load
# anything from TCC-protected folders (Documents, Desktop, Downloads), or macOS prompts the user.
# XCUISIM_SIGN_IDENTITY: identity used to sign the agent (must match the app's team for
# library validation under the hardened runtime). Defaults to ad-hoc.
set -euo pipefail
root=${0:A:h:h}
out=${XCUISIM_WORK:-$HOME/Library/Caches/dev.xcuitestsim}/build
mkdir -p $out
identity=${XCUISIM_SIGN_IDENTITY:--}
common=(-fobjc-arc -fmodules -Wall -Wno-unused-function -O1 -g -arch arm64 -mmacosx-version-min=26.0)
clang $common -dynamiclib -framework AppKit -o $out/libXCUISimRunnerShim.dylib $root/Sources/RunnerShim/RunnerShim.m
clang $common -dynamiclib -framework AppKit -framework Carbon -o $out/libXCUISimAgent.dylib $root/Sources/AppAgent/AppAgent.m
clang $common -framework AppKit -o $out/ScreenGuard $root/Tools/ScreenGuard/ScreenGuard.m
codesign -f -s "$identity" $out/libXCUISimRunnerShim.dylib $out/libXCUISimAgent.dylib $out/ScreenGuard 2>&1 | grep -v "replacing existing signature" || true
echo "built into $out"
