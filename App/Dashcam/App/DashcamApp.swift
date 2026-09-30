import SwiftUI
import DashcamCore

@main
struct DashcamApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let launch = LaunchConfiguration.current
        // First: a UI-test launch wipes the previous launch's settings and footage here.
        let settings = launch.makeSettings()
        let storage = launch.storage
        let memoryLog = InMemoryLogSink(capacity: 3_000)
        let logger = DashcamLogger(sinks: [memoryLog, FileLogSink(url: storage.logFile), OSLogSink()])
        let coordinator = RecordingCoordinator(settings: settings, logger: logger, memoryLog: memoryLog, capture: launch.makeCapture(), storage: storage)
        if launch.simulatedCamera {
            logger.notice(.app, "Launch: simulated camera\(launch.uiTesting ? ", UI testing" : "")")
        }
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .task { await coordinator.bootstrap() }
        }
    }
}
