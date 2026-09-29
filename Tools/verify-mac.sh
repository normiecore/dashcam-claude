#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 Tools/verify_project.py
if ! command -v xcodebuild >/dev/null || ! command -v xcrun >/dev/null; then
  echo 'Xcode command line tools are required. Select full Xcode with xcode-select.' >&2
  exit 2
fi

results_root="${DASHCAM_VERIFY_RESULTS:-$PWD/build/verification}"
mkdir -p "$results_root"
results_dir="$(mktemp -d "$results_root/run-XXXXXXXX")"
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "Evidence: $results_dir"

xcodebuild -project Dashcam.xcodeproj -scheme Dashcam -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$results_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$results_dir/debug-build.log"
xcodebuild -project Dashcam.xcodeproj -scheme Dashcam -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$results_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$results_dir/release-build.log"

simulator_id="$(xcrun simctl list devices available -j | python3 -c '
import json,re,sys
obj=json.load(sys.stdin)
for runtime, devices in obj["devices"].items():
    version=re.search(r"\.iOS-(\d+)", runtime)
    if not version or int(version.group(1)) < 17:
        continue
    for d in devices:
        if d["name"].startswith("iPhone") and d.get("isAvailable", True):
            print(d["udid"])
            sys.exit(0)
sys.exit(1)
')" || {
  echo 'No available iPhone simulator running iOS 17 or later. Install an iOS simulator runtime in Xcode Settings.' >&2
  exit 2
}
echo "Testing on simulator $simulator_id"
xcodebuild -project Dashcam.xcodeproj -scheme Dashcam -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$results_dir/DerivedData" \
  -resultBundlePath "$results_dir/DashcamTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$results_dir/test.log"
echo 'Debug, Release, and simulator XCTest passed. Physical camera and recording acceptance remains separate.'
