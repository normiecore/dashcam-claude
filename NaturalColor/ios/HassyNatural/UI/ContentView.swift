import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

private struct ImportedPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let source = received.file
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Picker", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            return ImportedPhoto(url: destination)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var reviewing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    @State private var picking = false
    @State private var importing = false
    @State private var about = false
    @State private var fetching = false
    @State private var pickerTask: Task<Void, Never>?
    @State private var pickerGeneration = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraView(model: model,
                active: !reviewing && !picking && !importing && !about && !fetching && scenePhase == .active,
                onCapture: { url, ratio, mode, output in cancelPicker(); model.captured(url: url, ratio: ratio, mode: mode, output: output) },
                onReview: { reviewing = true },
                onLibrary: { picking = true },
                onFiles: { importing = true },
                onAbout: { about = true })
                .accessibilityHidden(reviewing).allowsHitTesting(!reviewing)
            if reviewing { reviewScreen }
            if fetching || (model.busy && reviewing) {
                ZStack {
                    Color.black.opacity(0.8).ignoresSafeArea()
                    ProgressView("Opening original photo…").font(.caption)
                }.accessibilityIdentifier("importProgress")
            }
        }
        .photosPicker(isPresented: $picking, selection: $pickerItem, matching: .images, preferredItemEncoding: .current)
        .sheet(isPresented: $about) { aboutView }
        .sheet(isPresented: Binding(get: { model.shareURL != nil }, set: { if !$0 { model.shareURL = nil } })) {
            if let url = model.shareURL { ShareSheet(url: url) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: false) { result in
            do {
                if let url = try result.get().first { cancelPicker(); reviewing = true; model.load(url: url) }
            } catch { model.error = error.localizedDescription }
        }
        .onChange(of: pickerItem) { _, item in importSelection(item) }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { await model.loadDemo() }
        }
        .alert("Unable to complete", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.error ?? "") }
        .alert("Saved", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.notice ?? "") }
    }

    private var reviewScreen: some View {
        NavigationStack {
            EditorView(model: model).background(.black)
                .navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { reviewing = false } label: { Label("Camera", systemImage: "chevron.left") }
                            .accessibilityIdentifier("backToCamera")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Photo library", systemImage: "photo.on.rectangle") { picking = true }
                            Button("Import from Files", systemImage: "folder") { importing = true }
                            Button("About Natural", systemImage: "info.circle") { about = true }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Review options")
                    }
                }
        }
    }

    private var aboutView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Natural").font(.largeTitle.weight(.light))
                    Text("A camera, with room to look.")
                    Text("Frame a moment, take the photo and carry on. A light finishing adjustment keeps the original colours close.")
                    Text("RAW files are decoded through Apple’s RAW support. Unsupported originals show an error instead of substituting their embedded preview. HEIC saves space and retains wide colour. JPEG is available when you need it. Your imported files remain unchanged.")
                    Text("Photos stay on this device. No account or upload is required.")
                    Text("A finished photo saves straight to Photos. Medium-quality HEIC is the default. Enable Save RAW original in Camera controls to keep an additional RAW file where supported. Native framing keeps the camera’s pixel dimensions; optional ratios crop the finished photo. Interrupted saves remain in Files → On My iPhone → Natural → Pending Captures or Processed.")
                }.padding(24)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { about = false } } }
        }
    }

    private func cancelPicker() {
        pickerTask?.cancel()
        pickerGeneration = UUID()
        fetching = false
    }

    private func importSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        cancelPicker()
        let token = pickerGeneration
        fetching = true
        reviewing = true
        pickerTask = Task { @MainActor in
            do {
                guard let imported = try await item.loadTransferable(type: ImportedPhoto.self) else { throw PhotoError.unreadable }
                guard !Task.isCancelled, pickerGeneration == token else { return }
                model.load(url: imported.url)
                fetching = false
            } catch {
                guard !Task.isCancelled, pickerGeneration == token else { return }
                fetching = false
                model.error = error.localizedDescription
            }
        }
    }
}
