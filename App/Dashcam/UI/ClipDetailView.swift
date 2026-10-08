import AVFoundation
import AVKit
import Combine
import SwiftUI
import DashcamCore

/// Playback, sharing and details for one saved incident.
struct ClipDetailView: View {
    let incidentID: UUID
    @EnvironmentObject var coordinator: RecordingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var players: [URL: AVPlayer] = [:]
    @State private var playbackObservers: [AnyCancellable] = []
    @State private var photosMessage: String? = nil
    @State private var photosAccessDenied = false
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
            // Give other apps' audio (music, navigation) back; AVPlayer activated the session on play.
            if !coordinator.state.isActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func content(for incident: Incident) -> some View {
        let urls = coordinator.clipURLs(for: incident)
        return list(for: incident, urls: urls)
            .task(id: urls) { preparePlayers(for: urls) }
    }

    private func list(for incident: Incident, urls: [URL]) -> some View {
        List {
            switch incident.state {
            case .complete:
                Section {
                    ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                        VStack(alignment: .leading, spacing: 6) {
                            if urls.count > 1 {
                                Text("Part \(index + 1) of \(urls.count)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            if let player = players[url] {
                                VideoPlayer(player: player)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onDisappear { player.pause() }
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
                Section {
                    ShareLink(items: urls) {
                        Label("Share clip", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("clip.share")
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
                    if photosAccessDenied {
                        Button {
                            SystemSettings.open()
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
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

            Section {
                DisclosureGroup("Event details") {
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
            }

            Section {
                DisclosureGroup("File details") {
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
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete clip", systemImage: "trash")
                }
                // Same rule as the Clips list and the coordinator: only finished incidents can go.
                .disabled(!RecordingCoordinator.canDelete(incident))
                .accessibilityIdentifier("clip.delete")
            } footer: {
                if !RecordingCoordinator.canDelete(incident) {
                    Text("The clip can be deleted once it has finished saving.")
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

    /// Players are created outside `body` and reused across re-appearances (a tab switch fires
    /// onDisappear/onAppear and would otherwise rebuild them at time zero); they are rebuilt only when
    /// the set of clip URLs changes. When one part starts playing the others pause.
    private func preparePlayers(for urls: [URL]) {
        if !urls.isEmpty, !coordinator.state.isActive {
            // Clip review should be audible with the Ring/Silent switch on and come out of the speaker.
            // The category alone is set here; AVPlayer activates the session when the user presses play,
            // so merely opening a clip does not interrupt music or navigation. Never touched while a
            // session is active: the capture session owns the audio session then.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
        if !players.isEmpty, Set(players.keys) == Set(urls), !playbackObservers.isEmpty { return }
        for player in players.values { player.pause() }
        playbackObservers.removeAll()
        guard !urls.isEmpty else { players = [:]; return }
        let created = Dictionary(uniqueKeysWithValues: urls.map { ($0, AVPlayer(url: $0)) })
        players = created
        for (url, player) in created {
            let observer = player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { status in
                    guard status == .playing else { return }
                    for (other, otherPlayer) in created where other != url {
                        otherPlayer.pause()
                    }
                }
            playbackObservers.append(observer)
        }
    }

    private func saveToPhotos(_ incident: Incident) {
        isSavingToPhotos = true
        photosMessage = nil
        photosAccessDenied = false
        Task {
            do {
                let saved = try await coordinator.saveToPhotos(incident)
                photosMessage = saved > 0 ? "Saved to Photos." : "Already saved to Photos."
            } catch let error as ClipExportError {
                if case .photosAccessDenied = error { photosAccessDenied = true }
                photosMessage = error.localizedDescription
            } catch {
                photosMessage = "Could not save to Photos: \(error.localizedDescription)"
            }
            isSavingToPhotos = false
        }
    }
}
