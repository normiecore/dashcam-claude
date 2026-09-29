import Foundation

/// One motion sample. Acceleration is *user* acceleration in g (gravity removed, as Core Motion's
/// `CMDeviceMotion.userAcceleration` provides); rotation rate in radians per second.
public struct MotionSample: Sendable, Equatable, Codable {
    public var timestamp: TimeInterval
    public var userAcceleration: SIMD3<Double>
    public var rotationRate: SIMD3<Double>

    public init(timestamp: TimeInterval, userAcceleration: SIMD3<Double>, rotationRate: SIMD3<Double> = .zero) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
    }

    public var accelerationMagnitude: Double { (userAcceleration * userAcceleration).sum().squareRoot() }
    public var rotationMagnitude: Double { (rotationRate * rotationRate).sum().squareRoot() }
}

public struct MotionDetectorConfiguration: Codable, Sendable, Equatable {
    /// Instantaneous |a| (g) that counts as an impact candidate.
    public var impactThresholdG: Double
    /// Consecutive samples above the impact threshold required before an impact event is emitted.
    /// At 100 Hz, 3 samples = 30 ms, which rejects single-sample spikes from mount rattle.
    public var impactMinimumSamples: Int
    /// Low-pass-filtered |a| (g) that counts as hard braking / hard cornering.
    public var hardBrakingThresholdG: Double
    /// How long the filtered magnitude must stay above the braking threshold.
    public var hardBrakingMinimumDuration: TimeInterval
    /// Time constant of the first-order low-pass filter applied before the braking test.
    public var lowPassTimeConstant: TimeInterval
    /// |rotation rate| (rad/s) that counts as abnormal rotation (spin, rollover).
    public var rotationThreshold: Double
    /// Minimum spacing between emitted events.
    public var cooldown: TimeInterval

    public init(impactThresholdG: Double = 3.0, impactMinimumSamples: Int = 3, hardBrakingThresholdG: Double = 0.55, hardBrakingMinimumDuration: TimeInterval = 0.4, lowPassTimeConstant: TimeInterval = 0.15, rotationThreshold: Double = 5.0, cooldown: TimeInterval = 15) {
        self.impactThresholdG = impactThresholdG
        self.impactMinimumSamples = max(1, impactMinimumSamples)
        self.hardBrakingThresholdG = hardBrakingThresholdG
        self.hardBrakingMinimumDuration = hardBrakingMinimumDuration
        self.lowPassTimeConstant = lowPassTimeConstant
        self.rotationThreshold = rotationThreshold
        self.cooldown = cooldown
    }

    /// Conservative defaults: impact-only detection, so ordinary hard braking never saves a clip.
    public static let impactOnly = MotionDetectorConfiguration(hardBrakingThresholdG: .infinity, rotationThreshold: .infinity)
}

public struct MotionEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case impact
        case hardBraking
        case abnormalRotation
    }

    public let kind: Kind
    public let timestamp: TimeInterval
    public let peakMagnitude: Double

    public init(kind: Kind, timestamp: TimeInterval, peakMagnitude: Double) {
        self.kind = kind
        self.timestamp = timestamp
        self.peakMagnitude = peakMagnitude
    }
}

/// Supplementary motion heuristic. Pure and synchronous so it can be driven by live Core Motion
/// callbacks or by recorded traces in tests. This is not a crash detector: it is a coarse filter whose
/// thresholds must be validated on real drives before it is allowed to trigger incidents by default.
public struct MotionImpactDetector: Sendable {
    public var configuration: MotionDetectorConfiguration
    private var filtered: Double = 0
    private var lastTimestamp: TimeInterval?
    private var aboveImpactCount = 0
    private var impactPeak: Double = 0
    private var brakingStart: TimeInterval?
    private var brakingPeak: Double = 0
    private var lastEventTimestamp: TimeInterval = -.infinity

    public init(configuration: MotionDetectorConfiguration = MotionDetectorConfiguration()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        filtered = 0
        lastTimestamp = nil
        aboveImpactCount = 0
        impactPeak = 0
        brakingStart = nil
        brakingPeak = 0
        lastEventTimestamp = -.infinity
    }

