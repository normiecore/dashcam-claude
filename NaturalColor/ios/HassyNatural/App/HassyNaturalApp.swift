import SwiftUI

@main
struct HassyNaturalApp: App {
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--camera-ui-testing") || arguments.contains("--camera-denied-ui-testing") {
            // Deterministic UI fixtures, without overriding the preferences domain.
            UserDefaults.standard.set(arguments.contains("--advanced-ui-testing"), forKey: "advancedCamera")
            UserDefaults.standard.removeObject(forKey: "photoAspectRatio")
            UserDefaults.standard.removeObject(forKey: "photoSaveMode")
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
