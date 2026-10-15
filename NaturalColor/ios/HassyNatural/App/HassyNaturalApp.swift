import SwiftUI

@main
struct HassyNaturalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.91, green: 0.83, blue: 0.67))
        }
    }
}
