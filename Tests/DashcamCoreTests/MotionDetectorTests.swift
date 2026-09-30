import Foundation
import Testing
@testable import DashcamCore

@Suite("Motion impact detector")
struct MotionDetectorTests {
    @Test("Quiet driving noise produces no events")
    func quiet() {
        let trace = MotionTrace.synthetic(duration: 120)
        #expect(MotionImpactDetector.events(in: trace).isEmpty)
    }

    @Test("A single-sample spike (mount rattle, pothole) is ignored")
    func singleSpike() {
        let trace = MotionTrace.synthetic(duration: 10) { t in
            abs(t - 5.0) < 0.005 ? SIMD3(0, 0, 5.0) : .zero
        }
        #expect(MotionImpactDetector.events(in: trace).isEmpty)
    }

    @Test("A sustained high-g impact is detected once")
    func sustainedImpact() {
        let trace = MotionTrace.synthetic(duration: 10) { t in
            (5.0..<5.06).contains(t) ? SIMD3(3.5, 1.0, 0.5) : .zero
        }
        let events = MotionImpactDetector.events(in: trace)
        #expect(events.count == 1)
        #expect(events.first?.kind == .impact)
        #expect(events.first.map { abs($0.timestamp - 5.02) < 0.02 } == true)
        #expect(events.first.map { $0.peakMagnitude > 3.6 } == true)
    }

    @Test("Sustained hard braking is detected; a brief brake tap is not")
    func braking() {
        let hard = MotionTrace.synthetic(duration: 10) { t in
            (4.0..<5.5).contains(t) ? SIMD3(0, 0.75, 0) : .zero
        }
        let hardEvents = MotionImpactDetector.events(in: hard)
        #expect(hardEvents.count == 1)
        #expect(hardEvents.first?.kind == .hardBraking)

        let tap = MotionTrace.synthetic(duration: 10) { t in
            (4.0..<4.2).contains(t) ? SIMD3(0, 0.75, 0) : .zero
        }
        #expect(MotionImpactDetector.events(in: tap).isEmpty)
    }

    @Test("Cooldown suppresses repeated events; separated events are both reported")
    func cooldown() {
        let close = MotionTrace.synthetic(duration: 20) { t in
            ((2.0..<2.1).contains(t) || (7.0..<7.1).contains(t)) ? SIMD3(4, 0, 0) : .zero
        }
        #expect(MotionImpactDetector.events(in: close).count == 1)

        let apart = MotionTrace.synthetic(duration: 40) { t in
            ((2.0..<2.1).contains(t) || (30.0..<30.1).contains(t)) ? SIMD3(4, 0, 0) : .zero
        }
        #expect(MotionImpactDetector.events(in: apart).count == 2)
    }

    @Test("Impact-only configuration ignores braking and rotation")
    func impactOnly() {
        let trace = MotionTrace.synthetic(duration: 10) { t in
            (2.0..<4.0).contains(t) ? SIMD3(0, 0.9, 0) : .zero
        }.map { sample in
            var s = sample
            if (6.0..<6.5).contains(s.timestamp) { s.rotationRate = SIMD3(6, 0, 0) }
            return s
        }
        #expect(MotionImpactDetector.events(in: trace, configuration: .impactOnly).isEmpty)
        let defaultEvents = MotionImpactDetector.events(in: trace)
        #expect(defaultEvents.map(\.kind) == [.hardBraking, .abnormalRotation] || defaultEvents.map(\.kind) == [.hardBraking])
    }

    @Test("Abnormal rotation is detected")
    func rotation() {
        var trace = MotionTrace.synthetic(duration: 5)
        for i in 200..<210 { trace[i].rotationRate = SIMD3(0, 5.5, 0) }
        let events = MotionImpactDetector.events(in: trace)
        #expect(events.count == 1)
        #expect(events.first?.kind == .abnormalRotation)
    }

    @Test("CSV traces round-trip")
    func csvRoundTrip() throws {
        let trace = Array(MotionTrace.synthetic(duration: 0.1).prefix(5))
        let csv = MotionTrace.csv(from: trace)
        let parsed = try MotionTrace.parse(csv: csv)
        #expect(parsed.count == trace.count)
        for (a, b) in zip(parsed, trace) {
            #expect(abs(a.timestamp - b.timestamp) < 1e-9)
            #expect(abs(a.userAcceleration.x - b.userAcceleration.x) < 1e-9)
        }
        let fourColumn = try MotionTrace.parse(csv: "t,ax,ay,az\n0,0,0,0\n0.01,1,2,3\n")
        #expect(fourColumn.count == 2)
        #expect(fourColumn[1].userAcceleration == SIMD3(1, 2, 3))
        #expect(throws: DashcamCoreError.self) { try MotionTrace.parse(csv: "0,1,2\n") }
    }

    @Test("Detector reset clears state")
    func reset() {
        var detector = MotionImpactDetector()
        for i in 0..<2 { _ = detector.process(MotionSample(timestamp: Double(i) * 0.01, userAcceleration: SIMD3(4, 0, 0))) }
        detector.reset()
        let event = detector.process(MotionSample(timestamp: 0.02, userAcceleration: SIMD3(4, 0, 0)))
        #expect(event == nil)
    }
}

@Suite("Motion sample ring")
struct MotionSampleRingTests {
    @Test("Keeps the newest samples in order and wraps")
    func wraps() {
        var ring = MotionSampleRing(capacity: 3)
        #expect(ring.isEmpty)
        for i in 0..<5 {
            ring.append(MotionSample(timestamp: Double(i), userAcceleration: .zero))
        }
        #expect(ring.snapshot().map(\.timestamp) == [2, 3, 4])
        ring.removeAll()
        #expect(ring.isEmpty)
        ring.append(MotionSample(timestamp: 9, userAcceleration: .zero))
        #expect(ring.snapshot().map(\.timestamp) == [9])
    }

    @Test("Snapshot round-trips through CSV")
    func csv() throws {
        var ring = MotionSampleRing(capacity: 10)
        for sample in MotionTrace.synthetic(duration: 0.05) { ring.append(sample) }
        let parsed = try MotionTrace.parse(csv: MotionTrace.csv(from: ring.snapshot()))
        #expect(parsed.count == ring.snapshot().count)
    }
}
