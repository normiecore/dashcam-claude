import AVFoundation
import SwiftUI
import UIKit
import DashcamCore

/// Saved clips, grouped by day and presented as a quiet local archive.
struct ClipsLibraryView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    var onRecord: () -> Void
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
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                        }
                    } header: {
                        Text(group.day, format: .dateTime.day().month(.wide).year())
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay {
                if coordinator.incidents.isEmpty {
                    emptyState
                }
            }
            .navigationTitle("Saved clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
            Text("While recording, tap Save clip to keep a moment. Your saved clips will appear here.")
        } actions: {
            Button("Go to camera", action: onRecord)
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("clips.goToCamera")
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let incident: Incident

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
    }

    var body: some View {
        layout {
            ClipThumbnailView(incident: incident)
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(incident.triggerTime, format: .dateTime.hour().minute())
                    .font(.headline.monospacedDigit())
                Text("\(incident.primarySource.displayName) · \(formatDuration(incident.footageDuration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens playback and sharing options")
        .accessibilityIdentifier("clips.row")
    }

    @ViewBuilder private var status: some View {
        if incident.state == .complete {
            Label("Saved", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            StateBadge(state: incident.state)
        }
    }
}

private struct ClipThumbnailView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    let incident: Incident
    @State private var image: UIImage?

    var body: some View {
        // The image fills an explicitly bounded viewport. Its intrinsic portrait size
        // must never negotiate the row's height or cover neighbouring navigation.
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "video")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: thumbnailIdentity) { await loadThumbnail() }
    }

    private var thumbnailIdentity: String {
        "\(incident.id)-\(coordinator.clipURLs(for: incident).first?.absoluteString ?? "pending")"
    }

    @MainActor
    private func loadThumbnail() async {
        guard image == nil, let url = coordinator.clipURLs(for: incident).first else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 288, height: 192)
        do {
            let result = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
            image = UIImage(cgImage: result.image)
        } catch {
            // A collecting or recovering clip may not be readable yet; the placeholder is truthful.
        }
    }
}
