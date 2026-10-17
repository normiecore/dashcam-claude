import SwiftUI
import Photos

@MainActor
final class EditorModel: ObservableObject {
    @Published var photo: LoadedPhoto?
    @Published var preview: CGImage?
    @Published var originalPreview: CGImage?
    @Published var settings = EditSettings()
    @Published var busy = false
    @Published var exporting = false
    @Published var error: String?
    @Published var notice: String?
    @Published var shareURL: URL?
    @Published var savingCaptures = 0
    @Published var captureStatus = "Native resolution · Auto-save to Photos"
    private let engine = PhotoEngine()
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = UUID()
    private var previewGeneration = UUID()

    func loadDemo() async {
        busy = true
        do {
            let demo = await engine.demoPhoto()
            let original = try await engine.preview(photo: demo, settings: EditSettings(), original: true)
            let rendered = try await engine.preview(photo: demo, settings: EditSettings())
            photo = demo
            originalPreview = original
            preview = rendered
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func load(url: URL, initialSettings: EditSettings = .init()) {
        loadTask?.cancel()
        previewTask?.cancel()
        let token = UUID()
        generation = token
        busy = true
        error = nil
        loadTask = Task {
            do {
                let local = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    return destination
                }.value
                let loaded = try await engine.load(url: local)
                let original = try await engine.preview(photo: loaded, settings: initialSettings, original: true)
                let edited = try await engine.preview(photo: loaded, settings: initialSettings)
                guard !Task.isCancelled, generation == token else { return }
                photo = loaded
                settings = initialSettings
                originalPreview = original
                preview = edited
                busy = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    /// Each capture owns its save task. Reviewing/importing another image cannot cancel it.
    func captured(url: URL, ratio: PhotoAspectRatio, mode: PhotoSaveMode, output: PhotoOutputOptions) {
        let edit = EditSettings(aspectRatio: ratio)
        load(url: url, initialSettings: edit)
        let reviewTask = loadTask
        savingCaptures += 1
        captureStatus = "Saving to Photos…"
        Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "Save capture", expirationHandler: nil)
            defer {
                savingCaptures -= 1
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            var processed: URL?
            do {
                if mode != .original {
                    let rendered = try await engine.exportCapture(url: url, settings: edit, output: output)
                    // Keep a durable recovery copy until Photos confirms the transaction.
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Processed", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(rendered.lastPathComponent)
                    try FileManager.default.moveItem(at: rendered, to: destination)
                    processed = destination
                }
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else { throw PhotoError.photoAccess }
                let resources = mode.resources(original: url, processed: processed)
                try await PHPhotoLibrary.shared().performChanges {
                    for resource in resources {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, fileURL: resource, options: nil)
                    }
                }
                await reviewTask?.value
                if let processed { try? FileManager.default.removeItem(at: processed) }
                // Photos has copied the resources; retain only the review copy
                // in temporary storage, not another permanent RAW/HEIC file.
                try? FileManager.default.removeItem(at: url)
                captureStatus = mode == .both ? "Original + processed saved to Photos" : "Photo saved to Photos"
            } catch {
                captureStatus = "Save incomplete · Copies kept in Files"
                self.error = "Camera Roll save failed. Your capture is safe in Files → Natural → Pending Captures. Any developed copy is in Processed. " + error.localizedDescription
            }
        }
    }

    func updatePreview() {
        previewTask?.cancel()
        guard let photo else { return }
        let token = UUID()
        previewGeneration = token
        let current = settings
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(75))
                let result = try await engine.preview(photo: photo, settings: current)
                guard !Task.isCancelled, previewGeneration == token else { return }
                preview = result
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, previewGeneration == token else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func reset() {
        settings = EditSettings(aspectRatio: settings.aspectRatio)
        updatePreview()
    }

    func export(saveToPhotos: Bool) async {
        guard let photo, !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let url = try await engine.export(photo: photo, settings: settings, output: .current)
            if saveToPhotos {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else { throw PhotoError.photoAccess }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
                notice = "Full-resolution photo saved to Photos."
            } else {
                shareURL = url
            }
        } catch { self.error = error.localizedDescription }
    }
}
