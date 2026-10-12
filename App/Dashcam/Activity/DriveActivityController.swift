import ActivityKit
import Foundation

/// Updates are serialized so a delayed REC update cannot overwrite a later pause or stop.
/// Live Activity dismissal/expiry never controls capture. The camera remains foreground-only.
@MainActor
final class DriveActivityController {
    private var updateTask: Task<Void, Never>?
    private let enabled: Bool
    private var lastState: DriveActivityAttributes.ContentState?

    init(enabled: Bool) { self.enabled = enabled }

    func update(_ state: DriveActivityAttributes.ContentState, startedAt: Date) {
        guard enabled else { return }
        // Repeated idle refreshes must not keep extending the final card's dismissal time.
        let terminal = state.phase == .stopped || state.phase == .failed
        if terminal, lastState?.phase == state.phase { return }
        lastState = state
        let previous = updateTask
        updateTask = Task { @MainActor in
            await previous?.value
            let existing = Activity<DriveActivityAttributes>.activities
            let needsFreshness = state.phase == .recording || state.phase == .starting
            let content = ActivityContent(state: state, staleDate: needsFreshness ? Date().addingTimeInterval(20) : nil)
            let terminal = state.phase == .stopped || state.phase == .failed
            if terminal {
                for activity in existing {
                    await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
                }
                return
            }
            if existing.isEmpty {
                // A paused app cannot start an activity in the background; resume retries in foreground.
                guard state.phase == .recording || state.phase == .starting,
                      ActivityAuthorizationInfo().areActivitiesEnabled else { return }
                _ = try? Activity.request(attributes: DriveActivityAttributes(startedAt: startedAt), content: content, pushType: nil)
            } else {
                for activity in existing { await activity.update(content) }
            }
        }
    }

    func flush() async { await updateTask?.value }
}
