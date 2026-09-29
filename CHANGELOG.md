# Changelog

## 0.1.0-dev.1 — 2026-09-29

Implemented source:

- Native SwiftUI app, rear wide-camera capture, optional microphone, segmented MOV writer and large manual incident control.
- Five-minute rolling policy, 30-second incident tails, durable manifests, overlap-safe protection, file validation and two-phase cleanup.
- Retained crash/storage-fault buffers, quarantined uncertain media, fail-closed metadata errors, bounded writer finalization and dropped-frame monitoring.
- Saved-incident playback, derivative export/share, confirmed incident deletion, debug incident/interruption injection, OSLog diagnostics.
- Xcode project/shared scheme, privacy manifest, Git history, Mac/CI scripts, portable production-policy tests and 16 Apple XCTest methods.

Verified here: C compiler/warnings, 400,036 checks in normal and ASan/UBSan builds, accelerated 12-hour policy simulation, PBX grammar/graph, plists, scripts and whitespace.

Not verified: Swift compilation, XCTest execution, actual camera/encoder output, signing/install, interruption behavior and physical soak. See `Docs/Verification.md`; this is not a release build.

Decisions: foreground/unlocked only; 720p30 target; audio off by default; no SafetyKit entitlement or motion classifier; originals in Application Support; backup excluded; preserve uncertain footage even at the cost of refusing further recording. C is a small production policy boundary enabling native execution on this Linux host, not a duplicate test implementation.

Outstanding: Mac build fixes if any, physical acceptance, recovery/repair UX, SafetyKit eligibility and eventual integration. No `v0.1.0` release tag until these mandatory gates pass.
