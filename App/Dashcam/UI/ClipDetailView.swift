import AVKit
import SwiftUI
import DashcamCore

/// Playback, sharing and details for one saved incident.
struct ClipDetailView: View {
    let incidentID: UUID
    @EnvironmentObject var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var players: [URL: AVPlayer] = [:]
    @State private var photosMessage: String? = nil
    @State private var isSavingToPhotos = false
    @State private var isConfirmingDelete = false

    private var incident: Incident? {
        coordinator.incidents.first { $0.id == incidentID }
    }

    var body: some View {
        Group {
            if let incident {
                content(for: incident)
            } else {
                ContentUnavailableView("Clip not found", systemImage: "film", description: Text("This clip was deleted or has not finished saving."))
            }
        }
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            for player in players.values { player.pause() }
        }
    }

    private func content(for incident: Incident) -> some View {
        let urls = coordinator.clipURLs(for: incident)
        return List {
            switch incident.state {
            case .complete:
                Section {
                    ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                        VStack(alignment: .leading, spacing: 6) {
                            if urls.count > 1 {
                                Text("Part \(index + 1) of \(urls.count)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            VideoPlayer(player: player(for: url))
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
                Section {
                    ShareLink(items: urls) {
                        Label("Share clip", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        saveToPhotos(incident)
                    } label: {
                        HStack {
                            Label("Save to Photos", systemImage: "photo.on.rectangle")
                            if isSavingToPhotos {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSavingToPhotos)
                    if let photosMessage {
                        Text(photosMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The clip stays in Dashcam after sharing or saving.")
                }
            case .failed:
                Section {
                    Label(incident.failureReason ?? "The clip could not be exported.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button {
                        Task { await coordinator.retryAssembly(incident.id) }
                    } label: {
                        Label("Retry export", systemImage: "arrow.clockwise")
                    }
                }
            case .collecting:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Securing footage. The clip becomes available once the post-roll has been recorded.")
                    }
                }
            case .readyToAssemble, .assembling:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Exporting the clip. This usually takes a few seconds.")
                    }
                }
            }

            Section("Triggers") {
                ForEach(Array(incident.triggers.enumerated()), id: \.offset) { _, trigger in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(trigger.source.displayName, systemImage: DisplayText.sourceSymbol(trigger.source))
                        Text(trigger.time.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let note = trigger.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Details") {
                detailRow("Requested window", "\(incident.windowStart.formatted(date: .omitted, time: .standard)) to \(incident.windowEnd.formatted(date: .omitted, time: .standard))")
                if let start = incident.coveredStart, let end = incident.coveredEnd {
                    detailRow("Footage covered", "\(start.formatted(date: .omitted, time: .standard)) to \(end.formatted(date: .omitted, time: .standard))")
                }
                detailRow("Duration", formatDuration(incident.footageDuration))
                detailRow("Size", formatBytes(incident.totalBytes))
                detailRow("Segments", "\(incident.mediaParts.count)")
                detailRow("Created", incident.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Identifier", incident.id.uuidString)
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete clip", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this clip?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Clip", role: .destructive) {
                Task {
                    await coordinator.deleteIncident(incident.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The footage will be permanently deleted from this iPhone.")
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func player(for url: URL) -> AVPlayer {
        if let existing = players[url] { return existing }
        let player = AVPlayer(url: url)
        DispatchQueue.main.async { players[url] = player }
        return player
    }

    private func saveToPhotos(_ incident: Incident) {
        isSavingToPhotos = true
        photosMessage = nil
        Task {
            let ok = await coordinator.saveToPhotos(incident)
            photosMessage = ok ? "Saved to Photos." : (coordinator.lastError ?? "Could not save to Photos.")
            isSavingToPhotos = false
        }
    }
}
