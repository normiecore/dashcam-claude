import SwiftUI
import DashcamCore

/// App root: three tabs, the dimmed-recording cover and the first-run consent screen.
struct RootView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings
    @State private var selection: RootTab = .record

    enum RootTab: Hashable {
        case record
        case clips
        case settings
    }

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                Tab("Record", systemImage: "record.circle", value: RootTab.record) {
                    DashcamView()
                }
                Tab("Clips", systemImage: "film.stack", value: RootTab.clips) {
                    ClipsLibraryView()
                }
                .badge(pendingClipCount)
                Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                    SettingsView()
                }
            }

            // Dimmed mode covers the whole app, tab bar included; the TabView (and the camera preview in
            // it) stays alive underneath so nothing about the capture session changes.
            if coordinator.isDimmed {
                DimmedRecordingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.isDimmed)
        .fullScreenCover(isPresented: showsOnboarding) {
            OnboardingView()
                .environmentObject(settings)
                .environmentObject(coordinator)
        }
    }

    /// Incidents still securing or exporting footage.
    private var pendingClipCount: Int {
        coordinator.incidents.filter { incident in
            switch incident.state {
            case .collecting, .readyToAssemble, .assembling: return true
            case .complete, .failed: return false
            }
        }.count
    }

    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { isPresented in
                if !isPresented { settings.hasCompletedOnboarding = true }
            }
        )
    }
}
