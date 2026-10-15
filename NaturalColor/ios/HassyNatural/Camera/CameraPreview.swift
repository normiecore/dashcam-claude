import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = videoPreviewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

struct CameraView: View {
    @StateObject private var camera = CameraService()
    @Environment(\.dismiss) private var dismiss
    let onCapture: (URL) -> Void

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                CameraPreview(session: camera.session).ignoresSafeArea(edges: .bottom)
                VStack(spacing: 22) {
                    if !camera.lenses.isEmpty {
                        HStack {
                            ForEach(camera.lenses) { lens in
                                Button(lens.title) { camera.switchLens(lens.id) }
                                    .font(.caption.weight(.semibold))
                                    .padding(10)
                                    .background(camera.selectedLens == lens.id ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.65), in: Capsule())
                                    .disabled(camera.capturing || !camera.ready)
                            }
                        }
                    }
                    if camera.supportsRaw {
                        Toggle("Apple ProRAW", isOn: $camera.useRaw)
                            .font(.subheadline)
                            .padding(.horizontal, 32)
                            .disabled(camera.capturing)
                    }
                    Button { camera.capture() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                            Circle().fill(.white).frame(width: 62, height: 62)
                            if camera.capturing { ProgressView().tint(.black) }
                        }
                    }
                    .accessibilityLabel("Take photo")
                    .disabled(!camera.ready || camera.capturing)
                    Text(camera.useRaw ? "DNG · Apple ProRAW" : "JPEG · full resolution")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                camera.onCapture = { url in onCapture(url); dismiss() }
                await camera.start()
            }
            .onDisappear { camera.stop() }
            .alert("Camera unavailable", isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } })) {
                Button("OK", role: .cancel) { }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } message: { Text(camera.error ?? "") }
        }
    }
}
