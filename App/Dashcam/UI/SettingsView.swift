import AVFoundation
import SwiftUI
import DashcamCore

struct SettingsView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings

    private let postRollOptions = [30, 60, 120, 180]
    private let historyHourOptions = [1, 3, 6, 12]
    private let historyStorageOptions = [1, 2, 4, 8, 16]

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                automationSection
                screenSection
                detectionSection
                storageSection
                permissionsSection
                developerSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task { await coordinator.refreshStats() }
        }
    }

    private var recordingSection: some View {
        Section {
            Picker("Video quality", selection: $settings.quality) {
                ForEach(VideoQualityTier.allCases) { tier in
                    VStack(alignment: .leading) {
                        Text(tier.displayName)
                        Text(tier.technicalDescription)
                    }
                    .tag(tier)
                }
            }
            LabeledContent("Selected") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(settings.quality.technicalDescription)
                    Text("About \(formatBytes(settings.quality.estimatedBytesPerHour(audioEnabled: settings.audioEnabled))) per hour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Record audio", isOn: $settings.audioEnabled)
            Toggle("Video stabilization", isOn: $settings.stabilizationEnabled)
            Stepper("Save previous \(settings.bufferMinutes) min", value: $settings.bufferMinutes, in: 1...10)
            Picker("Continue after Save clip", selection: $settings.postRollSeconds) {
                ForEach(postRollOptions, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Standard is the recommended balance. Quality changes apply the next time recording starts. Save clip protects the selected time before the tap and continues recording afterwards. Audio recording may require consent in some places.")
        }
    }

    private var automationSection: some View {
        Section {
            Toggle("Start recording when the app opens", isOn: $settings.autoStartRecording)
            NavigationLink("Set up car automation") {
                CarAutomationHelpView()
            }
        } header: {
            Text("Car automation")
        } footer: {
            Text("CarPlay or your car's Bluetooth can open Dashcam through a Personal Automation. Keep the iPhone unlocked and Dashcam in the foreground while it records.")
        }
    }

    private var screenSection: some View {
        Section {
            Toggle("Keep screen awake while recording", isOn: $settings.keepScreenAwake)
        } header: {
            Text("Screen")
        } footer: {
            Text("iOS stops the camera when the phone locks or the app leaves the foreground, so Dashcam must stay open while you drive. Use Dim screen on the Record tab to darken the display without stopping.")
        }
    }

    private var detectionSection: some View {
        Section {
            Toggle("Possible event detection (experimental)", isOn: $settings.motionDetectionEnabled)
            if settings.motionDetectionEnabled {
                Picker("Sensitivity", selection: $settings.motionSensitivity) {
                    ForEach(MotionSensitivity.allCases) { level in
                        Text(DisplayText.sensitivity(level)).tag(level)
                    }
                }
                // The detector is not observable; refresh the row once a second while it is shown.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Status", value: coordinator.motionDetector.statusDescription)
                }
            }
            LabeledContent("Apple Crash Detection", value: coordinator.safetyKit.statusDescription)
        } header: {
            Text("Automatic detection")
        } footer: {
            Text("Motion sensors can save a clip after a strong jolt. This may also trigger on potholes or a dropped phone, so review automatic clips after the drive. Apple Crash Detection requires a separate entitlement and is currently unavailable.")
        }
    }

    private var storageSection: some View {
        Section {
            if let storage = coordinator.storage {
                LabeledContent("Free space", value: formatFreeSpace(storage.availableBytes))
                LabeledContent("Recent footage", value: formatBytes(storage.bufferBytes))
                LabeledContent("Saved clips", value: formatBytes(storage.incidentBytes))
            }
            Picker("Recent footage limit", selection: $settings.recentHistoryGigabytes) {
                ForEach(historyStorageOptions, id: \.self) { gigabytes in
                    Text("\(gigabytes) GB").tag(gigabytes)
                }
            }
            Picker("Maximum history", selection: $settings.recentHistoryHours) {
                ForEach(historyHourOptions, id: \.self) { hours in
                    Text("\(hours) h").tag(hours)
                }
            }
            LabeledContent("Estimated history", value: formatApproximateDuration(settings.estimatedRecentHistorySeconds))
            Stepper("Stop recording below \(settings.minimumFreeMegabytes) MB free", value: $settings.minimumFreeMegabytes, in: 512...8192, step: 256)
        } header: {
            Text("Storage")
        } footer: {
            Text("Dashcam keeps recent footage until it reaches the time limit, storage limit or free-space reserve. It deletes the oldest recent footage first. Saved and recovered clips are kept until you delete them.")
        }
    }

    private var permissionsSection: some View {
        Section {
            LabeledContent("Camera", value: DisplayText.authorization(coordinator.permissions.camera))
            LabeledContent("Microphone", value: DisplayText.authorization(coordinator.permissions.microphone))
            Button("Open Settings") { SystemSettings.open() }
        } header: {
            Text("Permissions")
        }
    }

    private var developerSection: some View {
        Section {
            Toggle("Developer menu", isOn: $settings.developerMenuEnabled)
            if settings.developerMenuEnabled {
                NavigationLink("Developer tools") {
                    DeveloperView()
                }
                .accessibilityIdentifier("settings.developerTools")
            }
        } header: {
            Text("Developer")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: versionText)
            Button("Show welcome screen again") {
                settings.hasCompletedOnboarding = false
            }
            .disabled(coordinator.state.isActive)
        } header: {
            Text("About")
        } footer: {
            Text(coordinator.state.isActive
                ? "Stop recording to show the welcome screen again. Footage never leaves this iPhone unless you share it or save it to Photos."
                : "Footage never leaves this iPhone unless you share it or save it to Photos.")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct CarAutomationHelpView: View {
    var body: some View {
        List {
            Section("Start a drive") {
                Text("In Shortcuts, create a Personal Automation for CarPlay Connects or for your selected car Bluetooth device. Add Open URLs with:")
                Text("dashcam://start")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Section("End a drive") {
                Text("Create a matching Disconnects automation and add Open URLs with:")
                Text("dashcam://stop")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text("Dashcam asks iOS to open, finishes current writes, then stops. Check that the app is stopped before removing the phone.")
                    .foregroundStyle(.secondary)
            }
            Section("Hands-free saving") {
                Text("A Shortcut can open the following URL while recording:")
                Text("dashcam://save")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Section {
                Text("iOS controls whether an automation opens an app automatically. Camera recording still requires Dashcam to remain open in the foreground.")
            }
        }
        .navigationTitle("Car automation")
        .navigationBarTitleDisplayMode(.inline)
    }
}
