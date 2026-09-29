# Brief review and platform constraints

Written 2026-09-29 against iOS 27.0.1 and Xcode 27. Each platform claim links the Apple page it came from; claims resting on search snippets, forum posts or inference say so.

## 1. Summary

The brief's priorities are right. It goes wrong where it assumes things iOS does not offer: SafetyKit is gated and late, background camera capture does not exist, and the obvious recording API cannot roll over files without a gap.

| Brief assumption | Reality | Consequence for the design |
|---|---|---|
| SafetyKit may deliver Apple crash events | Only with a restricted entitlement granted on request, to one app per device, carrying date, location and SOS response | Optional adapter behind `DASHCAM_SAFETYKIT`; manual button and motion heuristic are the real triggers |
| A crash event can immediately protect buffered footage | Events arrive by critical alert, after Emergency SOS when SOS is on, often via background launch with the camera stopped | Triggers accept a past `occurredAt` and protect segments already on disk |
| Write segments to temporary storage | tmp/ and Caches/ are purgeable | Buffer in Application Support, excluded from backup |
| Segmented circular recording with AVFoundation | Not with AVCaptureMovieFileOutput, which must stop to switch files and stops on backgrounding | One AVAssetWriter in segmented fMP4 mode; loss on termination bounded by one 4 s segment |
| Background or locked-screen recording "where iOS permits" | Never permitted for the camera; locking backgrounds the app | Removed; foreground-only with the idle timer off and a dim mode |
| Core Motion can supplement detection | 100 Hz maximum, undocumented range, no background delivery | Experimental, off by default, called an impact, never a crash |
| Thermal pressure is one condition | Two signals, `thermalState` and the camera's `systemPressureState` | Frame-rate throttling on both; a forced gap at shutdown is possible |
| Interruption, thermal, SafetyKit tests | No camera, microphone or motion in the Simulator; thermal forcing only on a device; no documented SafetyKit trigger | Linux, Simulator and device tiers; app-owned Simulate Crash |
| Long device tests | Free accounts get 7-day profiles; TestFlight and restricted entitlements need the paid program | Owner decides on the paid program before soak testing |
| App Store and privacy, to investigate | Privacy manifest and Guideline 2.5.14 are hard gates | Manifest, consent screen and a REC indicator that survives dim mode are V0.1 work |
| CarPlay features, if permitted | No camera category | Not possible |

## 2. Topics

### SafetyKit and Crash Detection

