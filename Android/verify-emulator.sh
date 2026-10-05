#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
test_result=0
gradle --no-daemon :app:connectedDebugAndroidTest || test_result=$?
mkdir -p app/build/reports/androidTests/ui-screenshots
for image in 01-ready 02-library-empty 03-recording 04-library-saved 05-landscape; do
    target="app/build/reports/androidTests/ui-screenshots/$image.png"
    adb exec-out run-as com.daz.dashcam cat "cache/ui-screenshots/$image.png" > "$target" || rm -f "$target"
done
exit "$test_result"
