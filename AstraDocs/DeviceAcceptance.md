# Mac and iPhone acceptance

This is the next required gate. It cannot be performed in this Linux workspace. Use a stationary phone for functional tests; a passenger should operate the app during any normal-road test. Never stage a collision, drop a phone, heat it deliberately, or fill a primary phone's storage to failure.

## Build and evidence

Run `bash Tools/verify-mac.sh`. It saves Debug/Release build logs, XCTest results and an `.xcresult` bundle under `build/verification`. Record Mac/Xcode version, iPhone model, iOS version, free storage, audio setting, power/charging state and mount orientation. Keep the current build number with every result. If signing fails, choose your development team under the app target's Signing & Capabilities. No restricted entitlement is used.

For a simulator with a camera unavailable, verify the permission/unavailable-device message rather than expecting a preview. Synthetic `SegmentWriterTests` create sample buffers themselves and do not require a physical camera. They test file output, not device capture.

## First working vertical slice

1. Run on a physical iPhone in the supported landscape orientation. Keep the device unlocked.
2. Start with microphone off. Grant camera access. Confirm the rear-camera preview and that RECORDING appears only after an accepted video frame.
3. Film a clock for at least six minutes. Tap Save Incident at a noted clock time; continue for 40 seconds and stop.
4. Open Saved incidents. Verify timestamp, trigger source, ready state and any partial-history note. Play all segments in sequence and export a combined MOV to Files.
5. Inspect the source segments around the trigger, every ten-second boundary and the end. Expected retained history is approximately five minutes before and at least 30 seconds after, with up to one segment of rounding. Startup-limited recordings must be labeled as shorter history.
6. Relaunch the app and replay. Start a fresh recording and verify prior protected footage is still present. Check ordinary previous-session footage is reclaimed when the new session starts.
7. Download the app container using Xcode's device tools and inspect `AppData/Library/Application Support/Dashcam/manifest.json` plus `segments/`. In Xcode versions that call this window Devices and Simulators, select the installed app and choose Download Container; newer versions may surface it in Device Hub. Preserve the entire container for recovery, not just the video folder.

## Failure and boundary matrix

| Scenario | Method | Required observation |
|---|---|---|
| Microphone denial | Enable microphone, deny the prompt, then start | Video continues; video-only status is explicit. Repeat with audio allowed; inspect audio across segment boundaries. |
| Camera denial/revocation | Deny on first run, later change Settings while stopped | Clear message, no false RECORDING state, no unauthorized start after returning. |
| Permission cancellation | Start, then background during a permission flow; return | Recording does not unexpectedly start. Explicit start required. |
| Overlapping incidents | Save twice five seconds apart | Both remain protected through later pruning; deleting one cannot remove media needed by the other. |
| Early stop | Trigger and stop after five seconds | Incident shows interrupted/partial tail; existing footage remains playable when intact. |
| Background/lock | Trigger, press Home or lock before tail ends | Capture stops, finite finalization completes when allowed, incomplete tail labeled. No claimed background capture. |
| Real interruption | Receive a call/use a competing camera while stationary | Stops or reports interruption; finalized media survives. Explicit restart works. |
| Debug interruption | Developer tools → Simulate recording interruption | Same orderly finalization path; does not establish real-call correctness. |
| Forced process death | Xcode Stop during an ordinary segment; repeat immediately after Save Incident | Relaunch preserves prior finalized/pinned segments. Unfinished segment is quarantined/flagged; no automatic deletion. |
| Force death around rotation | Repeat before, at and just after ten-second boundaries | At most current uncertain writers require recovery; no previously finalized protected files disappear. |
| Corrupt metadata | Use a disposable simulator/test container, back it up, corrupt manifest JSON | Store refuses to reset or record; existing files remain untouched. XCTest exercises this too. |
| Low space | Use policy tests first; only use a disposable test device/container for real capacity tests | Refuses a new file at reserve. Never removes protected/uncertain footage. Avoid filling a personal phone. |
| Export interruption | Begin export, background app | Export cancels/fails cleanly; originals remain protected; export can be retried. |
| Time adjustment/reboot | Use disposable test, change device wall clock, then restart/reboot between sessions | Session-scoped retention unaffected; labels may reflect changed wall clock. |
| Delete protection | Delete a saved incident while stopped, then start a new session | Unprotected finalized media may be reclaimed; overlapping incident media remains. |

## Soak qualification

Run 60–120 minutes in normal, safe conditions. Observe memory, thermal state, dropped-frame counts, storage and segment timestamps using Xcode Instruments/logs. Repeat on battery and normal charging, microphone off/on, and at least one older supported device. Test ordinary mount vibration, potholes and speed bumps only as encountered in normal driving; there is no automatic motion classifier in V0.1, so these test picture stability and recording continuity, not crash-detection accuracy.

Stop/finalization on serious/critical thermal conditions is intentional. Do not call this feature thermally qualified until natural-condition tests establish usable session length. Look for increasing memory, finalization backlog, growing disk usage across sessions, and missing frames around rotation. File existence alone is insufficient: decode/play the videos and compare the visible clock.

## Returning failures

Send `build/verification/debug-build.log`, `release-build.log` or `test.log`, and the failing `.xcresult` if available. For device failures, send the reproduction steps, device/OS/build, event time and relevant OSLog entries under subsystem `com.daz.dashcam`. Export or securely retain the app container before deleting/reinstalling; avoid sharing private road footage unless needed.

Release criterion: all mandatory build/XCTest tests pass and the six-minute incident test plus interruption/recovery and soak tests pass on physical hardware. Until then this is a development candidate, not a validated dashcam.
