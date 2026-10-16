import SwiftUI

@main
struct HassyNaturalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(CameraTheme.accent)
        }
    }
}
