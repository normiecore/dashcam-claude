# Verification checkpoint — 29 September 2026

Version: **0.1.0-dev.1**. Status: implementation candidate, **iOS simulator builds pass; not device-qualified**.

## Actually executed in this environment

Local environment: Ubuntu 24.04, x86_64, GCC 13.3.0. No Swift compiler, Xcode, Apple SDK, simulator or attached iPhone is present locally. Hosted Xcode verification is now running through GitHub Actions; see below.

| Check | Result | Scope |
|---|---|---|
| C compile with `-Wall -Wextra -Werror -Wconversion -pedantic` | PASS | Same production `RetentionPolicy.c` called by Swift storage |
| C policy tests, optimized binary | PASS: 400,036 assertions | Includes 100,000 deterministic randomized cases |
| AddressSanitizer + UndefinedBehaviorSanitizer | PASS: same assertions | LeakSanitizer disabled because container process inspection fails; policy itself allocates no memory |
| Accelerated 12-hour policy simulation | PASS | 4,320 simulated segments, four incident triggers, 100 protected segments, zero protected deletions |
| Rolling window in simulation | PASS | Maximum 30 ordinary ten-second segments; 4,203 unprotected segments deleted; 117 total retained at the end |
| PBX/OpenStep grammar and graph | PASS | Ten source/test files, build phases, references, plist and shared scheme validation |
| Shell syntax / Python byte compilation / whitespace | PASS | Build and test tooling only |
| Mac verification script here | BLOCKED, exits 2 as intended | Reports missing Xcode; no fake compilation or test success |

Run portable checks again with `bash Tools/test-core.sh` and `python3 Tools/verify_project.py`.

These checks do not validate Swift persistence, capture, encoding, export, permissions or hardware. The 12-hour simulation is accelerated policy logic, **not twelve hours of camera recording**.

## Hosted Xcode verification

The [first hosted run](https://github.com/normiecore/dashcam-claude/actions/runs/36592348632) used Xcode 26.6 (17F113) on `macos-26`. Debug and Release simulator builds passed. All 12 storage tests and three media tests passed. The remaining integration test caught a real discrepancy: two sparse segments exported to 60 seconds instead of approximately 40 seconds.

The writer now explicitly ends its session at the final accepted video sample's end, preventing an inferred final-frame duration from extending presentation. The integration test also checks each original segment's duration against the stored coverage. [The follow-up run](https://github.com/normiecore/dashcam-claude/actions/runs/36592919853) **passed both builds and all 16 XCTest cases with zero failures** on code commit `f3d7b8e68c50ba909a8c8337431ec5f1ea3ba018`. Linux policy checks passed in both hosted runs. [Logs and XCTest evidence](https://github.com/normiecore/dashcam-claude/actions/runs/36592919853/artifacts/11045135729) are retained as a GitHub artifact.

Compiler warnings remain for deprecated orientation APIs and the legacy export completion callback's non-Sendable capture in Swift 5 mode. These are not build errors; a Swift 6 migration and physical orientation/audio checks remain separate work.

## XCTest coverage

Twelve storage tests cover durable triggers, past/future protection, overlapping incidents, old-session cleanup with reset monotonic clocks, crash/orphan recovery, corrupt/missing manifests, metadata replacement failure, finalized post-event coverage, accepted-frame start times, and retaining the buffer after unexpected termination or a storage fault.

Four media tests cover a synthetic playable MOV, empty-writer rejection, backward timestamps, and a synthetic writer → store → incident → reload → export integration path that verifies originals remain byte-identical. They require Apple frameworks. Sparse frames in the integration test deliberately exercise timestamps without pretending to be a real-time capture soak.

## Important defects found and corrected during review

- Previous sessions' ordinary footage accumulated; cleanup now reclaims clean stopped sessions without comparing clocks across boots.
- A delayed/dropped first frame could falsely extend coverage; finalized metadata now uses the first accepted sample timestamp.
- Damaged media could be silently skipped when exporting; overlapping damaged/missing files now require recovery instead.
- Metadata errors could allow fresh recording/deletion; errors now latch a recording stop, and suspicious sessions remain retained across relaunch.
- Low-space preflight could prevent old-session cleanup from running; safe cleanup now precedes that gate.
- Generated Xcode objects omitted final field semicolons; generator fixed and a grammar parser added, with a malformed-input regression check.
- Export cancellation on background and finite pre-background finalization allowance added. Originals are never export working files.

## Remaining gates and limitations

1. Hosted `bash Tools/verify-mac.sh` gate is complete: Debug and Release builds and all 16 XCTest methods pass. Re-run it for later code changes. Results are preserved in separate run directories under `build/verification`.
2. Configure Apple signing/distribution to install on a physical iPhone. No signing credentials or paid Apple membership were used for the simulator gate.
3. Perform the six-minute incident test and the full [physical acceptance matrix](DeviceAcceptance.md). Validate orientation, audio continuity, sample gaps, thermal behavior, memory, charging and interrupted file recovery.
4. No automatic repair of damaged MOVs, no recovery-item deletion UI, and no automatic crash classifier. Suspicious buffers may consume extra disk space until reviewed; this is deliberate preservation-first behavior.
5. File fragments and atomic journaling reduce loss but cannot guarantee zero loss during power failure, device damage or sudden termination.
6. Unfinished export derivatives live in purgeable cache storage. Saved originals are local-only and excluded from backup. Export important evidence separately.
7. Apple approval, actual SafetyKit integration, App Store assets/privacy submission, and release qualification are deferred. Current code deliberately uses iOS-17-compatible APIs, including some deprecated-but-available AVFoundation interfaces; modernizing those requires compile/device verification.

The next gate is signed installation and physical-device acceptance.
