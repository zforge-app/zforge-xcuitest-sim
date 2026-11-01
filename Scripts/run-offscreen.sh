#!/bin/zsh
# Runs `xcodebuild test-without-building` on a throwaway copy of a test build while the screen guard
# records frontmost-app changes, cursor movement, visible windows and synthetic events.
#
# Usage: run-offscreen.sh [--real] <name> <xctestrun of the build> <guard process names (comma separated)> [xcodebuild args...]
#   default: simulated (offscreen) run: the copy is prepared with prepare-xctestrun.py
#   --real:  real XCUITest run (takes the screen; tell the user first): the copy is only stripped
# Output: $XCUISIM_RESULTS (default .local/results)/<name>.{xcresult,log,guard.log}
#
# The build products directory (the xctestrun's directory) is copied into
# $XCUISIM_WORK/runs/<name>-<time>-<pid>; the copy carries no app extensions. The run refuses to start
# while a process of another run's copies is alive. At the end, also on abort (system dialog, SIGINT,
# SIGTERM), leftover processes of the copy are terminated and reported, the copy is unregistered from
# Launch Services and pluginkit and deleted (Scripts/copy_hygiene.py dispose). XCUISIM_KEEP_COPY=1
# keeps the (unregistered) copy for diagnostics.
set -uo pipefail
root=${0:A:h:h}
mode=sim
[[ ${1:-} == --real ]] && { mode=real; shift; }
name=$1 source=$2 watched=$3; shift 3
results=${XCUISIM_RESULTS:-$root/.local/results}
work=${XCUISIM_WORK:-$HOME/Library/Caches/dev.xcuitestsim}
identity=${XCUISIM_SIGN_IDENTITY:-Apple Development}
mkdir -p $results
if [[ $source == *-offscreen.xctestrun ]]; then
    echo "$name: pass the build's own xctestrun; the offscreen variant is made on the copy"; exit 2
fi
[[ -f $source ]] || { echo "$name: no xctestrun at $source"; exit 2; }
hygiene=(python3 $root/Scripts/copy_hygiene.py)
busy=$(python3 -c "import sys; sys.path.insert(0, '$root/Scripts'); import copy_hygiene as h; print(' '.join(f'{p}:{q}' for p, q in h.runs_in_progress()))")
[[ -z $busy ]] || { echo "$name: another run is in progress ($busy); not started"; exit 1; }
run_dir=$(python3 -c "import sys; sys.path.insert(0, '$root/Scripts'); import copy_hygiene as h; print(h.new_run_dir('$name'))")
guard= xcb=
finish() {
    [[ -n $xcb ]] && kill $xcb 2>/dev/null
    [[ -n $guard ]] && { kill $guard 2>/dev/null; wait $guard 2>/dev/null; }
    if [[ -n ${XCUISIM_KEEP_COPY:-} ]]; then
        $hygiene cleanup $run_dir | sed "s/^/$name: /"
        echo "$name: copy kept at $run_dir"
    else
        $hygiene dispose $run_dir | sed "s/^/$name: /"
    fi
}
trap finish EXIT
trap 'echo "$name: interrupted"; exit 130' INT TERM
products=$run_dir/products
python3 -c "import sys; sys.path.insert(0, '$root/Scripts'); import copy_hygiene as h; h.clone_tree(sys.argv[1], sys.argv[2])" ${source:A:h} $products \
    || { echo "$name: could not copy ${source:A:h}"; exit 1; }
xctestrun=$products/${source:t}
if [[ $mode == sim ]]; then
    $root/Scripts/prepare-xctestrun.py $xctestrun --identity $identity > $run_dir/prepare.log 2>&1 \
        || { echo "$name: prepare-xctestrun.py failed:"; tail -5 $run_dir/prepare.log; exit 1; }
    xctestrun=${xctestrun%.xctestrun}-offscreen.xctestrun
else
    $hygiene strip $run_dir > $run_dir/prepare.log 2>&1 || { echo "$name: strip failed"; tail -5 $run_dir/prepare.log; exit 1; }
fi
$hygiene preflight $run_dir 2>&1 | sed "s/^/$name: /"
[[ ${pipestatus[1]} -eq 0 ]] || { echo "$name: not started (copy not clean)"; exit 1; }
rm -rf $results/$name.xcresult $results/$name.guard.log $results/$name.log
$work/build/ScreenGuard $results/$name.guard.log ${(s:,:)watched} &
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
echo "$name: xcodebuild exit $code after ${elapsed}s ($mode)"
grep -E "^Test Case .*(passed|failed)|error:|\*\* TEST" $results/$name.log | sed 's/^/  /' | head -60
echo "  guard: $(tail -1 $results/$name.guard.log)"
