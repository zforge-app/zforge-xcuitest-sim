#!/bin/zsh
# Builds a project for testing into a derived data directory inside $XCUISIM_WORK, then keeps the
# build from leaking into the system: Xcode registers the apps it builds with Launch Services, and
# their app extensions keep the real bundle identifiers, so the system could pick this build's
# extension instead of the developer's. After the build, app extensions and plug-ins are removed from
# the products (and from the xctestruns) and everything under the derived data path is unregistered
# (Scripts/copy_hygiene.py strip). Tests that need an extension belong in the real group, which runs
# from the developer's own build.
# Usage: build-for-testing.sh <derived data path> <xcodebuild args (project, scheme, test plan...)>
# Exit status: xcodebuild's (the cleanup runs even when the build fails).
set -uo pipefail
root=${0:A:h:h}
dd=$1; shift
work=${XCUISIM_WORK:-$HOME/Library/Caches/dev.xcuitestsim}
mkdir -p $dd
if [[ ${dd:A} != ${work:A}/* ]]; then
    echo "build-for-testing: $dd is not inside $work; refusing (its products would be modified)" >&2
    exit 2
fi
xcodebuild build-for-testing -derivedDataPath $dd "$@"
code=$?
python3 $root/Scripts/copy_hygiene.py strip $dd >&2 || { (( code == 0 )) && code=1; }
exit $code
