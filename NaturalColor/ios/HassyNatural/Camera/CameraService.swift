import AVFoundation
import SwiftUI

struct CameraLens: Identifiable {
    let id: String
    let title: String
    let device: AVCaptureDevice?
}

@MainActor
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var lenses: [CameraLens] = []
    @Published var selectedLens = ""
    @Published var ready = false
    @Published var capturing = false
    @Published var supportsRaw = false
    @Published var useRaw = true
    @Published var error: String?
    @Published var permissionDenied = false
    @Published var unavailableReason: String?
    @Published var iso: Float = 0
    @Published var shutterSeconds: Double = 0
    @Published var aperture: Float = 0
    @Published var exposureBias: Float = 0
    let isInterfaceTest: Bool
    private var device: AVCaptureDevice?
    private var meterTask: Task<Void, Never>?

    init(interfaceTest: Bool = false) {
        isInterfaceTest = interfaceTest
        super.init()
    }

    var canCapture: Bool { ready && !capturing && !isInterfaceTest }
    var shutterText: String {
        guard shutterSeconds.isFinite, shutterSeconds > 0 else { return "—" }
        return shutterSeconds < 1 ? "1/\(Int((1 / shutterSeconds).rounded()))" : String(format: "%.1f s", shutterSeconds)
    }
    var onCapture: ((URL) -> Void)?
    private let queue = DispatchQueue(label: "com.hassynatural.camera")
    private let output = AVCapturePhotoOutput()
    private var captureDelegate: PhotoCaptureDelegate?
    private var active = false
    private var configurationID = UUID()

    func start() async {
        guard !active else { return }
        active = true
        let startup = UUID()
        configurationID = startup
        permissionDenied = false
        unavailableReason = nil
        if isInterfaceTest {
            if ProcessInfo.processInfo.arguments.contains("--camera-denied-ui-testing") {
                permissionDenied = true
                unavailableReason = "Camera access is off"
                return
            }
            lenses = [CameraLens(id: "wide", title: "Wide", device: nil), CameraLens(id: "tele", title: "Tele", device: nil)]
            selectedLens = "wide"
            supportsRaw = true
            iso = 125; shutterSeconds = 1 / 125; aperture = 1.78
            ready = true
            return
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        guard !devices.isEmpty else {
            unavailableReason = "Camera unavailable"
            return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard active, configurationID == startup, !Task.isCancelled else { return }
        guard authorized else {
            permissionDenied = true
            unavailableReason = "Camera access is off"
            return
        }
        lenses = devices.map { device in
            let title: String
            switch device.deviceType {
            case .builtInUltraWideCamera: title = "Ultra"
            case .builtInTelephotoCamera: title = "Tele"
            default: title = "Wide"
            }
            return CameraLens(id: device.uniqueID, title: title, device: device)
        }
        let preferred = devices.first(where: { $0.uniqueID == selectedLens })
            ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices[0]
        switchLens(preferred.uniqueID)
    }

    func switchLens(_ id: String) {
        guard active, let lens = lenses.first(where: { $0.id == id }) else { return }
        if isInterfaceTest { selectedLens = id; return }
        guard let captureDevice = lens.device else { return }
        let token = UUID()
        configurationID = token
        ready = false
        device = nil
        meterTask?.cancel()
        queue.async { [self] in
            do {
                let input = try AVCaptureDeviceInput(device: captureDevice)
                session.beginConfiguration()
                session.sessionPreset = .photo
                let previous = session.inputs
                previous.forEach { session.removeInput($0) }
                guard session.canAddInput(input) else {
                    previous.filter { session.canAddInput($0) }.forEach { session.addInput($0) }
                    session.commitConfiguration()
                    throw CameraFailure.configuration
                }
                session.addInput(input)
                if !session.outputs.contains(output) {
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw CameraFailure.configuration
                    }
                    session.addOutput(output)
                }
                if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
                output.maxPhotoQualityPrioritization = .quality
                if let dimensions = captureDevice.activeFormat.supportedMaxPhotoDimensions.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) {
                    output.maxPhotoDimensions = dimensions
                }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                let raw = output.isAppleProRAWSupported && output.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                Task { @MainActor in
                    guard active, configurationID == token else { return }
                    selectedLens = id
                    supportsRaw = raw
                    device = captureDevice
                    ready = true
                    startMetering(captureDevice, token: token)
                }
            } catch {
                Task { @MainActor in
                    guard active, configurationID == token else { return }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        active = false
        configurationID = UUID()
        ready = false
        device = nil
        meterTask?.cancel()
        meterTask = nil
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func startMetering(_ device: AVCaptureDevice, token: UUID) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active, self.configurationID == token else { return }
                self.iso = device.iso
                self.shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
                self.aperture = device.lensAperture
                self.exposureBias = device.exposureTargetBias
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func setExposureBias(_ value: Float) {
        guard value.isFinite, ready else { return }
        if isInterfaceTest { exposureBias = min(max(value, -2), 2); return }
        guard let device else { return }
        let bias = min(max(value, max(-2, device.minExposureTargetBias)), min(2, device.maxExposureTargetBias))
        queue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(bias, completionHandler: nil)
            } catch {
                Task { @MainActor [weak self] in self?.error = error.localizedDescription }
            }
        }
    }

    func focus(at point: CGPoint) {
        guard ready, let device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
            } catch {
                Task { @MainActor [weak self] in self?.error = error.localizedDescription }
            }
        }
    }

    func capture() {
        guard canCapture else { return }
        capturing = true
        let rawRequested = useRaw && supportsRaw
        let delegate = PhotoCaptureDelegate { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.capturing = false
                self.captureDelegate = nil
                switch result {
                case .success(let url): self.onCapture?(url)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
        captureDelegate = delegate
        queue.async { [output] in
            let settings: AVCapturePhotoSettings
            if rawRequested, let format = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private enum CameraFailure: LocalizedError {
    case configuration, capture
    var errorDescription: String? { "The camera could not capture this photo. Try another lens or import a photo." }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<URL, Error>) -> Void
    private var result: Result<URL, Error>?
    init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { result = .failure(error); return }
        guard let data = photo.fileDataRepresentation() else { result = .failure(CameraFailure.capture); return }
        do {
            let originals = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Originals", isDirectory: true)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let url = originals.appendingPathComponent("Capture-\(UUID().uuidString).\(photo.isRawPhoto ? "dng" : "jpg")")
            try data.write(to: url, options: .atomic)
            result = .success(url)
        } catch { result = .failure(error) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { completion(.failure(error)) } else { completion(result ?? .failure(CameraFailure.capture)) }
    }
}
