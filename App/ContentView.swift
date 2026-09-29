import SwiftUI
import AVKit
import UIKit

struct ContentView: View {
    @ObservedObject var model: DashcamModel
    @State private var showLibrary = false
    @State private var showDeveloper = false

    var body: some View {
        HStack(spacing: 20) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let service = model.service { CameraPreview(session: service.captureSession) }
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.recording ? "RECORDING" : "NOT RECORDING",
                          systemImage: model.recording ? "record.circle.fill" : "stop.circle")
                        .font(.headline).foregroundStyle(model.recording ? .red : .white)
                    Text(model.status?.message ?? "Opening saved footage…").font(.caption)
                    Text("Keep the app open and iPhone unlocked.").font(.caption2)
                }.padding(12).background(.black.opacity(0.7))
            }.clipShape(RoundedRectangle(cornerRadius: 14))

            ScrollView {
              VStack(spacing: 12) {
                HStack {
                    Text("Dashcam").font(.title2.bold())
                    Spacer()
                    Text("0.1.0 · dev 1").font(.caption2).foregroundStyle(.secondary)
                }
                Text("5 min before · 30 sec after").font(.caption).foregroundStyle(.secondary)
                Button { model.saveIncident() } label: {
                    Label("Save Incident", systemImage: "shield.lefthalf.filled")
                        .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 70)
                }.buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(!model.recording || model.busy)
                    .accessibilityIdentifier("saveIncident")
                Button { model.toggleRecording() } label: {
                    Label(model.starting ? "Cancel starting" : (model.recording ? "Stop recording" : "Start recording"),
                          systemImage: model.recording || model.starting ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }.buttonStyle(.borderedProminent).tint(model.recording ? .red : .blue)
                    .disabled(model.service == nil || (model.busy && !model.starting))
                    .accessibilityIdentifier("toggleRecording")
                Toggle("Record microphone", isOn: $model.audioEnabled)
                    .font(.caption).disabled(model.recording || model.busy)
                Button { showLibrary = true } label: {
                    Label("Saved incidents (\(model.incidents.count))", systemImage: "film.stack")
                }.disabled(!model.canBrowse)
                if model.recording { Text("Stop to review or export footage.").font(.caption2).foregroundStyle(.secondary) }
                if let status = model.status {
                    Text("\(ByteCountFormatter.string(fromByteCount: status.snapshot.totalBytes, countStyle: .file)) stored · \(status.droppedFrames) dropped frames")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !status.snapshot.recoveryMessages.isEmpty {
                        Text("Recovery items retained: \(status.snapshot.recoveryMessages.count)")
                            .font(.caption2).foregroundStyle(.yellow)
                    }
                }
                if model.busy { ProgressView().controlSize(.small) }
                #if DEBUG
                Button("Developer tools") { showDeveloper = true }.font(.caption2)
                #endif
              }
            }.frame(width: 275)
        }
        .padding(16)
        .sheet(isPresented: $showLibrary) { IncidentLibrary(model: model) }
        .sheet(isPresented: $showDeveloper) { developerPanel }
        .alert("Dashcam", isPresented: Binding(get: { !showLibrary && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var developerPanel: some View {
        #if DEBUG
        NavigationStack {
            Form {
                Section("Incident pipeline") {
                    Text("Simulation saves real recorded footage. It does not test Apple Crash Detection.")
                    Button("Simulate Crash — save incident") {
                        if let service = model.service { DeveloperSimulation.incident(on: service) }
                    }.disabled(!model.recording || model.busy).accessibilityIdentifier("simulateCrash")
                    Button("Simulate recording interruption") {
                        if let service = model.service { DeveloperSimulation.interruption(on: service) }
                    }.disabled(!model.recording || model.busy)
                }
                Section("Recovery") {
                    ForEach(Array((model.status?.snapshot.recoveryMessages ?? []).enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption)
                    }
                    Text("For forced termination, use Xcode Stop while recording, then relaunch. Run physical interruption tests separately.")
                }
            }.navigationTitle("Developer tools")
                .toolbar { Button("Done") { showDeveloper = false } }
        }
        #else
        EmptyView()
        #endif
    }
}

private struct IncidentLibrary: View {
    @ObservedObject var model: DashcamModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: IncidentRecord?
    @State private var deleting: IncidentRecord?

    var body: some View {
        NavigationStack {
            List {
                if model.incidents.isEmpty { Text("No incidents saved yet.") }
                ForEach(model.incidents) { incident in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(incident.createdAt, format: .dateTime.day().month().hour().minute().second()).font(.headline)
                        Text("\(incident.source.rawValue.capitalized) · \(incident.state.rawValue.capitalized)").font(.caption)
                        if let note = incident.note { Text(note).font(.caption).foregroundStyle(.yellow) }
                        HStack {
                            Button("Play segments") { selected = incident }
                            Spacer()
                            Button("Export & share") { model.export(incident) }
                            Spacer()
                            Button("Delete", role: .destructive) { deleting = incident }
                        }.buttonStyle(.borderless).disabled(!model.canBrowse || incident.state == .collecting)
                    }.padding(.vertical, 6)
                }
                if !(model.status?.snapshot.recoveryMessages.isEmpty ?? true) {
                    Section("Recovery items retained") {
                        Text("Some footage may need recovery. It will not be automatically deleted. Download the app container in Xcode before making repairs.")
                        ForEach(Array((model.status?.snapshot.recoveryMessages ?? []).enumerated()), id: \.offset) { item in
                            Text(item.element).font(.caption)
                        }
                    }
                }
            }.navigationTitle("Saved incidents")
                .toolbar { Button("Done") { dismiss() }.disabled(model.exporting) }
                .overlay { if model.exporting { ProgressView("Combining footage…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) } }
                .sheet(item: $selected) { IncidentPlayer(incident: $0, model: model) }
                .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { if !$0 { model.dismissExport() } })) {
                    if let url = model.exportURL { ShareSheet(url: url) }
                }
                .confirmationDialog("Delete this incident's protection? Its footage may then be removed by storage cleanup.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Delete incident", role: .destructive) { if let deleting { model.deleteIncident(deleting) }; deleting = nil }
                }
                .interactiveDismissDisabled(model.exporting)
                .alert("Dashcam", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("OK") { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }
}

private struct IncidentPlayer: View {
    let incident: IncidentRecord
    @ObservedObject var model: DashcamModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVQueuePlayer?
    @State private var message: String?
    @State private var loading = true
    @State private var visible = true

    var body: some View {
        NavigationStack {
            VStack {
                if let player { VideoPlayer(player: player) }
                else if loading { ProgressView("Loading protected segments…") }
                if let message { Text(message).padding() }
                if let note = incident.note { Text(note).font(.caption).foregroundStyle(.yellow) }
                Text("Plays retained segments in order. Missing time between segments is not reconstructed.")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }.navigationTitle("Incident footage")
                .toolbar { Button("Done") { dismiss() } }
        }
        .onAppear {
            visible = true
            model.service?.incidentSegmentURLs(id: incident.id) { result in
                guard visible else { return }
                loading = false
                switch result {
                case .success(let urls):
                    if urls.isEmpty { message = "No finalized footage is available." }
                    else {
                        player = AVQueuePlayer(items: urls.map { AVPlayerItem(url: $0) })
                        player?.play()
                    }
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
        .onDisappear { visible = false; player?.pause(); player?.removeAllItems(); player = nil }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.preview.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }
}
