#!/bin/bash
set -euo pipefail
umask 077
key="$RUNNER_TEMP/AuthKey_$ASC_KEY_ID.p8"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$ASC_KEY_P8" > "$key"
build_number="$(date -u +%Y%m%d).$((10#$(date -u +%H%M)))"
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'build_number=%s\n' "$build_number" >> "$GITHUB_OUTPUT"; fi
archive="$RUNNER_TEMP/HassyNatural.xcarchive"
xcodebuild -project HassyNatural.xcodeproj -scheme HassyNatural -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- \
  AD_HOC_CODE_SIGNING_ALLOWED=YES CURRENT_PROJECT_VERSION="$build_number" archive
python3 scripts/check_bundle.py "$archive/Products/Applications/HassyNatural.app"
python3 - <<'PY'
import os,plistlib
from pathlib import Path
options={'method':'app-store-connect','destination':'upload','teamID':os.environ['APPLE_TEAM_ID'],
         'signingStyle':'automatic','manageAppVersionAndBuildNumber':False,
         'testFlightInternalTestingOnly':os.environ.get('NATURAL_EXTERNAL_TESTING') != '1','uploadSymbols':True}
Path(os.environ['RUNNER_TEMP'],'NaturalExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$RUNNER_TEMP/NaturalExportOptions.plist" -exportPath "$RUNNER_TEMP/natural-export" \
  -allowProvisioningUpdates -authenticationKeyPath "$key" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  2>&1 | tee "$RUNNER_TEMP/natural-upload.log"
