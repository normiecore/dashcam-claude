import SwiftUI
import DashcamCore

@main
struct DashcamApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let settings = AppSettings()
        let memoryLog = InMemoryLogSink(capacity: 3_000)
        let logger = DashcamLogger(sinks: [memoryLog, FileLogSink(url: AppPaths.logFile), OSLogSink()])
        let coordinator = RecordingCoordinator(settings: settings, logger: logger, memoryLog: memoryLog)
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
