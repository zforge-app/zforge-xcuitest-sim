#!/bin/zsh
# Runs `xcodebuild test-without-building` on an xctestrun (prepared offscreen variant, or the
# original one for a real run) while the screen
# guard records frontmost-app changes, cursor movement and visible windows.
# Usage: run-offscreen.sh <name> <xctestrun> <guard process names (comma separated)> [xcodebuild args...]
# Output: $XCUISIM_RESULTS (default .local/results)/<name>.{xcresult,log,guard.log}
# When the xctestrun belongs to a copy inside $XCUISIM_WORK, the run starts only if no process of the
# copy is alive (leftover Launch Services/pluginkit registrations are removed first), and at the end,
# also on abort, leftover processes of the copy are terminated and reported and the copy is
# unregistered (Scripts/copy_hygiene.py). Build products outside $XCUISIM_WORK are left alone.
set -uo pipefail
root=${0:A:h:h}
name=$1 xctestrun=$2 watched=$3; shift 3
results=${XCUISIM_RESULTS:-$root/.local/results}
mkdir -p $results
work=${XCUISIM_WORK:-$HOME/Library/Caches/dev.xcuitestsim}
hygiene=()
if [[ ${xctestrun:A:h} == ${work:A}/* ]]; then
    hygiene=(python3 $root/Scripts/copy_hygiene.py)
    $hygiene preflight $xctestrun 2>&1 | sed "s/^/$name: /"
    [[ ${pipestatus[1]} -eq 0 ]] || { echo "$name: not started (copy in use or not clean)"; exit 1; }
fi
guard= xcb=
finish() {
    [[ -n $xcb ]] && kill $xcb 2>/dev/null
    [[ -n $guard ]] && { kill $guard 2>/dev/null; wait $guard 2>/dev/null; }
    (( $#hygiene )) && $hygiene cleanup $xctestrun | sed "s/^/$name: /"
}
trap finish EXIT
trap 'echo "$name: interrupted"; exit 130' INT TERM
rm -rf $results/$name.xcresult $results/$name.guard.log $results/$name.log
${XCUISIM_WORK:-$HOME/Library/Caches/dev.xcuitestsim}/build/ScreenGuard $results/$name.guard.log ${(s:,:)watched} &
guard=$!
start=$(date +%s)
# perl alarm: hard stop after 20 minutes so a hung run cannot block forever.
perl -e 'alarm shift; exec @ARGV' 1200 xcodebuild test-without-building -xctestrun $xctestrun \
    -destination 'platform=macOS,arch=arm64' -resultBundlePath $results/$name.xcresult "$@" > $results/$name.log 2>&1 &
xcb=$!
# A system prompt (TCC, crash reporter...) in front means the run is interacting with the user:
# stop immediately and report instead of waiting for a timeout.
while kill -0 $xcb 2>/dev/null; do
    if grep -q " front UserNotificationCenter" $results/$name.guard.log 2>/dev/null; then
        echo "$name: ABORTED — a system dialog (UserNotificationCenter) came to the front; check the screen"
        kill $xcb; break
    fi
    sleep 0.5
done
wait $xcb
code=$?
xcb=
elapsed=$(( $(date +%s) - start ))
kill $guard; wait $guard 2>/dev/null; guard=
echo "$name: xcodebuild exit $code after ${elapsed}s"
grep -E "^Test Case .*(passed|failed)|error:|\*\* TEST" $results/$name.log | sed 's/^/  /' | head -60
echo "  guard: $(tail -1 $results/$name.guard.log)"
