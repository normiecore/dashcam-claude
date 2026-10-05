# Dashcam Android 0.1

First Android prototype alongside the existing iPhone app. Initial physical target:
Solana Seeker; its Android version still needs confirmation. Minimum Android 9
(API 28), compile/target API 35. Version `0.1.0-dev.1`.

Verified build: `98c6eaaf1a2013bfd210f64f468e97434d1ca670`.
[Download APK artifact](https://github.com/normiecore/dashcam-claude/actions/runs/37272375031/artifacts/11329275709)
(open `outputs/apk/debug/app-debug.apk` inside the ZIP).
[Build and emulator evidence](https://github.com/normiecore/dashcam-claude/actions/runs/37272375031):
Debug/Release and instrumentation compile, zero lint errors, 200,647 core assertions,
five Android 15 emulator tests pass. Physical Seeker recording is still unverified.
APK SHA256: `e380a3ea0a3f2fa168b81918db160d26fa8ca0e9d56aa36cbfca6fb474bed24b`.

## Included

- Rear camera preview and user-started camera foreground service.
- H.264 MP4, 720p target (supported smaller resolution fallback), optional AAC audio.
- Approximately ten-second segments and a five-minute rolling buffer.
- Manual incident protection covering available prior five minutes plus a 30-second tail.
- Overlapping incidents share protected footage; future tail segments are pinned automatically.
- Durable manifest, conservative interrupted/orphan recovery, low-space stop at a 256 MiB reserve.
- Library, per-clip playback and sharing of incident MP4 segments.
- Recording notification with Save/Stop; non-sticky service, no reboot auto-start.

The MediaRecorder prototype stops/restarts between segments and may lose footage at
boundaries. Measure gaps on the target phone before relying on this build. Incident
export shares separate original MP4s; a joined movie is not implemented. Stop before
the tail ends leaves partial coverage. Uncertain files stay retained and may not play;
damaged-media repair and explicit deletion of saved/recovery footage are outstanding.

## Build and install

Use JDK 17, Android SDK platform 35 and Gradle 8.11.1. CI installs these and uploads
an installable, debug-signed APK with reports. Debug signing is for this prototype.
The build caches its prototype debug key to permit updates while that cache survives;
cache loss or a different signing key may require an uninstall, which removes
private footage. Export saved footage before uninstalling. Stable release signing
is not configured.

```sh
bash Android/core-tests/run.sh
cd Android
gradle :app:assembleDebug :app:assembleRelease :app:lintDebug
gradle :app:connectedDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Alternatively download the build's GitHub Actions artifact on the Seeker, extract
the ZIP, open `app-debug.apk` and allow installation for that browser/files app if
Android asks. Start recording while the app is visible and allow Camera. Audio is
optional. Notifications expose controls while the app is in the background.

Footage lives in private app storage. Android backup/device transfer is excluded.
There is no network permission or upload. Sharing grants read access only to selected
MP4 files. Uninstalling or clearing app data deletes private footage.

## Verification and phone acceptance

Core tests exercise interval boundaries, overlap protection, tail segments, safe
pruning, restart recovery, corrupt metadata and persistence failure. Synthetic bytes
in these tests do not prove MP4 validity. Emulator instrumentation separately checks
Android directory sync, activity/provider behavior and recording as available.
Neither establishes physical camera reliability.

Run instrumentation on a fresh emulator install without user footage or granted
camera permission. It grants Camera itself for the synthetic recording test.
The suite is intended for disposable test storage, not an installed app with saved
incidents. Core assertions and emulator media samples are distinct from phone tests.

On the Seeker, record phone model, Android version, build commit and results:

1. Record six minutes. Save at minute five; continue at least 35 seconds, then stop.
   Play/share the saved segments and confirm prior footage and tail coverage.
2. Save twice 15 seconds apart. Confirm both incidents retain their overlapping clips.
3. Record while switching apps and with screen off for at least two minutes each.
   Inspect every segment boundary and note gaps, frozen frames and audio issues.
4. Stop/restart, rotate, deny microphone permission, interrupt camera with another
   app, force-stop mid-segment, then reopen. Completed clips must remain; interrupted
   bytes must be retained without a playback guarantee.
5. Check low storage stops recording without removing saved/uncertain footage.
6. Run at least a one-hour recording session and inspect heat, battery, dropped
   footage and bounded rolling storage. Do not manufacture thermal stress.

Automatic crash detection, GPS, cloud upload and seamless segmentation are absent.
Screen-off continuity needs physical verification. Camera/microphone services are
started only from visible user interaction, consistent with Android's current
[service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
and [background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start),
rechecked on 2026-10-05. Native Camera2 avoids an unnecessary dependency for this slice;
see the [Camera2 overview](https://developer.android.com/media/camera/camera2).
