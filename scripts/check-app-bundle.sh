#!/bin/bash
# Checks a built Dashcam.app for what an App Store Connect upload needs, so a missing icon or an iPad
# build fails in CI instead of bouncing after upload. macOS only (plutil).
#   scripts/check-app-bundle.sh path/to/Dashcam.app [expected CFBundleVersion]
set -u
app="$1"
expected_build="${2:-}"
plist="$app/Info.plist"
failures=0

fail() { echo "::error::$1"; failures=$((failures + 1)); }
value() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null; }

[ -f "$plist" ] || { echo "::error::No Info.plist at $plist"; exit 1; }

# actool records the icon under CFBundleIcons on iOS (the top-level key is the macOS form).
icon_name="$(value CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName)"
[ -n "$icon_name" ] || icon_name="$(value CFBundleIconName)"
[ "$icon_name" = "AppIcon" ] || fail "CFBundleIconName is not AppIcon: the asset catalog icon is missing (ITMS-90713)"
[ -f "$app/Assets.car" ] || fail "No Assets.car in the bundle: the asset catalog was not compiled"
family="$(plutil -extract UIDeviceFamily json -o - "$plist" 2>/dev/null | tr -d ' \n')"
[ "$family" = "[1]" ] || fail "UIDeviceFamily is $family, expected [1] (iPhone only)"
plutil -extract UILaunchScreen json -o - "$plist" >/dev/null 2>&1 || fail "UILaunchScreen is missing (ITMS-90870)"
[ -f "$app/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy is not in the bundle"
ls "$app"/*.debug.dylib >/dev/null 2>&1 && fail "A debug dylib is in the bundle: this is not a Release build"

version="$(value CFBundleShortVersionString)"
build="$(value CFBundleVersion)"
case "$version$build" in *'$('*|'') fail "Version or build number was not substituted: '$version' ($build)";; esac
if [ -n "$expected_build" ] && [ "$build" != "$expected_build" ]; then
  fail "CFBundleVersion is $build, expected $expected_build"
fi

echo "Bundle $(value CFBundleIdentifier) $version ($build), device family $family, icon $icon_name"
[ "$failures" -eq 0 ] || { echo "$failures check(s) failed. Info.plist:"; plutil -p "$plist"; exit 1; }
echo "All bundle checks passed"
