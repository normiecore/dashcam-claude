import AVFoundation
import SwiftUI
import UIKit
import DashcamCore

/// Saved clips, grouped by day and presented as a quiet local archive.
struct ClipsLibraryView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings
    @State private var pendingDelete: Incident? = nil

    private struct DayGroup: Identifiable {
        let day: Date
        let incidents: [Incident]
        var id: Date { day }
    }

    private var groupedIncidents: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: coordinator.incidents) {
            calendar.startOfDay(for: $0.triggerTime)
        }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(day: day, incidents: groups[day, default: []].sorted { $0.triggerTime > $1.triggerTime })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedIncidents) { group in
                    Section {
                        ForEach(group.incidents) { incident in
                            row(for: incident)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(group.day, format: .dateTime.day().month(.wide).year())
                            .font(.caption.weight(.medium))
                            .tracking(1.2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.97, green: 0.965, blue: 0.94))
            .overlay {
                if coordinator.incidents.isEmpty {
                    emptyState
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Saved clips")
            .navigationDestination(for: UUID.self) { id in
                ClipDetailView(incidentID: id)
            }
            .refreshable { await coordinator.refreshIncidents() }
            .task { await coordinator.refreshIncidents() }
            .confirmationDialog(
                "Delete this clip?",
                isPresented: isConfirmingDelete,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { incident in
                Button("Delete Clip", role: .destructive) {
                    Task { await coordinator.deleteIncident(incident.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { incident in
                Text("The footage from \(incident.triggerTime.formatted(date: .abbreviated, time: .shortened)) will be permanently deleted from this iPhone.")
            }
        }
    }

    private func canDelete(_ incident: Incident) -> Bool {
        RecordingCoordinator.canDelete(incident)
    }

    @ViewBuilder private func row(for incident: Incident) -> some View {
        let link = NavigationLink(value: incident.id) {
            IncidentArchiveRow(incident: incident)
        }
        .buttonStyle(.plain)

        if canDelete(incident) {
            link
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        pendingDelete = incident
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDelete = incident
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        } else {
            link
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No saved clips", systemImage: "film.stack")
        } description: {
            Text("Tap Save clip while recording, or enable possible event detection. Recent footage rolls over automatically; saved clips stay here until you delete them.")
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } }
        )
    }
}

struct IncidentArchiveRow: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    let incident: Incident

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipThumbnailView(incident: incident)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(Rectangle())
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(incident.triggerTime, format: .dateTime.hour().minute().second())
                    .font(.headline.monospacedDigit())
                Text(incident.primarySource.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(formatDuration(incident.footageDuration))
                    .font(.subheadline.monospacedDigit())
                StateBadge(state: incident.state)
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clips.row")
    }
}

private struct ClipThumbnailView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    let incident: Incident
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: incident.id) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        guard image == nil, let url = coordinator.clipURLs(for: incident).first else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        do {
            let result = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
            image = UIImage(cgImage: result.image)
        } catch {
            // A collecting or recovering clip may not be readable yet; the placeholder is truthful.
        }
    }
}
