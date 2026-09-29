import SwiftUI
import DashcamCore

/// Saved incidents, newest first.
struct ClipsLibraryView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings
    @State private var pendingDelete: Incident? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(coordinator.incidents) { incident in
                    NavigationLink(value: incident.id) {
                        IncidentRow(incident: incident)
                    }
                    // Not role: .destructive, which would animate the row away before the user confirms.
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
                }
            }
            .overlay {
                if coordinator.incidents.isEmpty {
                    emptyState
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Clips")
            .navigationDestination(for: UUID.self) { id in
                ClipDetailView(incidentID: id)
            }
            .refreshable {
                await coordinator.refreshIncidents()
            }
            .task {
                await coordinator.refreshIncidents()
            }
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No saved clips", systemImage: "film.stack")
        } description: {
            Text("While recording, press Save Incident, or let a detected impact do it, and Dashcam keeps the last \(settings.bufferMinutes) min of footage plus the next \(settings.postRollSeconds) s here. Everything else is overwritten automatically.")
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented { pendingDelete = nil }
            }
        )
    }
}

/// One incident in the library list.
struct IncidentRow: View {
    let incident: Incident

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DisplayText.sourceSymbol(incident.primarySource))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(incident.triggerTime, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                    .font(.headline)
                Text(incident.primarySource.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(formatDuration(incident.footageDuration), systemImage: "clock")
                    Label(formatBytes(incident.totalBytes), systemImage: "doc")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StateBadge(state: incident.state)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
