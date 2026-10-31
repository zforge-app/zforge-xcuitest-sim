#!/bin/zsh
# Builds the sample app for testing. Optional first argument: a regression flag
# (CLICK, SHORTCUT, TYPING, CONTEXT, MENU, MODIFIER, HOVER, FOCUS) compiled into a separate
# derived data directory for negative-control runs.
set -euo pipefail
root=${0:A:h:h}
regression=${1:-}
work=${XCUISIM_WORK:-$HOME/Library/Caches/dev.xcuitestsim}
dd=${XCUISIM_SAMPLE_DD:-$work/dd-sample${regression:+-reg-${regression:l}}}
xcodebuild build-for-testing -project $root/Sample/SampleApp.xcodeproj -scheme SampleApp -configuration Debug \
    -derivedDataPath $dd CODE_SIGN_IDENTITY="${XCUISIM_SIGN_IDENTITY:-Apple Development}" \
    ${XCUISIM_TEAM:+DEVELOPMENT_TEAM=$XCUISIM_TEAM} ${regression:+SAMPLE_REGRESSION=REGRESSION_$regression} -quiet 2>&1 \
    | grep -E "error:|BUILD FAILED" || true
ls $dd/Build/Products/*.xctestrun | grep -v -- "-offscreen\|-dropped" | head -1
