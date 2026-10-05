#!/bin/bash
# Turns a UI test run into a preview of the app for people without a Mac: the screenshots the UI
# tests attach (DashcamUITests.snapshot), the screen recording CI made of the run, and a README.md
# that shows them on GitHub. CI uploads the folder as the simulator-preview artifact and publishes
# it to the simulator-preview branch.
#
# Usage: scripts/simulator-preview.sh <UITests.xcresult> <output folder>
# The output folder may already hold ui-tests.mov from `simctl io recordVideo`.
set -uo pipefail

result="$1"
out="$2"
mkdir -p "$out"

if [ ! -d "$result" ]; then
  echo "::warning::No UI test result at $result, so the preview has no screenshots."
  exit 0
fi

attachments=$(mktemp -d)
if ! xcrun xcresulttool export attachments --path "$result" --output-path "$attachments"; then
  echo "::warning::xcresulttool could not export the screenshots."
  exit 0
fi

# The raw recording is large; re-encode it to 720p. Keep the original if that fails. GitHub refuses
# files over 100 MB and warns over 50 MB, so a video still over 45 MB stays out of the branch.
video=""
if [ -s "$out/ui-tests.mov" ]; then
  if avconvert --preset Preset1280x720 --source "$out/ui-tests.mov" --output "$out/ui-tests.mp4" --replace >/dev/null 2>&1 \
     && [ -s "$out/ui-tests.mp4" ]; then
    rm -f "$out/ui-tests.mov"
    video="ui-tests.mp4"
  else
    echo "::warning::avconvert could not re-encode the recording; keeping the original."
    video="ui-tests.mov"
  fi
  if [ "$(stat -f %z "$out/$video")" -gt $((45 * 1024 * 1024)) ]; then
    mkdir -p "$out/large"
    mv "$out/$video" "$out/large/"
    video="large/$video"
  fi
fi

python3 - "$attachments" "$out" "$video" "${PREVIEW_SOURCE:-}" "${UI_TESTS_OUTCOME:-}" <<'PY'
import json
import pathlib
import re
import shutil
import sys

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
video, source, outcome = sys.argv[3], sys.argv[4], sys.argv[5]

images = (".png", ".jpg", ".jpeg", ".heic")
try:
    manifest = json.loads((src / "manifest.json").read_text())
    # Only the tests' own snapshots: Xcode adds its own screenshots, recordings and UI hierarchies
    # to a failing test, and those are marked isAssociatedWithFailure.
    entries = [a for test in manifest for a in test.get("attachments", [])
               if not a.get("isAssociatedWithFailure", False)
               and pathlib.Path(a.get("exportedFileName", "")).suffix.lower() in images]
except (OSError, ValueError, AttributeError, TypeError) as error:
    print(f"::warning::Unexpected attachments manifest ({error}); using the exported file names.")
    entries = [{"exportedFileName": p.name} for p in sorted(src.iterdir()) if p.suffix.lower() in images]

shots = []
for attachment in entries:
    exported = attachment["exportedFileName"]
    # suggestedHumanReadableName is the attachment's name plus an index and a UUID.
    name = pathlib.Path(attachment.get("suggestedHumanReadableName") or exported).stem
    title = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", name)
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    filename = slug + (pathlib.Path(exported).suffix or ".png")
    shutil.copy(src / exported, out / filename)
    shots.append((title, filename))
shots.sort()

lines = ["# Dashcam in the iOS Simulator", ""]
if source:
    lines += [source, ""]
if outcome and outcome != "success":
    lines += [f"**The UI tests did not pass on this run ({outcome}).** A failing test stops at the",
              "failure, so its later screens are missing.", ""]
lines += [
    "Screenshots taken by the UI tests in the iOS Simulator with the simulated camera. The Simulator",
    "has no camera, so the preview area stays empty; on an iPhone it shows the rear camera.",
    "",
]
if video.startswith("large/"):
    lines += ["The screen recording of the run is too large for this branch; it is in the run's",
              "simulator-preview artifact.", ""]
elif video:
    lines += [f"Screen recording of the whole UI test run: [{video}]({video})", ""]
for title, filename in shots:
    lines += [f"## {title}", "", f'<img src="{filename}" width="320" alt="{title}">', ""]
(out / "README.md").write_text("\n".join(lines))
print(f"{len(shots)} screenshots" + (f", video {video}" if video else ", no video"))
PY
