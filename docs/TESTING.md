# Testing

## Core package on Linux or macOS

```
make test            # or: swift test
make sim ARGS="drive --hours 2 --incidents 1200,4000"
swift run dashcam-sim replay App/Dashcam/Resources/Traces/impact.csv --sensitivity medium
```

Any Swift 6 toolchain works. In the Linux environment this project was built in, the toolchain lives at `/opt/swift-rootfs/usr/bin` (extracted from the `swift:6.4-noble` image); that path is specific to that environment.

## App on the iOS Simulator

Requires a Mac with Xcode 26.6 or later (Xcode 27 recommended) and XcodeGen (`brew install xcodegen`). The `.xcodeproj` is generated and not committed.

```
cd App && DASHCAM_TEAM_ID=YOURTEAMID xcodegen generate && cd ..
xcodebuild -project App/Dashcam.xcodeproj -scheme Dashcam \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The Simulator has no camera, microphone or motion sensors. Three test files cover what it can:

- `SegmentWriterTests` drives the real segmented `AVAssetWriter` with synthetic video, and with synthetic video and audio together, and checks that whole-run and mid-run clips load with the right duration and aligned tracks before and after the passthrough remux.
- `RecordingCoordinatorTests` drives the real `RecordingCoordinator` (with the real writer, store, incident manager and clip export) against `FakeCaptureService`, a fake camera that produces 30 fps synthetic frames and 44.1 kHz audio on host-clock timestamps and can simulate camera and audio interruptions, runtime errors, media-services resets, a camera that cannot restart and rotation. Each test asserts an invariant that must hold in any event order; the race tests repeat with several delays. Segments are 2 s and post-roll 5 s, so the suite runs in a few minutes.
- `PrivacyManifestTests` guards the manifest and usage strings.

The app itself launches in the Simulator but the Record tab reports that no camera is available.

CI (`.github/workflows/ci.yml`) runs the same command for pull requests on GitHub's preview `xcode-27` label (Xcode 27.0, iOS 27.0 simulator), which is the toolchain the project is opened with; the whole Simulator suite takes about four minutes. A second lane on `macos-26` (Xcode 26.6, iOS 26.5 SDK) runs only when dispatched from the Actions tab, because macOS minutes bill at a multiple on this private repository. Each test has a 180 s execution allowance, so a hang fails in minutes and the streamed log shows where.

## Physical iPhone checklist

Prerequisites: an iPhone on iOS 18 or later with Developer Mode on (Settings > Privacy & Security > Developer Mode, then restart), and a signing team. A free Apple account works for on-device installs (3 devices, profiles expire after 7 days); TestFlight and restricted entitlements need the paid program.

Do not mirror the iPhone with Device Hub's View Screen during any capture step. Apple documents that apps lose the camera and microphone while Device Hub interacts with the device, so the app would record black frames and silence without reporting an error. Watch the phone's own screen instead.

1. Generate the project with your team id, open `App/Dashcam.xcodeproj`, select your iPhone as the run destination, and run. If signing complains, pick your team under Signing & Capabilities for the Dashcam target.
2. First launch: read the welcome screen, tap Continue, tap Start recording, allow camera and (if audio is on) microphone. Confirm the preview is upright in portrait and in landscape, and the HUD shows REC, the buffer counting up to 5:00, the free space chip and the format (expect 1080p 30fps HEVC).
3. Driveway test (10 minutes, engine off, phone mounted): let the buffer fill, watch Settings > Storage show the buffer stabilise around 170 MB, then tap Save Incident. The orange card should count down 60 s and the Clips tab badge should show 1. Open the clip: playback should start at the beginning of the pre-roll, not with a blank lead-in, and the duration should be about 6 minutes. Share it via AirDrop to a Mac and confirm QuickTime plays it. Save to Photos and confirm it appears.
4. Lock the screen while recording, wait 20 s, unlock. Expect "Paused: camera unavailable in background" then automatic resume with a new run; the buffer keeps its earlier footage. Save an incident that spans the gap and confirm two clip files appear.
5. Incoming phone call (ask someone to call): with the banner style, video should continue and the mic chip should appear; accept the call, then hang up and return. Expect the log to show the run rotated to video only at the start of the call and rotated back with audio at the end, and a clip saved across the call to have separate parts. Also lock the phone during a call and unlock while it is still ongoing; recording should resume without audio and get audio back when the call ends.
5a. Orientation: tap Start while holding the phone in portrait, then seat it in a landscape mount. Within a few seconds the log should show "orientation changed" and a new run; a clip saved afterwards must play upright in QuickTime.
5b. Toggle Record audio off and on in Settings while recording. Each toggle should start a new run (log) and the AUDIO badge in the dimmed screen should follow the actual track.
5c. Tap Stop, then Save Incident. The incident must complete with the buffered footage within seconds, not sit at "Recording 60 s more". Also tap Save Incident within a second of tapping Stop: the clip must include the footage right up to the tap (the writer's last segment), which the log shows as the incident attaching one more segment after "Recording stopped".
5d. During a phone call, note in the developer live stats whether video frames keep counting up. If they stop, the app should show "Paused: camera interrupted" within about 5 s and resume when the call ends; if they continue, the run should be video-only and audio should return after the call. Report which of the two happened.
6. Open the Camera app from the Lock Screen or Control Center while Dashcam is frontmost, then return. Expect a pause and a resume.
7. Settings > Developer > Reset Media Services while recording. Expect "Recovering camera" and a resume within a few seconds.
8. Raise the thermal state with Xcode's Device Conditions. In Xcode 26 this is Window > Devices and Simulators, select the iPhone, Device Conditions. Xcode 27 moved device management into the Device Hub app and Apple's Device Hub pages do not mention thermal conditions, so look in the iPhone's inspector there and note whether the control still exists. Choose Thermal State: Serious, then Critical. Expect the frame rate to drop to 24 then 15 fps in the developer live stats and the heat chip to appear; stop the condition and confirm 30 fps returns.
9. Low storage: in Developer tools set Storage floor override to 64 GB or higher than your free space. Expect the buffer to trim and recording to stop with the "almost out of storage" message. Set it back to Off.
10. Force quit the app mid-recording (with an incident collecting if possible), relaunch. Expect the incident to appear as ready or exporting, then complete, and the buffer to still hold its earlier footage minus at most one segment.
11. Soak: mount the phone on the windshield on a car charger, record for at least 60 minutes with Dim screen on. Note the thermal state, frame rate, battery level and any pauses from the developer live stats and log. Export the log afterwards.
12. False positives: turn on Impact detection at Low, drive a normal route with speed bumps and hard stops, and count unwanted incidents. Repeat at Medium. Report the counts and export the log.
13. Optional: connect and disconnect CarPlay while recording; note any audio route changes or pauses.

## Collecting logs

In the app: Settings > Developer > View recent log, then Export log file (share sheet). The file holds the last 2 MB with one rotation.

Only notice level and above from the os_log stream persists on the device by default, so the in-app log file is the complete record. On a Mac with the iPhone connected, Console.app filters by subsystem `com.matrixengineered.dashcam`. For a range of time:

```
sudo log collect --device --start "2026-09-29 10:00:00" --output dashcam.logarchive
```

To pull the log file, or the buffer and incident directories, off the device without the Xcode UI:

```
xcrun devicectl list devices
xcrun devicectl device copy from --device <id> \
  --source "Library/Application Support/Dashcam/logs/dashcam.log" --destination ./dashcam.log \
  --domain-type appDataContainer --domain-identifier com.matrixengineered.dashcam
```

For a system-level failure, hold Volume Up and Volume Down together until the phone vibrates to capture a sysdiagnose, then find it under Settings > Privacy & Security > Analytics & Improvements > Analytics Data. Crash reports for the app appear in the same place, in Xcode's Organizer, and in Xcode 27 under the device's diagnostics tab in Device Hub.