    /// Feeds one sample. Returns an event at most once per cooldown period.
    public mutating func process(_ sample: MotionSample) -> MotionEvent? {
        let magnitude = sample.accelerationMagnitude
        let dt: TimeInterval
        if let last = lastTimestamp, sample.timestamp > last {
            dt = sample.timestamp - last
        } else {
            dt = 0.01
        }
        lastTimestamp = sample.timestamp

        let alpha = dt / (configuration.lowPassTimeConstant + dt)
        filtered += alpha * (magnitude - filtered)

        var candidate: MotionEvent?

        // Impact: sustained high instantaneous magnitude.
        if magnitude >= configuration.impactThresholdG {
            aboveImpactCount += 1
            impactPeak = max(impactPeak, magnitude)
            if aboveImpactCount >= configuration.impactMinimumSamples {
                candidate = MotionEvent(kind: .impact, timestamp: sample.timestamp, peakMagnitude: impactPeak)
            }
        } else {
            aboveImpactCount = 0
            impactPeak = 0
        }

        // Abnormal rotation.
        if candidate == nil, sample.rotationMagnitude >= configuration.rotationThreshold {
            candidate = MotionEvent(kind: .abnormalRotation, timestamp: sample.timestamp, peakMagnitude: sample.rotationMagnitude)
        }

        // Hard braking: filtered magnitude sustained above threshold.
        if filtered >= configuration.hardBrakingThresholdG {
            if brakingStart == nil { brakingStart = sample.timestamp }
            brakingPeak = max(brakingPeak, filtered)
            if candidate == nil, let start = brakingStart, sample.timestamp - start >= configuration.hardBrakingMinimumDuration {
                candidate = MotionEvent(kind: .hardBraking, timestamp: sample.timestamp, peakMagnitude: brakingPeak)
            }
        } else {
            brakingStart = nil
            brakingPeak = 0
        }

        guard let event = candidate else { return nil }
        guard sample.timestamp - lastEventTimestamp >= configuration.cooldown else { return nil }
        lastEventTimestamp = sample.timestamp
        aboveImpactCount = 0
        impactPeak = 0
        brakingStart = nil
        brakingPeak = 0
        return event
    }

    /// Runs a whole trace through a fresh detector. Used by tests and the developer trace-replay tool.
    public static func events(in trace: [MotionSample], configuration: MotionDetectorConfiguration = MotionDetectorConfiguration()) -> [MotionEvent] {
        var detector = MotionImpactDetector(configuration: configuration)
        return trace.compactMap { detector.process($0) }
    }
}

/// CSV trace format: `timestamp,ax,ay,az[,gx,gy,gz]` with an optional header line. Acceleration in g.
public enum MotionTrace {
    public static func parse(csv: String) throws -> [MotionSample] {
        var samples: [MotionSample] = []
        for (lineNumber, rawLine) in csv.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if lineNumber == 0, Double(fields[0]) == nil { continue } // header
            guard fields.count == 4 || fields.count == 7, let values = Optional(fields.compactMap(Double.init)), values.count == fields.count else {
                throw DashcamCoreError.corruptSidecar("Motion trace line \(lineNumber + 1) is malformed: \(line)")
            }
            let acceleration = SIMD3(values[1], values[2], values[3])
            let rotation = values.count == 7 ? SIMD3(values[4], values[5], values[6]) : SIMD3<Double>.zero
            samples.append(MotionSample(timestamp: values[0], userAcceleration: acceleration, rotationRate: rotation))
        }
        return samples
    }

    public static func csv(from samples: [MotionSample]) -> String {
        var lines = ["timestamp,ax,ay,az,gx,gy,gz"]
        for s in samples {
            lines.append("\(s.timestamp),\(s.userAcceleration.x),\(s.userAcceleration.y),\(s.userAcceleration.z),\(s.rotationRate.x),\(s.rotationRate.y),\(s.rotationRate.z)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Synthetic trace builder for tests: `duration` seconds at `rate` Hz of quiet driving noise, with
    /// injected events applied via `shape`.
    public static func synthetic(duration: TimeInterval, rate: Double = 100, noiseG: Double = 0.03, shape: (TimeInterval) -> SIMD3<Double> = { _ in .zero }) -> [MotionSample] {
        let count = Int(duration * rate)
        var generator = SeededGenerator(seed: 42)
        return (0..<count).map { i in
            let t = Double(i) / rate
            let noise = SIMD3(
                Double.random(in: -noiseG...noiseG, using: &generator),
                Double.random(in: -noiseG...noiseG, using: &generator),
                Double.random(in: -noiseG...noiseG, using: &generator)
            )
            return MotionSample(timestamp: t, userAcceleration: noise + shape(t))
        }
    }
}

/// Deterministic PRNG so synthetic traces are reproducible across platforms.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
