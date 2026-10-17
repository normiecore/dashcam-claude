import SwiftUI

@main
struct HassyNaturalApp: App {
    init() {
        // Previous sessions' temporary working copies are disposable. Recovery
        // captures in Documents are deliberately preserved.
        for folder in ["Imports", "Picker", "Exports"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(folder))
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--camera-ui-testing") || arguments.contains("--camera-denied-ui-testing") {
            // Deterministic UI fixtures, without overriding the preferences domain.
            UserDefaults.standard.set(arguments.contains("--advanced-ui-testing"), forKey: "advancedCamera")
            UserDefaults.standard.removeObject(forKey: "photoAspectRatio")
            UserDefaults.standard.removeObject(forKey: "photoSaveModeV2")
            UserDefaults.standard.removeObject(forKey: "photoFileFormat")
            UserDefaults.standard.removeObject(forKey: "photoFileQuality")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(CameraTheme.accent)
        }
    }
}
