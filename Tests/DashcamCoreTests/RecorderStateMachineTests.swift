import Foundation
import Testing
@testable import DashcamCore

@Suite("Recorder state machine")
struct RecorderStateMachineTests {
    let run = RunID(rawValue: "run-1")
    let run2 = RunID(rawValue: "run-2")

    @Test("Happy path")
    func happyPath() {
        var state = RecorderState.idle
        for event in [RecorderEvent.startRequested, .started(run), .stopRequested, .stopped] {
            guard let next = RecorderStateMachine.reduce(state, event) else { Issue.record("invalid \(event) in \(state)"); return }
            state = next
        }
        #expect(state == .idle)
    }

    @Test("Interruption and automatic resume start a new run")
    func interruption() {
        var state = RecorderState.recording(run)
        state = RecorderStateMachine.reduce(state, .interruptionBegan("phone call"))!
        #expect(state == .interrupted(run, reason: "phone call"))
        #expect(state.isActive)
        state = RecorderStateMachine.reduce(state, .interruptionEnded)!
        #expect(state == .starting)
        state = RecorderStateMachine.reduce(state, .resumed(run2))!
        #expect(state == .recording(run2))
        #expect(state.runID == run2)
    }

    @Test("Stop while interrupted and failure paths")
    func stopWhileInterrupted() {
        let interrupted = RecorderState.interrupted(run, reason: "background")
        #expect(RecorderStateMachine.reduce(interrupted, .stopRequested) == .stopping)
        #expect(RecorderStateMachine.reduce(.recording(run), .failed("media services reset")) == .failed("media services reset"))
        #expect(RecorderStateMachine.reduce(.failed("x"), .startRequested) == .starting)
        #expect(RecorderStateMachine.reduce(.failed("x"), .reset) == .idle)
    }

    @Test("Invalid transitions are rejected")
    func invalid() {
        #expect(RecorderStateMachine.reduce(.idle, .stopped) == nil)
        #expect(RecorderStateMachine.reduce(.idle, .started(run)) == nil)
        #expect(RecorderStateMachine.reduce(.recording(run), .started(run2)) == nil)
        #expect(RecorderStateMachine.reduce(.stopping, .startRequested) == nil)
        #expect(!RecorderState.idle.isActive)
        #expect(RecorderState.recording(run).isActive)
    }
}
