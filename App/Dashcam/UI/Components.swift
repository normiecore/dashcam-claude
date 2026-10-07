import AVFoundation
import SwiftUI
import UIKit
import DashcamCore

// MARK: - Formatting

/// "4:58" for durations under an hour, "1:02:03" otherwise. Negative or non-finite values read as 0:00.
func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

/// File-style byte count ("34.2 MB").
func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Free-space style: GB when there is at least 1 GB, MB below that.
func formatFreeSpace(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatApproximateDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(1, Int((seconds / 60).rounded()))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "About \(minutes) min" }
    if minutes == 0 { return "About \(hours) h" }
    return "About \(hours) h \(minutes) min"
}

/// Human-readable labels for model and system values. Kept as free functions (rather than extensions on
/// DashcamCore or Apple types) so they can never collide with members added to those types later.
enum DisplayText {
    static func recorderState(_ state: RecorderState) -> String {
        switch state {
        case .idle: return "Stopped"
        case .starting: return "Starting"
        case .recording: return "Recording"
        case .interrupted(_, let reason): return "Paused: \(reason)"
        case .stopping: return "Stopping"
        case .failed: return "Error"
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    static func authorization(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked"
        @unknown default: return "Unknown"
        }
    }

    static func sensitivity(_ sensitivity: MotionSensitivity) -> String {
        switch sensitivity {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    static func motionKind(_ kind: MotionEvent.Kind) -> String {
        switch kind {
        case .impact: return "Impact"
        case .hardBraking: return "Hard braking"
        case .abnormalRotation: return "Abnormal rotation"
        }
    }

    static func sourceSymbol(_ source: IncidentSource) -> String {
        switch source {
        case .manual: return "hand.tap.fill"
        case .appleCrashDetection: return "car.fill"
        case .motionHeuristic: return "waveform.path.ecg"
        case .developerSimulation: return "hammer.fill"
        }
    }

    static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
}

// MARK: - HUD chip

/// Small capsule used in the recording HUD (storage, heat, audio, battery).
struct HUDChip: View {
    let systemImage: String
    var text: String?
    var tint: Color = .white
    var accessibilityText: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            if let text {
                Text(text)
                    .lineLimit(1)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? text ?? "")
    }
}

// MARK: - Incident state badge

struct StateBadge: View {
    let state: IncidentState

    var body: some View {
        switch state {
        case .collecting:
            badge {
                Image(systemName: "lock.fill")
                Text("Securing")
            }
            .foregroundStyle(.orange)
            .accessibilityLabel("Securing footage")
        case .readyToAssemble, .assembling:
            badge {
                ProgressView()
                    .controlSize(.mini)
                Text("Exporting")
            }
            .foregroundStyle(.blue)
            .accessibilityLabel("Exporting clip")
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Saved")
        case .failed:
            badge {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Failed")
            }
            .foregroundStyle(.red)
            .accessibilityLabel("Export failed")
        }
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .ignore)
    }
}

// MARK: - Recording dot

/// Red recording indicator. Pulses unless Reduce Motion is on.
struct PulsingDot: View {
    var color: Color = .red
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dot
        } else {
            dot.phaseAnimator([1.0, 0.3]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Banner

/// Full-width message banner; tapping it dismisses it.
struct BannerView: View {
    let text: String
    let systemImage: String
    let tint: Color
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let onDismiss {
                Button(action: onDismiss) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Double-tap to dismiss")
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if onDismiss != nil {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .opacity(0.7)
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.55)))
    }
}

// MARK: - Big button style

/// Large, high-contrast button for use at a glance in a car. Minimum height defaults to 60 pt.
struct BigButtonStyle: ButtonStyle {
    var color: Color
    var foreground: Color = .white
    var minHeight: CGFloat = 60

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BigButtonBody(configuration: configuration, color: color, foreground: foreground, minHeight: minHeight)
    }

    private struct BigButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        let foreground: Color
        let minHeight: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? foreground : foreground.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isEnabled ? color : Color(white: 0.22))
                )
                .opacity(configuration.isPressed ? 0.75 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - System helpers

@MainActor
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func heavyImpact() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}

@MainActor
enum SystemSettings {
    /// Opens this app's page in the Settings app.
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
