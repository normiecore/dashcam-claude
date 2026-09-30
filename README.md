# Dashcam

An iPhone dash cam that records continuously into a rolling buffer (five minutes by default), keeps footage on the phone, and preserves the minutes before and after an incident when you tap Save Incident or, optionally, when a strong impact is detected.

Status: V0.1 in progress. The core logic is tested on Linux and macOS, the app target compiles in CI, and the first physical-device validation pass has not happened yet. See `CHANGELOG.md`.

## Layout

- `Sources/DashcamCore`, `Tests/DashcamCoreTests`: platform-independent Swift package (retention, incidents, assembly, motion heuristic). `swift test` runs anywhere Swift 6 does.
- `Sources/DashcamSim`: `dashcam-sim`, a command-line drive simulator against the real core.
- `App/`: the iOS app. `App/project.yml` is the XcodeGen spec; the `.xcodeproj` is generated.
- `docs/PLATFORM_REVIEW.md`: the brief reviewed against current Apple documentation, with what iOS does not permit.
- `docs/ARCHITECTURE.md`, `docs/PLAN.md`, `docs/TESTING.md`.

## Quick start on a Mac

1. Install Xcode 27 (Xcode 26.6 also builds it) and XcodeGen: `brew install xcodegen`.
2. Generate the project: `cd App && DASHCAM_TEAM_ID=YOURTEAMID xcodegen generate`. Find the team id in Xcode under Settings > Accounts, or leave it out and choose the team in Signing & Capabilities.
3. Open `App/Dashcam.xcodeproj`, select your iPhone (Developer Mode on) and run. In the Simulator, which has no camera, Debug builds record from a simulated camera instead, so the screens, incidents and clips can be tried there (see `docs/TESTING.md`).
4. Run the tests: `swift test` at the repository root for the core, and Product > Test in Xcode (or the command in `docs/TESTING.md`) for the app.

License: TBD
