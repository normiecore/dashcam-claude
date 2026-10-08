import Foundation
import Combine
import DashcamCore

enum MotionSensitivity: String, CaseIterable, Codable, Identifiable {
    case low, medium, high
    var id: String { rawValue }

    var configuration: MotionDetectorConfiguration {
        switch self {
        case .low: return MotionDetectorConfiguration(impactThresholdG: 4.0, impactMinimumSamples: 4, hardBrakingThresholdG: .infinity, rotationThreshold: .infinity)
        case .medium: return MotionDetectorConfiguration(impactThresholdG: 3.0, impactMinimumSamples: 3, hardBrakingThresholdG: .infinity, rotationThreshold: 6.0)
        case .high: return MotionDetectorConfiguration(impactThresholdG: 2.2, impactMinimumSamples: 2, hardBrakingThresholdG: 0.7, hardBrakingMinimumDuration: 0.6, rotationThreshold: 5.0)
        }
    }
}

/// User-facing and developer settings, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var bufferMinutes: Int { didSet { defaults.set(bufferMinutes, forKey: Keys.bufferMinutes) } }
    @Published var recentHistoryMinutes: Int { didSet { defaults.set(recentHistoryMinutes, forKey: Keys.recentHistoryMinutes) } }
    @Published var recentHistoryGigabytes: Int { didSet { defaults.set(recentHistoryGigabytes, forKey: Keys.recentHistoryGigabytes) } }
    @Published var postRollSeconds: Int { didSet { defaults.set(postRollSeconds, forKey: Keys.postRollSeconds) } }
    @Published var audioEnabled: Bool { didSet { defaults.set(audioEnabled, forKey: Keys.audioEnabled) } }
    @Published var quality: VideoQualityTier { didSet { defaults.set(quality.rawValue, forKey: Keys.quality) } }
    @Published var stabilizationEnabled: Bool { didSet { defaults.set(stabilizationEnabled, forKey: Keys.stabilization) } }
    @Published var motionDetectionEnabled: Bool { didSet { defaults.set(motionDetectionEnabled, forKey: Keys.motionDetection) } }
    @Published var motionSensitivity: MotionSensitivity { didSet { defaults.set(motionSensitivity.rawValue, forKey: Keys.motionSensitivity) } }
    @Published var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake) } }
    @Published var autoDimAfterSeconds: Int { didSet { defaults.set(autoDimAfterSeconds, forKey: Keys.autoDim) } }
    @Published var autoStartRecording: Bool { didSet { defaults.set(autoStartRecording, forKey: Keys.autoStart) } }
    /// Developer: segment length in seconds. Shorter segments bound crash loss more tightly at the cost of more files.
    @Published var segmentSeconds: Int { didSet { defaults.set(segmentSeconds, forKey: Keys.segmentSeconds) } }
    @Published var minimumFreeMegabytes: Int { didSet { defaults.set(minimumFreeMegabytes, forKey: Keys.minimumFreeMB) } }
    @Published var developerMenuEnabled: Bool { didSet { defaults.set(developerMenuEnabled, forKey: Keys.developerMenu) } }
    /// First-run consent/onboarding (App Review guideline 2.5.14: explicit consent for recording).
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bufferMinutes = defaults.object(forKey: Keys.bufferMinutes) as? Int ?? 5
        let legacyHours = defaults.object(forKey: Keys.recentHistoryHours) as? Int
        recentHistoryMinutes = defaults.object(forKey: Keys.recentHistoryMinutes) as? Int ?? legacyHours.map { $0 * 60 } ?? 360
        recentHistoryGigabytes = defaults.object(forKey: Keys.recentHistoryGigabytes) as? Int ?? 4
        postRollSeconds = defaults.object(forKey: Keys.postRollSeconds) as? Int ?? 60
        audioEnabled = defaults.object(forKey: Keys.audioEnabled) as? Bool ?? true
        quality = VideoQualityTier(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .hd1080p30
        stabilizationEnabled = defaults.object(forKey: Keys.stabilization) as? Bool ?? true
        motionDetectionEnabled = defaults.object(forKey: Keys.motionDetection) as? Bool ?? false
        motionSensitivity = MotionSensitivity(rawValue: defaults.string(forKey: Keys.motionSensitivity) ?? "") ?? .low
        keepScreenAwake = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? true
        autoDimAfterSeconds = defaults.object(forKey: Keys.autoDim) as? Int ?? 0
        autoStartRecording = defaults.object(forKey: Keys.autoStart) as? Bool ?? false
        segmentSeconds = defaults.object(forKey: Keys.segmentSeconds) as? Int ?? 4
        minimumFreeMegabytes = defaults.object(forKey: Keys.minimumFreeMB) as? Int ?? 1_024
        #if DEBUG
        developerMenuEnabled = defaults.object(forKey: Keys.developerMenu) as? Bool ?? true
        #else
        developerMenuEnabled = defaults.object(forKey: Keys.developerMenu) as? Bool ?? false
        #endif
        hasCompletedOnboarding = defaults.object(forKey: Keys.onboarding) as? Bool ?? false
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            targetDuration: TimeInterval(max(1, recentHistoryMinutes) * 60),
            maxBufferBytes: Int64(max(1, recentHistoryGigabytes)) * 1_073_741_824,
            minimumFreeBytes: Int64(max(256, minimumFreeMegabytes)) * 1_048_576
        )
    }

    var incidentPolicy: IncidentPolicy {
        IncidentPolicy(preRoll: TimeInterval(max(1, bufferMinutes) * 60), postRoll: TimeInterval(max(5, postRollSeconds)))
    }

    var segmentInterval: TimeInterval { TimeInterval(min(max(segmentSeconds, 2), 30)) }

    /// Conservative estimate shown before a drive. The rolling buffer stops growing at whichever
    /// limit is reached first: the chosen time window, storage budget or free-space floor.
    var estimatedRecentHistorySeconds: TimeInterval {
        let bytesPerHour = max(quality.estimatedBytesPerHour(audioEnabled: audioEnabled), 1)
        let budgetBytes = Int64(max(1, recentHistoryGigabytes)) * 1_073_741_824
        let hoursFromBudget = Double(budgetBytes) / Double(bytesPerHour)
        let selectedHours = Double(max(1, recentHistoryMinutes)) / 60
        return min(selectedHours, hoursFromBudget) * 3_600
    }

    private enum Keys {
        static let bufferMinutes = "settings.bufferMinutes"
        static let recentHistoryMinutes = "settings.recentHistoryMinutes"
        static let recentHistoryHours = "settings.recentHistoryHours"
        static let recentHistoryGigabytes = "settings.recentHistoryGigabytes"
        static let postRollSeconds = "settings.postRollSeconds"
        static let audioEnabled = "settings.audioEnabled"
        static let quality = "settings.quality"
        static let stabilization = "settings.stabilization"
        static let motionDetection = "settings.motionDetection"
        static let motionSensitivity = "settings.motionSensitivity"
        static let keepScreenAwake = "settings.keepScreenAwake"
        static let autoDim = "settings.autoDimAfterSeconds"
        static let autoStart = "settings.autoStartRecording"
        static let segmentSeconds = "settings.segmentSeconds"
        static let minimumFreeMB = "settings.minimumFreeMegabytes"
        static let developerMenu = "settings.developerMenuEnabled"
        static let onboarding = "settings.hasCompletedOnboarding"
    }
}
