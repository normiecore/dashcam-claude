import Foundation

/// High-level state of the dash-cam session, independent of AVFoundation.
public enum RecorderState: Equatable, Sendable {
    case idle
    case starting
    case recording(RunID)
    /// Capture is paused by the system (call, backgrounding, system pressure). Resumes automatically when the
    /// interruption ends; a new run begins because the writer had to be closed.
    case interrupted(RunID?, reason: String)
    case stopping
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .starting, .recording, .interrupted: return true
        case .idle, .stopping, .failed: return false
        }
    }

    public var runID: RunID? {
        switch self {
        case .recording(let run): return run
        case .interrupted(let run, _): return run
        default: return nil
        }
    }
}

public enum RecorderEvent: Equatable, Sendable {
    case startRequested
    case started(RunID)
    case interruptionBegan(String)
    case interruptionEnded
    case resumed(RunID)
    case stopRequested
    case stopped
    case failed(String)
    case reset
}

/// Pure transition function. Returns nil for an invalid transition so callers can log and ignore it
/// instead of corrupting state.
public enum RecorderStateMachine {
    public static func reduce(_ state: RecorderState, _ event: RecorderEvent) -> RecorderState? {
        switch (state, event) {
        case (.idle, .startRequested), (.failed, .startRequested):
            return .starting
        case (.starting, .started(let run)):
            return .recording(run)
        case (.starting, .failed(let reason)), (.recording, .failed(let reason)), (.interrupted, .failed(let reason)), (.stopping, .failed(let reason)):
            return .failed(reason)
        case (.recording(let run), .interruptionBegan(let reason)):
            return .interrupted(run, reason: reason)
        case (.starting, .interruptionBegan(let reason)):
            return .interrupted(nil, reason: reason)
        case (.interrupted, .interruptionEnded):
            return .starting
        case (.interrupted, .resumed(let run)), (.starting, .resumed(let run)):
            return .recording(run)
        case (.recording, .stopRequested), (.interrupted, .stopRequested), (.starting, .stopRequested):
            return .stopping
        case (.stopping, .stopped):
            return .idle
        case (_, .reset):
            return .idle
        default:
            return nil
        }
    }
}
