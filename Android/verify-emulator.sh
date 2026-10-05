#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
test_result=0
gradle --no-daemon :app:connectedDebugAndroidTest || test_result=$?
mkdir -p app/build/reports/androidTests/ui-screenshots
for image in 01-ready 02-library-empty 03-recording 04-library-saved 05-landscape; do
    target="app/build/reports/androidTests/ui-screenshots/$image.png"
    adb pull "/sdcard/Download/dashcam-ui/$image.png" "$target" || rm -f "$target"
done
if [ "$test_result" -eq 0 ]; then
    python3 - <<'PY'
from pathlib import Path
for name in ["01-ready", "02-library-empty", "03-recording", "04-library-saved", "05-landscape"]:
    image = Path("app/build/reports/androidTests/ui-screenshots") / (name + ".png")
    assert image.read_bytes().startswith(bytes([137, 80, 78, 71, 13, 10, 26, 10])), f"Missing valid screenshot: {name}"
PY
fi
exit "$test_result"
