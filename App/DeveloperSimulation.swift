import Foundation

#if DEBUG
/// These inject into the real service. They do not impersonate a SafetyKit event
/// and do not test Apple's detector or a real physical interruption.
enum DeveloperSimulation {
    static func incident(on service: CameraCaptureService) {
        service.saveIncident(source: .developer)
    }

    static func interruption(on service: CameraCaptureService) {
        service.stop(reason: "Developer simulated interruption")
    }
}
#endif
