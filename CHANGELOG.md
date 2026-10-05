# Changelog

## Android 0.1.0-dev.2 UI refinement — 2026-10-05

- Added a consistent native dark/mint theme, adaptive launcher icon, large recording
  controls, clear idle/recording states and persistent Recorder/Footage navigation.
- Replaced nested library menus with Saved/Recent/Recovery browsing, thumbnails,
  direct playback/share, live incident-tail status and explanatory empty states.
- Added audio/privacy/storage settings, saved audio preference, camera onboarding,
  permission-dialog state restoration and confirmation before stopping an incident tail.
- Verified Debug/Release and test compilation, lint, 200,647 storage assertions
  and ten Android 15 emulator checks, including actual recording and accessible
  incident/settings interactions. Reviewed seven clean emulator screenshots.
- Final verified build: `0651518568001b0cabbee858107a41ffe7d57925`,
  hosted run `37281099291`; installable APK artifact `11332392247`.
- APK is 120,898 bytes; source remains native Java with no UI dependency bundle.
  New branch has a different debug signing key: export old footage before reinstalling.
  Physical Seeker acceptance and production signing remain pending.

## Android 0.1 prototype — 2026-10-05

- Separated the installable app artifact from the AndroidTest APK after download
  size confusion; provided an app-only installer ZIP containing the verified binary.

- User chose Android first, deferring iPhone signing/TestFlight.
- Added isolated native Android preview/foreground recording, ten-second MP4 segments,
  rolling retention, durable manual incident protection, recovery, playback and sharing.
- Added storage/retention tests and hosted build/emulator verification workflow.
- Verified 200,647 Android core assertions and five Android 15 emulator tests,
  including synthetic MP4 segment/incident/tail recording. Debug/Release compilation,
  device-test compilation and lint passed; physical Seeker recording remains untested.
- Fixed actual compiler errors in native directory sync and share Intent calls.
  Added media fsync, conservative write-failure stop, partial-tail status, thermal/
  storage stops, monotonic recording timestamps, bounded renewable wake lock and
  API 30 guards for camera/microphone service types.
- Prototype signing key is cached outside source control; cache survival is required
  for future updates to preserve signing identity. Production signing remains deferred.
- MediaRecorder boundaries may have gaps; physical Seeker acceptance remains required.
- Preserved iPhone source and its implementation branch.
- Final verified Android build: `98c6eaaf1a2013bfd210f64f468e97434d1ca670`;
  hosted run `37272375031`, installable debug APK artifact `11329275709`.

## Session handover — 2026-10-05

- Paused implementation/signing at the user's request; preserved the iPhone candidate.
- Recorded potential Android direction, Solana Seeker availability, unconfirmed second phone model and Android versions.
- Recorded reported Apple enrollment with activation/access still unconfirmed.
- Added root HANDOVER.md and AGENTS.md startup/maintenance instructions; linked from README.
- Documentation only; no new application build or physical testing claimed.

## 0.1.0-dev.1 — packaging follow-up, 2026-09-30

- Added an opaque app icon asset and a deterministic, dependency-free generator.
- Added a hosted Release iPhoneOS archive gate checking arm64 output, icon compilation, privacy manifest, permission strings and debug symbols.
- Documented the iPad/iPhone account steps for later signed TestFlight distribution. No signing credentials are stored in the repository.
- Local project and portable retention checks pass. Hosted Debug/Release simulator builds, all 16 XCTest cases and the unsigned arm64 device archive checks pass in run `36671496781`. Fixed the archive checker’s `lipo` argument order after its first real execution. Device installation and physical acceptance still require Apple signing.

## 0.1.0-dev.1 — 2026-09-29

Implemented source:

- Native SwiftUI app, rear wide-camera capture, optional microphone, segmented MOV writer and large manual incident control.
- Five-minute rolling policy, 30-second incident tails, durable manifests, overlap-safe protection, file validation and two-phase cleanup.
- Retained crash/storage-fault buffers, quarantined uncertain media, fail-closed metadata errors, bounded writer finalization and dropped-frame monitoring.
- Saved-incident playback, derivative export/share, confirmed incident deletion, debug incident/interruption injection, OSLog diagnostics.
- Xcode project/shared scheme, privacy manifest, Git history, Mac/CI scripts, portable production-policy tests and 16 Apple XCTest methods.

Verified here: C compiler/warnings, 400,036 checks in normal and ASan/UBSan builds, accelerated 12-hour policy simulation, PBX grammar/graph, plists, scripts and whitespace.

Hosted verification: Xcode 26.6 Debug and Release simulator builds and all 16 XCTest cases pass. The first hosted test exposed inflated sparse-segment duration; explicitly ending the writer session at the last accepted frame fixes it. Added assertions for original segment duration and retained the export duration regression. Source and hosted workflow are in private GitHub draft PR #2; see `Docs/Verification.md` for evidence.

Not verified: actual camera/hardware encoder output, signing/install, interruption behavior and physical soak. This is not a release build.

Decisions: foreground/unlocked only; 720p30 target; audio off by default; no SafetyKit entitlement or motion classifier; originals in Application Support; backup excluded; preserve uncertain footage even at the cost of refusing further recording. C is a small production policy boundary enabling native execution on this Linux host, not a duplicate test implementation.

Outstanding: Apple signing/distribution, physical acceptance, recovery/repair UX, SafetyKit eligibility and eventual integration. Compiler warnings remain for legacy orientation and export callback APIs. No `v0.1.0` release tag until mandatory gates pass.
