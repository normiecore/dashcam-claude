import CoreMotion
import Foundation
import DashcamCore

/// A source of automatic incident triggers. Manual and developer triggers call the coordinator
/// directly; detectors exist for sources that observe something (sensors, system events).
@MainActor
protocol IncidentDetector: AnyObject {
    var source: IncidentSource { get }
    var statusDescription: String { get }
    func start()
    func stop()
}

struct DetectedIncident {
    let source: IncidentSource
    let occurredAt: Date?
    let note: String
}

/// Core Motion heuristic. Runs one CMMotionManager at 100 Hz while recording and feeds
/// `MotionImpactDetector` (pure logic, unit-tested in DashcamCore). Off by default until thresholds
/// are validated on real drives; it is a supplement to the manual button, not a crash detector.
@MainActor
final class MotionIncidentDetector: IncidentDetector {
    let source: IncidentSource = .motionHeuristic
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let logger: DashcamLogger
    /// Touched from the Core Motion operation queue; every access is guarded by `lock`.
    nonisolated(unsafe) private var detector: MotionImpactDetector
    /// Last minute of samples at 100 Hz, saved next to incidents for threshold calibration. Guarded by `lock`.
    nonisolated(unsafe) private var ring = MotionSampleRing(capacity: 6_000)
    private let lock = NSLock()
    private var isRunning = false
    private(set) var lastMagnitude: Double = 0
    private(set) var sampleCount = 0
    var onIncident: ((DetectedIncident) -> Void)?

    init(configuration: MotionDetectorConfiguration, logger: DashcamLogger) {
        self.detector = MotionImpactDetector(configuration: configuration)
        self.logger = logger
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.matrixengineered.dashcam.motion"
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    var statusDescription: String {
        guard isAvailable else { return "Motion sensors unavailable" }
        return isRunning ? String(format: "Monitoring, %.2f g", lastMagnitude) : "Idle"
    }

    func updateConfiguration(_ configuration: MotionDetectorConfiguration) {
        lock.lock(); defer { lock.unlock() }
        detector = MotionImpactDetector(configuration: configuration)
    }

    func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        isRunning = true
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        lock.lock(); detector.reset(); ring.removeAll(); lock.unlock()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.logger.error(.motion, "Device motion error: \(error)")
                return
            }
            guard let motion else { return }
            let sample = MotionSample(
                timestamp: motion.timestamp,
                userAcceleration: SIMD3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z),
                rotationRate: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
            )
            self.lock.lock()
            self.ring.append(sample)
            let event = self.detector.process(sample)
            self.lock.unlock()
            let magnitude = sample.accelerationMagnitude
            if let event {
                let note = String(format: "%@ %.2f", event.kind.rawValue, event.peakMagnitude)
                self.logger.notice(.motion, "Motion event: \(note)")
                Task { @MainActor in
                    self.onIncident?(DetectedIncident(source: .motionHeuristic, occurredAt: nil, note: note))
                }
            }
            Task { @MainActor in
                self.sampleCount += 1
                if self.sampleCount % 25 == 0 { self.lastMagnitude = magnitude }
            }
        }
        logger.info(.motion, "Motion detector started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
        logger.info(.motion, "Motion detector stopped")
    }

    /// The most recent samples (up to one minute), oldest first. Empty when the detector is not running.
    func recentSamples() -> [MotionSample] {
        lock.lock(); defer { lock.unlock() }
        return ring.snapshot()
    }

    /// Developer tool: run a recorded CSV trace through the current configuration without touching sensors.
    func replay(csv: String) throws -> [MotionEvent] {
        let samples = try MotionTrace.parse(csv: csv)
        lock.lock(); let configuration = detector.configuration; lock.unlock()
        return MotionImpactDetector.events(in: samples, configuration: configuration)
    }
}

// MARK: - SafetyKit

