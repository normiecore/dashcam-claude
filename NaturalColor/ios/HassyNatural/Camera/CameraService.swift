import AVFoundation
import SwiftUI

struct CameraLens: Identifiable {
    let id: String
    let title: String
    let device: AVCaptureDevice
}

@MainActor
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var lenses: [CameraLens] = []
    @Published var selectedLens = ""
    @Published var ready = false
    @Published var capturing = false
    @Published var supportsRaw = false
    @Published var useRaw = false
    @Published var error: String?
    var onCapture: ((URL) -> Void)?
    private let queue = DispatchQueue(label: "com.hassynatural.camera")
    private let output = AVCapturePhotoOutput()
    private var captureDelegate: PhotoCaptureDelegate?
    private var active = false
    private var configurationID = UUID()

    func start() async {
        active = true
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard active else { return }
        guard authorized else {
            error = "Allow camera access in Settings, or import a photo from your library."
            return
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        lenses = devices.map { device in
            let title: String
            switch device.deviceType {
            case .builtInUltraWideCamera: title = "Ultra wide"
            case .builtInTelephotoCamera: title = "Telephoto"
            default: title = "Wide"
            }
            return CameraLens(id: device.uniqueID, title: title, device: device)
        }
        guard let device = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            error = "No rear camera is available. You can still import photos."
            return
        }
        switchLens(device.uniqueID)
    }

    func switchLens(_ id: String) {
        guard active, let lens = lenses.first(where: { $0.id == id }) else { return }
        let token = UUID()
        configurationID = token
        ready = false
        queue.async { [self] in
            do {
                let input = try AVCaptureDeviceInput(device: lens.device)
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
                if let dimensions = lens.device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) {
                    output.maxPhotoDimensions = dimensions
                }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                let raw = output.isAppleProRAWSupported && output.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                Task { @MainActor in
                    guard active, configurationID == token else { return }
                    selectedLens = id
                    supportsRaw = raw
                    if !raw { useRaw = false }
                    ready = true
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
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func capture() {
        guard ready, !capturing else { return }
        capturing = true
        let rawRequested = useRaw
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
            settings.photoQualityPrioritization = .balanced
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
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(UUID().uuidString).\(photo.isRawPhoto ? "dng" : "jpg")")
            try data.write(to: url, options: .atomic)
            result = .success(url)
        } catch { result = .failure(error) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { completion(.failure(error)) } else { completion(result ?? .failure(CameraFailure.capture)) }
    }
}
