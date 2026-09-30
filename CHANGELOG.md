# Changelog

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
