# Testing

## Core package on Linux or macOS

```
make test            # or: swift test
make sim ARGS="drive --hours 2 --incidents 1200,4000"
swift run dashcam-sim replay App/Dashcam/Resources/Traces/impact.csv --sensitivity medium
```

Any Swift 6 toolchain works. In the Linux environment this project was built in, the toolchain lives at `/opt/swift-rootfs/usr/bin` (extracted from the `swift:6.4-noble` image); that path is specific to that environment.

## App on the iOS Simulator

CI runs this suite on every pull request, so no Mac is needed to see results. Locally it requires a Mac with Xcode 26.6 or later (Xcode 27 recommended) and XcodeGen (`brew install xcodegen`). The `.xcodeproj` is generated and not committed.

```
cd App && DASHCAM_TEAM_ID=YOURTEAMID xcodegen generate && cd ..
xcodebuild -project App/Dashcam.xcodeproj -scheme Dashcam \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The Simulator has no camera, microphone or motion sensors. Debug builds therefore carry `SimulatedCaptureService`, which produces 30 fps synthetic frames and a 44.1 kHz tone on host-clock timestamps like a capture session. Four test files cover what the Simulator can:

- `SegmentWriterTests` drives the real segmented `AVAssetWriter` with synthetic video, and with synthetic video and audio together, and checks that whole-run and mid-run clips load with the right duration and aligned tracks before and after the passthrough remux.
- `RecordingCoordinatorTests` drives the real `RecordingCoordinator` (with the real writer, store, incident manager and clip export) against the simulated camera, which can also simulate camera and audio interruptions, runtime errors, media-services resets, a camera that cannot restart and rotation. Each test asserts an invariant that must hold in any event order; the race tests repeat with several delays. Segments are 2 s, the buffer 1 minute and post-roll 5 s; one test records for about 85 s so an incident's oldest footage ages out of the buffer while the incident is still collecting, and checks that the incident's links keep it and the clip includes it.
- `DashcamUITests` (XCUITest) taps through the app itself: first-run consent, start and stop, Save Incident, the clip library, clip detail and delete, dimmed mode (REC indicator, hold to save, tap to wake), Simulate Crash from the developer menu, and the camera-denied screen.
- `PrivacyManifestTests` guards the manifest and usage strings.

Running the Debug app in the Simulator uses the simulated camera, so recording, incidents, clips and the developer menu all work there; the preview stays black with a note, since nothing is drawn. Launch arguments for Debug builds:

| Argument | Effect |
|---|---|
| `--simulated-camera` | Synthetic camera and microphone. Always on in the Simulator unless the process hosts unit tests; on a device it replaces the real camera. |
| `--ui-testing` | Own settings and storage (`Library/Application Support/DashcamUITesting`), wiped at every launch, with 2 s segments, a 1 minute buffer and a 5 s post-roll. The app's real footage and settings are not touched. |
| `--skip-onboarding` | With `--ui-testing`, starts past the consent screen. |
| `--camera-denied` | The simulated camera reports camera access as denied. |

Set them in Xcode under Product > Scheme > Edit Scheme > Run > Arguments. Release builds ignore them and always use the real camera.

CI (`.github/workflows/ci.yml`) runs the same command for pull requests on GitHub's preview `xcode-27` label (Xcode 27.0, iOS 27.0 simulator), which is the toolchain the project is opened with, and then archives the Release configuration for a generic iOS device. That checks that the shipping code compiles without the Debug-only simulated camera, runs `scripts/check-app-bundle.sh` (app icon, iPhone only, launch screen, privacy manifest, version substitution) so a TestFlight upload does not bounce, and attaches `Dashcam-unsigned.ipa` to the run. A second lane on `macos-26` (Xcode 26.6, iOS 26.5 SDK) runs only when dispatched from the Actions tab (which needs the workflow on the default branch), because macOS minutes bill at a multiple on this private repository. Each test has a 180 s execution allowance, so a hang fails in minutes and the streamed log shows where.

## Getting the app onto an iPhone without a Mac

The build, signing and upload run on GitHub's macOS runners, so everything on your side happens on the iPhone and in a browser. Two routes:

- **TestFlight (recommended).** Needs the paid Apple Developer Program (99 USD a year). Install from the TestFlight app, builds last 90 days, no Developer Mode or trust steps, and TestFlight passes crash reports and screenshot feedback back to App Store Connect.
- **Free Apple Account with a Windows or Linux PC.** Costs nothing but needs a PC and a USB cable, the app stops launching after 7 days until you re-install it, and since July 2026 Apple has been rejecting many free-account installs with "The provisioning profile is banned" (0xe8008024) whichever tool is used. Use it only if you have a PC and do not want to pay yet.

### Route A: TestFlight

One-time setup. In Safari, use Request Desktop Website if an Apple or GitHub page is cramped.

1. Already enrolled? Continue with step 2. Otherwise, enrol: install the Apple Developer app on the iPhone. Account tab > sign in with your Apple Account (two-factor authentication on) > Agree if asked > Enroll Now > Continue, and choose Individual. Do the whole enrolment on this one iPhone, signed in to iCloud and protected by a passcode. You enter your legal name, which is shown as the seller on the App Store, and photograph a government ID when asked (a passport works in most regions). Payment is an auto-renewing subscription on your Apple Account's card; gift card balance is not accepted. Enrolling as an organisation needs a D-U-N-S number and takes days longer. Wait for the confirmation email.

2. Open appstoreconnect.apple.com > Business and accept any pending agreements. Until you do, apps cannot be added and uploads fail.
3. Open developer.apple.com/account > Membership details and copy the Team ID (10 characters).
4. developer.apple.com/account > Certificates, Identifiers & Profiles > Identifiers > + > App IDs > App. Choose Explicit, enter `com.normiecore.dashcam`, description Dashcam, tick no capabilities, then Register.
5. App Store Connect > Apps > + > New App: platform iOS; a name that is not already taken on the store (plain "Dashcam" almost certainly is; the name under the home screen icon stays Dashcam); a primary language; the bundle ID from step 4; any SKU, for example DASHCAM001; Full Access. Create.
6. App Store Connect > Users and Access > Integrations > App Store Connect API. If there is a Request Access button, request access and wait for Apple's approval. Then Team Keys > Generate API Key (or + if a key already exists): name it GitHub Actions, set Access to **Admin** (signing in the cloud needs Admin, and the role cannot be changed later), Generate. Download the `.p8` file now, because Apple only lets you download it once, and note the Key ID and the Issuer ID shown on the page. This key can do anything in App Store Connect: keep it only in GitHub secrets, and revoke it on this page if it ever leaks.
7. In the Files app, open the downloaded `AuthKey_<KEYID>.p8`. If it will not preview, rename it to end in `.txt`. Copy all of its text, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines.
8. github.com/normiecore/dashcam-claude > Settings > Secrets and variables > Actions > New repository secret. Add four secrets: `ASC_KEY_ID` (Key ID), `ASC_ISSUER_ID` (Issuer ID), `ASC_KEY_P8` (the copied key text) and `APPLE_TEAM_ID` (Team ID).
9. App Store Connect > your app > TestFlight > + next to Internal Testing. Name the group, tick Enable automatic distribution and add yourself.
10. Install TestFlight from the App Store on the iPhone.
11. Create the label that starts a build: github.com/normiecore/dashcam-claude/labels > New label, name it `testflight` exactly (lower case), Create label. The label menu on a pull request can only pick existing labels. (Or tell me the secrets are in and I will create it and start the first build.)

Each build:

1. Add the `testflight` label to the pull request (on the PR page, Labels). That starts `.github/workflows/testflight.yml`: a quick secrets check, then archive, cloud signing and upload on a macOS runner, about 15 to 20 minutes. To build again, remove and re-add the label, or press Re-run on the run's page; every upload gets a new build number from the clock. Once the workflow file is on the default branch it can also be started from Actions > TestFlight > Run workflow.
2. Wait for processing, usually 5 to 30 minutes after the run finishes. To check, open App Store Connect (the website or the App Store Connect app) > your app > TestFlight; the build shows as Testing once it has reached your group.
3. First build only: Apple emails "You're invited to test" to your App Store Connect address. Open it on the iPhone, tap View in TestFlight, then Accept.
4. Open TestFlight on the iPhone and install Dashcam. Each build expires after 90 days; a newer upload replaces it.

If a run fails, its page shows the error and a `testflight-logs` artifact holds Apple's export logs. Send me the run link.

### Route B: free Apple Account and a PC

1. Every CI run on the pull request uploads `Dashcam-unsigned.ipa` as an artifact: open the run from the PR's Checks tab, scroll to Artifacts and download it to the PC.
2. On Windows, remove the Microsoft Store "Apple Devices" and iTunes apps if installed, then install iTunes from apple.com, which the signing tools need for their USB drivers. On Linux, install `usbmuxd` and `libimobiledevice`.
3. Install a signing tool from its official GitHub releases page only: Impactor (github.com/claration/Impactor) or iloader (github.com/nab138/iloader). Avoid on-device installers and signing services from other sites.
4. Use a separate Apple Account for signing, not your main one: the tool signs in to Apple as you, and an account that has sideloaded before is the one most likely to be refused.
5. Connect the iPhone by USB, unlock it and tap Trust. In the tool, sign in with the signing account, pick `Dashcam-unsigned.ipa` and install.
6. On the iPhone: Settings > Privacy & Security > Developer Mode > on, restart, then tap Enable. If the toggle is missing, start the install once from the tool and look again. Then Settings > General > VPN & Device Management, tap the signing account and Trust.
7. Re-install at least every 7 days with the same tool and the same signing account. If you miss the deadline the app only stops opening; re-installing the same way over it brings it back with its footage and settings. Do not delete the app first: deleting it erases its footage and settings, and installing with a different account or tool puts a second, empty copy beside it.

If the install fails with 0xe8008024 or 0xe8008018, try one brand-new signing account; if that fails too, use Route A.

## Physical iPhone checklist

Prerequisites: the app installed by Route A or B, on iOS 18 or later. Developer tools are hidden in TestFlight and other Release builds: turn on Settings > Developer > Developer menu, then open Developer tools.

1. Open Dashcam from the home screen.
2. First launch: read the welcome screen, tap Continue, tap Start recording, allow camera and (if audio is on) microphone. Confirm the preview is upright in portrait and in landscape, and the HUD shows REC, the buffer counting up to 5:00, the free space chip and the format (expect 1080p 30fps HEVC).
3. Driveway test (10 minutes, engine off, phone mounted): let the buffer fill, watch Settings > Storage show the buffer stabilise around 170 MB, then tap Save Incident. The orange card should count down 60 s and the Clips tab badge should show 1. Open the clip: playback should start at the beginning of the pre-roll, not with a blank lead-in, and the duration should be about 6 minutes. Tap Save to Photos and play it in the Photos app; also share it to Files (Save to Files) and play it from there.
4. Lock the screen while recording, wait 20 s, unlock. Expect "Paused: camera unavailable in background" then automatic resume with a new run; the buffer keeps its earlier footage. Save an incident that spans the gap and confirm two clip files appear.
5. Incoming phone call (ask someone to call): with the banner style, video should continue and the mic chip should appear; accept the call, then hang up and return. Expect the log to show the run rotated to video only at the start of the call and rotated back with audio at the end, and a clip saved across the call to have separate parts. Also lock the phone during a call and unlock while it is still ongoing; recording should resume without audio and get audio back when the call ends.
5a. Orientation: tap Start while holding the phone in portrait, then seat it in a landscape mount. Within a few seconds the log should show "orientation changed" and a new run; a clip saved afterwards must play upright in the app and in Photos.
5b. Toggle Record audio off and on in Settings while recording. Each toggle should start a new run (log) and the AUDIO badge in the dimmed screen should follow the actual track.
5c. Tap Stop, then Save Incident. The incident must complete with the buffered footage within seconds, not sit at "Recording 60 s more". Also tap Save Incident within a second of tapping Stop: the clip must include the footage right up to the tap (the writer's last segment), which the log shows as the incident attaching one more segment after "Recording stopped".
5d. During a phone call, note in the developer live stats whether video frames keep counting up. If they stop, the app should show "Paused: camera interrupted" within about 5 s and resume when the call ends; if they continue, the run should be video-only and audio should return after the call. Report which of the two happened.
6. Open the Camera app from the Lock Screen or Control Center while Dashcam is frontmost, then return. Expect a pause and a resume.
7. Developer tools > Simulate media services reset while recording. Expect "Recovering camera" and a resume within a few seconds.
8. Heat: without a Mac the thermal state cannot be forced, so watch for it during the soak (step 11), for example on a warm day in the sun. When the heat chip appears, the developer live stats should show the frame rate dropping to 24 and then 15 fps, and 30 fps returning once the phone cools. With a Mac, Xcode's Device Conditions (Thermal State: Serious, then Critical) forces it.
9. Low storage: in Developer tools set Storage floor override to 64 GB or higher than your free space. Expect the buffer to trim and recording to stop with the "almost out of storage" message. Set it back to Off.
10. Force quit the app mid-recording (with an incident collecting if possible), relaunch. Expect the incident to appear as ready or exporting, then complete, and the buffer to still hold its earlier footage minus at most one segment.
11. Soak: mount the phone on the windshield on a car charger, record for at least 60 minutes with Dim screen on. Note the thermal state, frame rate, battery level and any pauses from the developer live stats and log. Export the log afterwards.
12. False positives: turn on Impact detection at Low, drive a normal route with speed bumps and hard stops, and count unwanted incidents. Repeat at Medium. Report the counts and export the log.
13. Optional: connect and disconnect CarPlay while recording; note any audio route changes or pauses.

## Collecting logs

In the app: Developer tools > View recent log > Prepare log file for export, then Export log file and send it with Mail, Messages or Save to Files. The file holds the last 2 MB with one rotation, and it is the complete record: only notice level and above from the system log persists on the device.

Crash reports: Settings > Privacy & Security > Analytics & Improvements > Analytics Data, entries starting with Dashcam; open one and use the share button. In a TestFlight build you can also take a screenshot while Dashcam is open and send it as TestFlight feedback with a note, and crashes that testers share reach App Store Connect under TestFlight > Crashes.

For a system-level failure, hold Volume Up and Volume Down together until the phone vibrates to capture a sysdiagnose; it appears in the same Analytics Data list after a few minutes.

### With a Mac

Not needed for any of the above, but if one is available: run from Xcode with a free account (Developer Mode on), force thermal states with Device Conditions, and do not mirror the iPhone with Device Hub's View Screen during capture (apps lose the camera and microphone while Device Hub interacts with the device). Console.app filters by subsystem `com.normiecore.dashcam`, and:

```
sudo log collect --device --start "2026-09-29 10:00:00" --output dashcam.logarchive
xcrun devicectl device copy from --device <id> \
  --source "Library/Application Support/Dashcam/logs/dashcam.log" --destination ./dashcam.log \
  --domain-type appDataContainer --domain-identifier com.normiecore.dashcam
```
