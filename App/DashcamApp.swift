import SwiftUI
import UIKit
import AVFoundation
import OSLog

@main
struct DashcamApp: App {
    @StateObject private var model = DashcamModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { _, phase in
                    if phase == .inactive { model.prepareForBackground() }
                    if phase == .background { model.enterBackground() }
                    if phase == .active { model.enterForeground() }
                }
        }
    }
}

@MainActor
final class DashcamModel: ObservableObject {
    @Published var service: CameraCaptureService?
    @Published var status: CaptureStatus?
    @Published var audioEnabled = false
    @Published var errorMessage: String?
    @Published var exporting = false
    @Published var exportURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let exporter = ClipExportService()
    private let logger = Logger(subsystem: "com.daz.dashcam", category: "app")

    init() {
        // Scanning and recovering the manifest can involve disk I/O.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let service = try CameraCaptureService()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.service = service
                    service.onUpdate = { [weak self] status in
                        self?.status = status
                        UIApplication.shared.isIdleTimerDisabled = UIApplication.shared.applicationState == .active && (status.isRecording || status.isBusy)
                    }
                    service.onError = { [weak self] message in
                        self?.errorMessage = message
                    }
                    service.refreshSnapshot()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = "Storage could not be opened. Existing files have been left untouched. \(error.localizedDescription)"
                }
            }
        }
    }

    var busy: Bool { status?.isBusy == true || exporting }
    var recording: Bool { status?.isRecording == true }
    var starting: Bool { status?.isStarting == true }
    var incidents: [IncidentRecord] { status?.snapshot.incidents.sorted { $0.createdAt > $1.createdAt } ?? [] }
    var canBrowse: Bool { service != nil && !recording && !busy }

    func toggleRecording() {
        if starting { service?.stop(reason: "Start cancelled"); return }
        guard !busy else { return }
        if recording { service?.stop(reason: "Stopped by user") }
        else { service?.start(audioEnabled: audioEnabled) }
    }

    func saveIncident(source: IncidentSource = .manual) {
        service?.saveIncident(source: source)
    }

    func refresh() { service?.refreshSnapshot() }

    func enterForeground() {
        endBackgroundTask()
        refresh()
    }

    func prepareForBackground() {
        guard recording || starting || status?.isStopping == true else { return }
        beginFinalizationAllowance()
    }

    private func beginFinalizationAllowance() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finalize footage") { [weak self] in
            // Existing files are already journaled. No restart or new capture.
            self?.logger.error("Background finalization time expired")
            self?.endBackgroundTask()
        }
    }

    func enterBackground() {
        exporter.cancel()
        guard let service else { return }
        beginFinalizationAllowance()
        service.stop(reason: "App left the foreground; recording stopped") { [weak self] in
            self?.endBackgroundTask()
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func deleteIncident(_ incident: IncidentRecord) {
        guard canBrowse else { return }
        service?.deleteIncident(id: incident.id) { [weak self] result in
            if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
        }
    }

    func export(_ incident: IncidentRecord) {
        guard canBrowse else { return }
        exporting = true
        service?.incidentSegmentURLs(id: incident.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.exporting = false
                self.errorMessage = error.localizedDescription
            case .success(let urls):
                Task {
                    do {
                        let url = try await self.exporter.export(urls: urls, incidentID: incident.id)
                        if UIApplication.shared.applicationState == .active { self.exportURL = url }
                        else { try? FileManager.default.removeItem(at: url) }
                    }
                    catch { self.errorMessage = "Export failed; originals remain protected. \(error.localizedDescription)" }
                    self.exporting = false
                }
            }
        }
    }

    func dismissExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }
}
