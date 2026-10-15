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

    func load(url: URL) {
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
                let original = try await engine.preview(photo: loaded, settings: EditSettings(), original: true)
                let edited = try await engine.preview(photo: loaded, settings: EditSettings())
                guard !Task.isCancelled, generation == token else { return }
                photo = loaded
                settings = EditSettings()
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
        settings = EditSettings()
        updatePreview()
    }

    func export(saveToPhotos: Bool) async {
        guard let photo, !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let url = try await engine.export(photo: photo, settings: settings)
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