enum SafetyKitAvailability: Equatable {
    /// Built without the DASHCAM_SAFETYKIT flag (no entitlement yet).
    case notIncludedInBuild
    case unsupportedHardware
    case notDetermined
    case authorized
    /// Another app is the device's designated Crash Detection receiver, or the user declined.
    case denied

    var description: String {
        switch self {
        case .notIncludedInBuild: return "Not available in this build (entitlement pending)"
        case .unsupportedHardware: return "Crash Detection not supported on this iPhone"
        case .notDetermined: return "Not yet authorized"
        case .authorized: return "Authorized"
        case .denied: return "Denied (another app may hold Crash Detection access)"
        }
    }
}

#if DASHCAM_SAFETYKIT
import SafetyKit

/// Apple Crash Detection adapter. Requires the com.apple.developer.severe-vehicular-crash-event
/// entitlement, which Apple grants per request; only one app per device may receive events, and
/// events arrive via a background launch *after* Emergency SOS completes. The adapter therefore
/// triggers retroactively with the event's own date, and deduplicates by that date because the
/// system may redeliver the same event on later launches.
@MainActor
final class SafetyKitIncidentDetector: NSObject, IncidentDetector, SACrashDetectionDelegate {
    let source: IncidentSource = .appleCrashDetection
    private let manager = SACrashDetectionManager()
    private let logger: DashcamLogger
    private let defaults: UserDefaults
    private(set) var availability: SafetyKitAvailability = .notDetermined
    var onIncident: ((DetectedIncident) -> Void)?

    init(logger: DashcamLogger, defaults: UserDefaults = .standard) {
        self.logger = logger
        self.defaults = defaults
        super.init()
        manager.delegate = self
        refreshAvailability()
    }

    var statusDescription: String { availability.description }

    func refreshAvailability() {
        guard SACrashDetectionManager.isAvailable else { availability = .unsupportedHardware; return }
        switch manager.authorizationStatus {
        case .authorized: availability = .authorized
        case .denied: availability = .denied
        case .notDetermined: availability = .notDetermined
        @unknown default: availability = .notDetermined
        }
    }

    func requestAuthorization() async {
        guard SACrashDetectionManager.isAvailable else { return }
        do {
            let status = try await manager.requestAuthorization()
            logger.notice(.incident, "SafetyKit authorization: \(status.rawValue)")
        } catch {
            logger.error(.incident, "SafetyKit authorization failed: \(error)")
        }
        refreshAvailability()
    }

    func start() { refreshAvailability() }
    func stop() {}

    nonisolated func crashDetectionManager(_ crashDetectionManager: SACrashDetectionManager, didDetect event: SACrashDetectionEvent) {
        let date = event.date
        let location = event.location
        let response = event.response
        Task { @MainActor in
            let key = "safetykit.lastHandledEventDate"
            if let last = self.defaults.object(forKey: key) as? Date, abs(last.timeIntervalSince(date)) < 1 {
                self.logger.notice(.incident, "Ignoring redelivered crash event from \(date)")
                return
            }
            self.defaults.set(date, forKey: key)
            var note = "Apple Crash Detection; SOS \(response == .attempted ? "attempted" : "disabled")"
            if let location { note += String(format: " at %.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude) }
            self.logger.fault(.incident, "Crash event received: \(note)")
            self.onIncident?(DetectedIncident(source: .appleCrashDetection, occurredAt: date, note: note))
        }
    }
}
#else
/// Placeholder used until the SafetyKit entitlement is granted and DASHCAM_SAFETYKIT is defined.
@MainActor
final class SafetyKitIncidentDetector: IncidentDetector {
    let source: IncidentSource = .appleCrashDetection
    let availability: SafetyKitAvailability = .notIncludedInBuild
    var onIncident: ((DetectedIncident) -> Void)?

    init(logger: DashcamLogger) {}

    var statusDescription: String { availability.description }
    func requestAuthorization() async {}
    func start() {}
    func stop() {}
}
#endif
