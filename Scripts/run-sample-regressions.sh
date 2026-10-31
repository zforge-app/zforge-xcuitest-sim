#!/bin/zsh
# Negative controls: each regression build breaks one handler in the sample app; the offscreen
# run of the unchanged suite must fail the matching test (and only tests that depend on it).
set -uo pipefail
root=${0:A:h:h}
regressions=(${@:-CLICK SHORTCUT TYPING CONTEXT MENU MODIFIER HOVER FOCUS})
(( $# )) || regressions=(CLICK SHORTCUT TYPING CONTEXT MENU MODIFIER HOVER FOCUS)
for regression in $regressions; do
    xctestrun=$($root/Scripts/build-sample.sh $regression)
    $root/Scripts/prepare-xctestrun.py $xctestrun --identity "${XCUISIM_SIGN_IDENTITY:-Apple Development}" > /dev/null 2>&1
    $root/Scripts/run-offscreen.sh sample-reg-${regression:l} ${xctestrun%.xctestrun}-offscreen.xctestrun SampleApp,SampleAppUITests-Runner
done
