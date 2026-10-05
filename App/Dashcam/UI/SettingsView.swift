import AVFoundation
import SwiftUI
import DashcamCore

struct SettingsView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings

    private let postRollOptions = [30, 60, 120, 180]

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
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
            Picker("Quality", selection: $settings.quality) {
                ForEach(VideoQualityTier.allCases) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            Toggle("Record audio", isOn: $settings.audioEnabled)
            Toggle("Video stabilization", isOn: $settings.stabilizationEnabled)
            Stepper("Rolling buffer: \(settings.bufferMinutes) min", value: $settings.bufferMinutes, in: 1...10)
            Picker("Keep recording after an incident", selection: $settings.postRollSeconds) {
                ForEach(postRollOptions, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
            Toggle("Start recording when the app opens", isOn: $settings.autoStartRecording)
        } header: {
            Text("Recording")
        } footer: {
            Text("Changes to quality and audio apply the next time recording starts. Recording conversations may require the consent of everyone in the car in some places.")
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
            Toggle("Impact detection (experimental)", isOn: $settings.motionDetectionEnabled)
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
            Text("Impact detection uses the motion sensors to save footage after a strong jolt. It supplements the Save Incident button and may trigger on potholes or a dropped phone. Apple Crash Detection requires an entitlement Apple grants per app, only one app on the phone can receive its events, and events arrive after Emergency SOS finishes, protecting footage already on disk.")
        }
    }

    private var storageSection: some View {
        Section {
            if let storage = coordinator.storage {
                LabeledContent("Free space", value: formatFreeSpace(storage.availableBytes))
                LabeledContent("Rolling buffer", value: formatBytes(storage.bufferBytes))
                LabeledContent("Saved clips", value: formatBytes(storage.incidentBytes))
            }
            Stepper("Stop recording below \(settings.minimumFreeMegabytes) MB free", value: $settings.minimumFreeMegabytes, in: 512...8192, step: 256)
        } header: {
            Text("Storage")
        } footer: {
            Text("The rolling buffer deletes its oldest footage automatically. Saved clips are kept until you delete them.")
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
