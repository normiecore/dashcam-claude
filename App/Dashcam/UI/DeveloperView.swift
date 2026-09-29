import AVFoundation
import SwiftUI
import DashcamCore

/// Developer-only tools: fault injection, simulated incidents, motion trace replay, live stats and logs.
struct DeveloperView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings
    @State private var storageFloorMB = 0
    @State private var replayResult: String? = nil
    @State private var replayEvents: [MotionEvent] = []

    private let floorOptions: [(label: String, megabytes: Int)] = [
        ("Off", 0), ("1 GB", 1_024), ("4 GB", 4_096), ("16 GB", 16_384), ("64 GB", 65_536), ("256 GB", 262_144),
    ]
    private let traces = ["pothole", "hard-braking", "impact"]

    var body: some View {
        Form {
            Section {
                Button {
                    Haptics.heavyImpact()
                    Task { await coordinator.developerSimulateCrash() }
                } label: {
                    Label("Simulate Crash", systemImage: "car.side.rear.and.collision.and.car.side.front")
                        .font(.title3.weight(.bold))
                }
                .buttonStyle(BigButtonStyle(color: .red))
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Incident simulation")
            } footer: {
                Text("Runs the real incident pipeline with source \"Developer simulation\": protects the buffered footage, keeps recording the post-roll, then exports a clip.")
            }

            Section {
                Button("Simulate camera interruption (3 s)") { coordinator.developerSimulateInterruption() }
                Button("Simulate media services reset") { coordinator.developerSimulateMediaServicesReset() }
                Button("Simulate writer failure") { coordinator.developerSimulateWriterFailure() }
                Picker("Storage floor override", selection: $storageFloorMB) {
                    ForEach(floorOptions, id: \.megabytes) { option in
                        Text(option.label).tag(option.megabytes)
                    }
                }
                .onChange(of: storageFloorMB) { _, newValue in
                    Task { await coordinator.developerSetStorageFloor(megabytes: newValue == 0 ? nil : newValue) }
                }
            } header: {
                Text("Fault injection")
            } footer: {
                Text("A high storage floor makes retention trim the buffer immediately and, above the free space, stops recording as if the phone were full.")
            }

            Section {
                ForEach(traces, id: \.self) { name in
                    Button("Replay \(name) trace") { replay(name) }
                }
                LabeledContent("Sensitivity", value: DisplayText.sensitivity(settings.motionSensitivity))
                if let replayResult {
                    Text(replayResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(replayEvents.enumerated()), id: \.offset) { _, event in
                    Text(String(format: "%@ at %.2f s, peak %.2f", DisplayText.motionKind(event.kind), event.timestamp, event.peakMagnitude))
                        .font(.footnote.monospacedDigit())
                }
            } header: {
                Text("Motion trace replay")
            } footer: {
                Text("Runs a recorded accelerometer trace through the impact detector at the current sensitivity without touching the sensors.")
            }

            Section("Live stats") {
                LabeledContent("State", value: DisplayText.recorderState(coordinator.state))
                LabeledContent("Recording", value: DisplayText.yesNo(coordinator.isRecording))
                if let started = coordinator.sessionStartedAt {
                    LabeledContent("Session started") { Text(started, style: .relative) }
                }
                if let started = coordinator.runStartedAt {
                    LabeledContent("Run started") { Text(started, style: .relative) }
                }
                LabeledContent("Video frames", value: "\(coordinator.videoFrames)")
                LabeledContent("Dropped frames", value: "\(coordinator.droppedFrames)")
                LabeledContent("Buffered", value: formatDuration(coordinator.bufferedSeconds))
                LabeledContent("Segments", value: "\(coordinator.bufferSegmentCount)")
                if let last = coordinator.lastSegmentAt {
                    LabeledContent("Last segment") { Text(last, style: .relative) }
                }
                LabeledContent("Frame rate", value: "\(coordinator.currentFrameRate) fps")
                LabeledContent("Camera pressure", value: coordinator.pressureLevel.rawValue)
                LabeledContent("Thermal state", value: DisplayText.thermal(coordinator.thermalState))
                LabeledContent("Recovery attempts", value: "\(coordinator.recoveryAttempts)")
                LabeledContent("Battery", value: batteryText)
                if let config = coordinator.configuration {
                    LabeledContent("Camera", value: config.deviceName)
                    LabeledContent("Format", value: "\(config.width)x\(config.height) @ \(config.frameRate) \(config.codec)")
                    LabeledContent("Stabilization", value: config.stabilization)
                    LabeledContent("Audio", value: DisplayText.yesNo(config.audioEnabled))
                    LabeledContent("Using preset", value: DisplayText.yesNo(config.usingPreset))
                }
                LabeledContent("Segment length", value: "\(Int(settings.segmentInterval)) s")
                Stepper("Segment length: \(settings.segmentSeconds) s", value: $settings.segmentSeconds, in: 2...30)
            }

            Section("Logs") {
                NavigationLink("View recent log") {
                    LogViewerView()
                }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var batteryText: String {
        let level = coordinator.batteryLevel >= 0 ? " \(Int(coordinator.batteryLevel * 100))%" : ""
        switch coordinator.batteryState {
        case .charging: return "Charging" + level
        case .full: return "Full" + level
        case .unplugged: return "Unplugged" + level
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private func replay(_ name: String) {
        let url = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "Traces")
            ?? Bundle.main.url(forResource: name, withExtension: "csv")
        guard let url, let csv = try? String(contentsOf: url, encoding: .utf8) else {
            replayResult = "Trace \(name).csv is not bundled."
            replayEvents = []
            return
        }
        do {
            let events = try coordinator.developerReplayMotionTrace(csv: csv)
            replayEvents = events
            replayResult = events.isEmpty ? "\(name): no events" : "\(name): \(events.count) event(s)"
        } catch {
            replayEvents = []
            replayResult = "\(name): \(error.localizedDescription)"
        }
    }
}

/// Recent in-memory log entries with level filtering, search and export of the on-disk log file.
struct LogViewerView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @State private var minimumLevel: LogLevel = .info
    @State private var query = ""
    @State private var entries: [LogEntry] = []
    @State private var logFileURL: URL? = nil

    var body: some View {
        List {
            Section {
                Picker("Minimum level", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.menu)
                if let logFileURL {
                    ShareLink(item: logFileURL) {
                        Label("Export log file", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("\(filtered.count) entries") {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.level.label) \(entry.category.rawValue)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color(for: entry.level))
                        Text(entry.message)
                            .font(.caption.monospaced())
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Refresh") { refresh() }
        }
        .onAppear { refresh() }
    }

    private var filtered: [LogEntry] {
        entries.filter { entry in
            entry.level >= minimumLevel && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query) || entry.category.rawValue.localizedCaseInsensitiveContains(query))
        }
    }

    private func refresh() {
        entries = coordinator.recentLogEntries.reversed()
        logFileURL = coordinator.exportLogFile()
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info, .notice: return .blue
        case .warning: return .orange
        case .error, .fault: return .red
        }
    }
}
