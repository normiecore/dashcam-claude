import Foundation
import DashcamCore

/// How this process was launched. Release builds always record from the real camera into the app's
/// own directories; the options below exist in Debug builds only.
///
/// - `--ui-testing`: settings and storage of its own, wiped at every launch, with 2 s segments, a
///   1 minute buffer and a 5 s post-roll so UI tests run in seconds. The app's real footage and
///   settings are never touched.
/// - `--skip-onboarding`: with `--ui-testing`, starts past the consent screen.
/// - `--simulated-camera`: synthetic frames and a tone instead of the camera and microphone. On by
///   default in the Simulator, which has no camera, except when the process hosts unit tests.
/// - `--camera-denied`: the simulated camera reports camera access as denied.
struct LaunchConfiguration {
    var uiTesting = false
    var skipOnboarding = false
    var simulatedCamera = false
    var cameraDenied = false

    static var current: LaunchConfiguration {
        #if DEBUG
        LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        #else
        LaunchConfiguration()
        #endif
    }

    init() {}

    init(arguments: [String], environment: [String: String]) {
        uiTesting = arguments.contains("--ui-testing")
        skipOnboarding = arguments.contains("--skip-onboarding")
        cameraDenied = arguments.contains("--camera-denied")
        simulatedCamera = arguments.contains("--simulated-camera") || cameraDenied
        #if targetEnvironment(simulator)
        // Unit tests inject their own fake; the host app keeps the real service and stays idle.
        if environment["XCTestConfigurationFilePath"] == nil { simulatedCamera = true }
        #endif
    }

    private static let uiTestingDefaultsSuite = "com.normiecore.dashcam.ui-testing"
    private static var uiTestingRoot: URL {
        AppPaths.root.deletingLastPathComponent().appendingPathComponent("DashcamUITesting", isDirectory: true)
    }

    var storage: StorageLocations {
        uiTesting ? .isolated(root: Self.uiTestingRoot) : .app
    }

    /// The settings for this launch. Call before anything reads settings or storage: a UI-test launch
    /// first deletes the previous launch's settings and footage.
    func makeSettings() -> AppSettings {
        guard uiTesting else { return AppSettings() }
        UserDefaults.standard.removePersistentDomain(forName: Self.uiTestingDefaultsSuite)
        try? FileManager.default.removeItem(at: Self.uiTestingRoot)
        let settings = AppSettings(defaults: UserDefaults(suiteName: Self.uiTestingDefaultsSuite) ?? .standard)
        settings.segmentSeconds = 2
        settings.bufferMinutes = 1
        settings.recentHistoryMinutes = 1
        settings.postRollSeconds = 5
        settings.minimumFreeMegabytes = 512
        settings.motionDetectionEnabled = false
        settings.autoStartRecording = false
        settings.hasCompletedOnboarding = skipOnboarding
        return settings
    }

    /// The camera for this launch; nil means the real `CameraCaptureService`.
    func makeCapture() -> (any CaptureControlling)? {
        #if DEBUG
        guard simulatedCamera else { return nil }
        let simulated = SimulatedCaptureService()
        if cameraDenied { simulated.cameraStatus = .denied }
        return simulated
        #else
        return nil
        #endif
    }
}
