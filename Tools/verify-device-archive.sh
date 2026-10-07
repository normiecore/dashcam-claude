#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Compile against the device SDK and exercise archive packaging before asking
# for signing credentials. This output cannot be installed or sent to TestFlight.
results_root="${DASHCAM_VERIFY_RESULTS:-$PWD/build/verification}"
mkdir -p "$results_root"
results_dir="$(mktemp -d "$results_root/device-XXXXXXXX")"
archive_path="$results_dir/Dashcam.xcarchive"
xcodebuild -project Dashcam.xcodeproj -scheme Dashcam -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  -derivedDataPath "$results_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO archive 2>&1 | tee "$results_dir/device-archive.log"

python3 - "$archive_path" <<'PY'
import pathlib, plistlib, subprocess, sys
archive = pathlib.Path(sys.argv[1])
app = archive / 'Products/Applications/Dashcam.app'
with (app / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], info
assert info['UIDeviceFamily'] == [1], info['UIDeviceFamily']
assert info['NSCameraUsageDescription'] and info['NSMicrophoneUsageDescription']
assert info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon'
assert (app / 'Assets.car').is_file()
with (app / 'PrivacyInfo.xcprivacy').open('rb') as f:
    plistlib.load(f)
subprocess.run(['lipo', str(app / info['CFBundleExecutable']), '-verify_arch', 'arm64'], check=True)
assert (archive / 'dSYMs/Dashcam.app.dSYM').is_dir()
print('PASS: unsigned arm64 iPhone archive, app icon, privacy manifest and symbols')
print('Not installable: Apple signing, export and physical testing remain required.')
PY