Verified. The entitlement is `com.apple.developer.severe-vehicular-crash-event`, requested through a [sign-in form](https://developer.apple.com/contact/request/vehicular-crash-events/) ([entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.severe-vehicular-crash-event)). "Only one app on the device can receive Crash Detection events" ([overview](https://developer.apple.com/documentation/safetykit)), and `.denied` means "another app has authorization" ([SAAuthorizationStatus](https://developer.apple.com/documentation/safetykit/saauthorizationstatus)). An event has `date`, `location` and `response`, no severity ([SACrashDetectionEvent](https://developer.apple.com/documentation/safetykit/sacrashdetectionevent)). With Emergency SOS off, "a critical alert occurs and the third party receives the crash information"; with it on, only "after the first party completes its procedures" ([overview](https://developer.apple.com/documentation/safetykit)). A non-running app is launched in the background, and the system "may report the same Crash Detection event across different launches of your app, so always check date" ([delegate](https://developer.apple.com/documentation/safetykit/sacrashdetectiondelegate/crashdetectionmanager(_:diddetect:))); there is no completion handler or documented time budget. `SAError.Code.notAllowed` ("restricts the feature on this iPhone at the current time") differs from `.denied` ([SAError.Code](https://developer.apple.com/documentation/safetykit/saerror/code)). Apple says to test in the Simulator but names no mechanism ([thread 727615](https://developer.apple.com/forums/thread/727615)).

For this app. With SOS on, its screen takes over and the camera stops (inference), so SafetyKit can only protect footage already written. The flag-gated adapter triggers with `occurredAt: event.date` and dedupes by date; the coordinator loads storage and holds a background task before handling a trigger, so a cold background launch can still link footage. Apple's stated purpose, "initiating a call to a contact designated by the app, such as a roadside assistance provider", makes approval for a dash cam uncertain.

Unverified. The form's criteria. The Account Holder must have accepted the latest license agreement ([thread 770430](https://developer.apple.com/forums/thread/770430)); that only the Account Holder can submit is inferred from the Fall Detection equivalent. "iPhone 14 or later" and the roughly 20 s SOS countdown come from a support page seen only as a snippet. Latency with SOS on is undocumented.

### AVFoundation recording

Verified. For the movie file output, "In iOS, to avoid any errors, you must call stopRecording() before calling this method again" ([startRecording](https://developer.apple.com/documentation/avfoundation/avcapturefileoutput/startrecording(to:recordingdelegate:))), and recordings stop on backgrounding ([thread 61406](https://developer.apple.com/forums/thread/61406)). AVAssetWriter's segmented mode uses `init(contentType:)` and a delegate, which suppresses file writing ([delegate](https://developer.apple.com/documentation/avfoundation/avassetwriterdelegate/assetwriter(_:didoutputsegmentdata:segmenttype:segmentreport:))). The sample crossing each interval boundary "will be forced to be encoded as sync sample", and the CMAF profile handles AAC priming with an edit list ([WWDC20 10011](https://developer.apple.com/videos/play/wwdc2020/10011/)). Apple lists 1080p30 HEVC at 4500 to 5800 kb/s ([HLS authoring spec](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)). `activeFormat` and `sessionPreset` are mutually exclusive ([activeFormat](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat)). iOS 27 deprecates `expectsMediaDataInRealTime` ([doc](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/expectsmediadatainrealtime)).

For this app. ARCHITECTURE.md describes the writer. The iOS 18 target keeps the legacy append path, so the iOS 27 SDK warns. Stabilization prefers `lowLatency` (iOS 26), then `standard`; cinematic modes crop the view and are not used.

Unverified. That init plus concatenated media segments plays locally and survives passthrough export follows from the documented pieces but needs a device (medium confidence); the Simulator test checks it with synthetic H.264. Also open: A/V alignment after remux, and hardware HEVC, which the code checks at runtime with an H.264 fallback.

### Background, lock screen and interruptions

Verified. "Camera usage is prohibited while in the background" ([videoDeviceNotAvailableInBackground](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason/videodevicenotavailableinbackground)). Multitasking camera access covers only iPad Stage Manager, VoIP apps or an entitlement ([isMultitaskingCameraAccessSupported](https://developer.apple.com/documentation/avfoundation/avcapturesession/ismultitaskingcameraaccesssupported)); LockedCameraCapture is a user-launched Lock Screen extension ([LockedCameraCapture](https://developer.apple.com/documentation/lockedcameracapture/creating-a-camera-experience-for-the-lock-screen)). `isIdleTimerDisabled` suits "programs where the app needs to continue displaying content when user interaction is minimal" ([doc](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)). The writer "must give up encoding resources" in the background; `applicationDidEnterBackground` gets "approximately five seconds" and a background task about 30 s, not guaranteed ([doc](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationdidenterbackground(_:))). A phone call takes the audio device ([InterruptionReason](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason)). There is "no guarantee that an app will receive an interrupted ended notification", and media services can be reset from Settings > Developer ([mediaServicesWereResetNotification](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification)).

For this app. Backgrounding finishes the run inside a background task; an audio-only interruption keeps video; the watchdog restarts capture when frames stop and reconciles state with `session.isInterrupted` when a notification never comes; a reset rebuilds the session. The app calls `setPrefersNoInterruptionsFromSystemAlerts(true)`, so a banner-style call should interrupt audio only if answered ([doc](https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersnointerruptionsfromsystemalerts(_:))). Hands-free Bluetooth input is avoided because a CarPlay head unit mutes media when an app takes its microphone ([DTS, via this page](https://developer.apple.com/documentation/avfoundation/avcapturesession/automaticallyconfiguresapplicationaudiosession)). Dim mode sets brightness through the window scene's screen, since `UIScreen.main` is deprecated in iOS 26.

Open. Whether video keeps flowing during a ringing banner call needs a device. 2025 forum reports describe a persistent multiple-foreground-apps interruption on iPhone cleared only by rebooting.

### Thermal, power and storage

Verified. Apple's WWDC19 advice is that "at thermal state critical, your app should stop using peripherals such as the camera" ([thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification)). The camera's pressure state adds `shutdown`, where "the capture system automatically shuts down" ([SystemPressureState](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempressurestate-swift.class)); the documented first mitigation is a lower frame rate ([property](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempressurestate-swift.property)). Free space should come from `volumeAvailableCapacityForImportantUsageKey`; iOS 27 truncates `volumeAvailableCapacityKey` ([key](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)). tmp/ and Caches/ are purgeable ([iCloud backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)). The default protection class stays writable after first unlock; the Data Protection capability would make it Complete ([Encrypting files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)). Apple says not to compute battery drain rate ([battery](https://developer.apple.com/documentation/uikit/uidevice/batteryleveldidchangenotification)).

For this app. Either signal at serious sets 24 fps, at critical 15 fps. Continuing at thermal critical deliberately departs from Apple's advice so footage continues; the soak test must show it does not lead to shutdown. HDR is disabled at configuration (inference: less ISP load, SDR output). At 4.5 Mb/s the 5-minute buffer is about 170 MB and a default incident clip about 205 MB. The free-space floor defaults to 1 GB. A "Not charging" hint shows while recording on battery.

Open. Apple publishes no power figures; that a 5 W charger is inadequate is low-confidence inference. The code sets `isExcludedFromBackup` on the buffer and logs directories at launch; since Apple warns the flag can reset on some file operations, confirm on device that the buffer stays out of backups.

### Core Motion and Core Location

Verified. CMMotionManager's "maximum supported frequency is 100 Hz" ([WWDC23 10179](https://developer.apple.com/videos/play/wwdc2023/10179/)); the accelerometer's range is undocumented ([CMAcceleration](https://developer.apple.com/documentation/coremotion/cmacceleration)). The motion usage key is not required for CMMotionManager ([NSMotionUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmotionusagedescription)), yet an `authorizationStatus()` marked iOS 27.2 has appeared ([doc](https://developer.apple.com/documentation/coremotion/cmmotionmanager/authorizationstatus())). Motion updates "stop within a few seconds of the app leaving the foreground" ([thread 841001](https://developer.apple.com/forums/thread/841001)). Core Location "does not commit to a particular update rate" and negative speed means invalid ([speed](https://developer.apple.com/documentation/corelocation/cllocation/speed)); When-In-Use suffices in the foreground ([doc](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization())).

For this app. The detector runs only while recording and is off by default. Low sensitivity needs 4 consecutive samples over 4.0 g, medium 3 over 3.0 g plus rotation, high 2 over 2.2 g plus braking and rotation. The usage string ships anyway. Location is deferred.

Low confidence. Apple's Crash Detection reportedly uses a 256 g accelerometer, barometer and microphone (press coverage). Published thresholds (about 4 g impact, 0.3 to 0.5 g braking) came from snippets. The phone's clip level must be measured; the bundled traces are synthetic.

### Tooling, versions and testing constraints

Verified. Xcode 27 "includes Swift 6.4", needs macOS Tahoe 26.6 on Apple silicon and debugs iOS 17 and later ([release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)). The Simulator "doesn't have access to device cameras" ([AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)) or motion and microphone input ([Simulator guide](https://developer.apple.com/library/archive/documentation/IDEs/Conceptual/iOS_Simulator_Guide/TestingontheiOSSimulator/TestingontheiOSSimulator.html)). Thermal states can be raised on a connected device through Device Conditions ([WWDC19 412](https://developer.apple.com/videos/play/wwdc2019/412/)). Free accounts get 7-day profiles on 3 devices ([memberships](https://developer.apple.com/support/compare-memberships/)). GitHub's macos-26 image defaults to Xcode 26.6.

For this app. DashcamCore avoids os.Logger and Darwin-only volume keys, so it tests on Linux. AVFoundation file APIs are not on the Simulator's unsupported list (medium-high inference), so the Simulator test drives the real writer with synthetic frames. Nothing has been compiled with Xcode yet.

### App Store review and privacy

Verified. A capture session without the camera or microphone usage string "raises an exception" ([requestAccess](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:))). App Store Connect rejects undeclared required-reason APIs, and E174.1 requires behaviour that changes with disk space "in a way that is observable to users" ([reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)). Guideline 2.5.14 requires "explicit user consent" and "a clear visual and/or audible indication when recording"; 2.4.2 covers heat and battery; 2.5.4 limits background modes; 5.1.1(i) requires a privacy policy link even with no data collected ([guidelines](https://developer.apple.com/app-store/review/guidelines/)). The system recording indicator cannot be hidden, and users "may be surprised if an app immediately starts recording on launch" ([WWDC20 10676](https://developer.apple.com/videos/play/wwdc2020/10676/)). On-device data is not "collected" ([privacy details](https://developer.apple.com/app-store/app-privacy-details/)). From April 2027 uploads need the iOS 27 SDK (Apple developer news).

For this app. The manifest declares DiskSpace (E174.1, 85F4.1), FileTimestamp (C617.1) and UserDefaults (CA92.1), no tracking, no collected data; a Simulator test guards these entries and the usage strings. A first-run consent screen, a REC indicator that stays visible in dim mode, opt-in auto-start and a separate audio toggle answer 2.5.14. The label can be "Data Not Collected", but a hosted privacy policy is still needed. Photos saving uses add-only access. Expected age rating 4+. Comparable dash cam apps are on the store (medium confidence).

Low confidence. About 11 US states require all-party consent to record conversations, and California Vehicle Code 26708 requires a notice that "a passenger's conversation may be recorded" and limits windshield placement. These come from snippets of secondary sources such as the [RCFP guide](https://www.rcfp.org/reporters-recording-guide/) and need counsel. The location usage string is declared although no location code exists. The code reads the host clock through Core Media, not on Apple's SystemBootTime list per the research; confirm with Xcode's privacy report.

## 3. Things iOS does not permit

1. Camera capture while the app is in the background or the screen is locked. No background mode changes this.
2. Using the audio, voip or location background modes to keep a camera app alive (Guideline 2.5.4).
3. Gapless file rollover with AVCaptureMovieFileOutput.
4. Resuming an AVAssetWriter after suspension.
5. Hiding the system camera or microphone indicator.
6. Receiving Crash Detection events without the entitlement, alongside another designated app, or with a severity value.
7. Firing a test Crash Detection event through any documented mechanism.
8. Reading the dedicated sensors Apple's Crash Detection uses (per press coverage).
9. Core Motion delivery in the background without another background mode, or above 100 Hz.
10. Showing a camera app on CarPlay, or taking the car's microphone without muting its media.
11. Camera, microphone, motion or thermal input in the Simulator.
12. Restricted entitlements, TestFlight or profiles longer than 7 days on a free account.

## 4. Version baseline

As of 2026-09-29 ([Apple releases](https://developer.apple.com/news/releases/)): iOS 27.0.1 (24A446), released 2026-09-28; Xcode 27 (27A266a), released 2026-09-14, with Swift 6.4 and the iOS 27 SDK; iOS 27.2 and Xcode 27.2 in beta. On 2026-06-07, 79% of all iPhones using the App Store ran iOS 26 ([App Store support](https://developer.apple.com/support/app-store/)).

Decision: develop with Xcode 27, Swift 6.4 and the iOS 27 SDK; deploy to iOS 18.0 for reach. The research recommended iOS 26, also defensible, since it removes the `#available` checks and the second append path. The cost of iOS 18 is small: `lowLatency` stabilization sits behind `#available(iOS 26, *)`, the deprecated append path stays, and CI's Xcode 26.6 can build an iOS 18 target. DashcamCore declares iOS 17 and macOS 14. SafetyKit (iOS 16) does not constrain the target.
