import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DriveActivityBundle: WidgetBundle {
    var body: some Widget { DriveActivityWidget() }
}

struct DriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            DriveStatusView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "dashcam://open"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusSymbol(context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(duration(context.state.recordedSeconds)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DriveStatusView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                statusSymbol(context)
            } compactTrailing: {
                Text(context.isStale || context.state.phase != .recording ? "II" : "REC")
                    .font(.caption2.bold())
                    .foregroundStyle(context.isStale || context.state.phase != .recording ? .orange : .red)
            } minimal: {
                statusSymbol(context)
            }
            .widgetURL(URL(string: "dashcam://open"))
            .keylineTint(context.isStale || context.state.phase != .recording ? .orange : .red)
        }
        .supplementalActivityFamilies([.small])
    }

    private func statusSymbol(_ context: ActivityViewContext<DriveActivityAttributes>) -> some View {
        Image(systemName: context.isStale ? "questionmark.circle" : context.state.phase == .recording ? "record.circle.fill" : "pause.circle.fill")
            .foregroundStyle(context.isStale || context.state.phase != .recording ? Color.orange : Color.red)
            .accessibilityLabel(context.isStale ? "Recording status unavailable" : context.state.phase == .recording ? "Recording" : "Not recording")
    }
}

private struct DriveStatusView: View {
    let state: DriveActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isStale ? "questionmark.circle" : state.phase == .recording ? "record.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(isStale || state.phase != .recording ? Color.orange : Color.red)
                Text(title).font(.headline)
                Spacer(minLength: 4)
                if family != .small { Text(duration(state.recordedSeconds)).monospacedDigit() }
            }
            Text(isStale ? "Open Dashcam to check" : state.detail)
                .font(.caption)
                .lineLimit(family == .small ? 2 : 3)
        }
        .foregroundStyle(.white)
        .padding(family == .small ? 8 : 14)
    }

    private var title: String {
        if isStale { return "Check Dashcam" }
        switch state.phase {
        case .recording: return "Recording"
        case .paused: return "Recording paused"
        case .starting: return "Starting camera"
        case .stopped: return "Drive stopped"
        case .failed: return "Recording stopped"
        }
    }
}

private func duration(_ seconds: Int) -> String {
    let value = max(0, seconds)
    return String(format: "%d:%02d", value / 60, value % 60)
}
