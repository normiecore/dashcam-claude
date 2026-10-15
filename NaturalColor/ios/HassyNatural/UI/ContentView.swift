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
    @State private var pickerItem: PhotosPickerItem?
    @State private var camera = false
    @State private var importing = false
    @State private var about = false
    @State private var fetching = false
    @State private var pickerTask: Task<Void, Never>?
    @State private var pickerGeneration = UUID()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if model.photo != nil { EditorView(model: model) } else { welcome }
                if model.busy || fetching {
                    ZStack {
                        Color.black.opacity(0.65).ignoresSafeArea()
                        ProgressView("Opening original photo…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityIdentifier("importProgress")
                }
            }
            .navigationTitle("Hassy Natural")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { about = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("About Hassy Natural")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Camera", systemImage: "camera") { camera = true }
                        Button("Import file", systemImage: "folder") { importing = true }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add photo")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.photo != nil {
                    PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                        Label("Open another photo", systemImage: "photo.on.rectangle")
                            .font(.footnote).padding(12).frame(maxWidth: .infinity)
                    }.background(Color(white: 0.04))
                }
            }
            .sheet(isPresented: $camera) { CameraView { cancelPicker(); model.load(url: $0) } }
            .sheet(isPresented: $about) { aboutView }
            .sheet(isPresented: Binding(get: { model.shareURL != nil }, set: { if !$0 { model.shareURL = nil } })) {
                if let url = model.shareURL { ShareSheet(url: url) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: false) { result in
                do {
                    if let url = try result.get().first { cancelPicker(); model.load(url: url) }
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
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.aperture").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(Color.accentColor)
            VStack(spacing: 10) {
                Text("A considered take\non natural colour.").font(.system(size: 32, weight: .light, design: .serif)).multilineTextAlignment(.center)
                Text("Capture a photo or open an original to begin. Start with ProRAW for the closest reference rendering.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 14) {
                Button { camera = true } label: {
                    Label("Open camera", systemImage: "camera").frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.borderedProminent).foregroundStyle(.black).accessibilityIdentifier("openCamera")
                PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                    Label("Photo library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.bordered).accessibilityIdentifier("openLibrary")
                Button("Import JPEG, HEIC or DNG from Files") { importing = true }
                    .font(.footnote).padding(8).accessibilityIdentifier("openFiles")
            }
            Text("Experimental colour rendering · Originals stay untouched")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28)
    }

    private var aboutView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Hassy Natural").font(.largeTitle.weight(.light))
                    Text("An independent camera and photo editor exploring natural colour rendering.")
                    Text("Reference rendering uses recovered chroma processing and the Standard film curve. Its adaptation to phone images is experimental and has not been validated as a complete HNCS match. This independent app is not affiliated with Hasselblad.")
                    Text("RAW files are decoded through Apple’s RAW support. Unsupported originals show an error instead of substituting their embedded preview. Exports are full-resolution sRGB JPEGs; your original files remain unchanged.")
                    Text("Photos stay on this device. No account or upload is required.")
                    Text("Camera originals are preserved in Files → On My iPhone → Hassy Natural → Originals. Save creates an edited copy in Photos.")
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
