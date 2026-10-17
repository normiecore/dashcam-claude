import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onFocus: ((CGPoint, CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { context.coordinator.onFocus = onFocus }

    final class Coordinator: NSObject {
        var onFocus: ((CGPoint, CGPoint) -> Void)?
        init(onFocus: ((CGPoint, CGPoint) -> Void)?) { self.onFocus = onFocus }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let point = gesture.location(in: view)
            onFocus?(view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point),
                CGPoint(x: point.x / view.bounds.width, y: point.y / view.bounds.height))
        }
    }
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

/// The camera stays mounted while review/import temporarily pauses its session.
struct CameraView: View {
    @StateObject private var camera: CameraService
    @ObservedObject var model: EditorModel
    let active: Bool
    let onCapture: (URL, PhotoAspectRatio, PhotoSaveMode, PhotoOutputOptions) -> Void
    let onReview: () -> Void
    let onLibrary: () -> Void
    let onFiles: () -> Void
    let onAbout: () -> Void
    @AppStorage("advancedCamera") private var advanced = false
    @AppStorage("photoAspectRatio") private var ratio: PhotoAspectRatio = .native
    @AppStorage("photoSaveModeV2") private var saveMode: PhotoSaveMode = .processed
    @AppStorage("photoFileFormat") private var fileFormat: PhotoFileFormat = .heic
    @AppStorage("photoFileQuality") private var fileQuality: PhotoFileQuality = .medium
    @State private var shotOutput = PhotoOutputOptions()
    @State private var captureAngle: CGFloat = 90
    @State private var shotRatio: PhotoAspectRatio = .native
    @State private var shotSaveMode: PhotoSaveMode = .processed
    @State private var gridVisible = false
    @State private var controls = false
    @State private var showAboutAfterControls = false
    @State private var focusPoint: CGPoint?
    @State private var focusID = UUID()

    init(model: EditorModel, active: Bool, onCapture: @escaping (URL, PhotoAspectRatio, PhotoSaveMode, PhotoOutputOptions) -> Void,
         onReview: @escaping () -> Void, onLibrary: @escaping () -> Void,
         onFiles: @escaping () -> Void, onAbout: @escaping () -> Void) {
        self.model = model; self.active = active; self.onCapture = onCapture
        self.onReview = onReview; self.onLibrary = onLibrary; self.onFiles = onFiles; self.onAbout = onAbout
        let arguments = ProcessInfo.processInfo.arguments
        _camera = StateObject(wrappedValue: CameraService(interfaceTest:
            arguments.contains("--camera-ui-testing") || arguments.contains("--camera-denied-ui-testing")))
    }

    var body: some View {
        GeometryReader { geometry in
            let framed = ratio.cropRect(in: CGRect(origin: .zero, size: camera.nativePhotoSize))
            let aspect = framed.width / max(1, framed.height)
            let availableHeight = max(180, geometry.size.height - (advanced ? 270 : 190))
            VStack(spacing: 0) {
                header.frame(height: 44)
                Spacer(minLength: 0)
                viewfinder
                    .frame(width: min(geometry.size.width, availableHeight * aspect),
                           height: min(geometry.size.width / aspect, availableHeight))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                if advanced {
                    readouts.padding(.top, 8).padding(.bottom, 6)
                    exposureScale.padding(.horizontal, 28)
                }
                captureControls.padding(.top, 6).padding(.bottom, 4)
                Text(model.savingCaptures > 0 ? "Saving to Photos…" : model.captureStatus)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 8)
            }
            .background(.black)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraScreen")
        .task(id: active) {
            camera.onCapture = { url in onCapture(url, shotRatio, shotSaveMode, shotOutput) }
            if active { await camera.start() } else { camera.stop() }
        }
        .onDisappear { camera.stop(); UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            captureAngle = CaptureOrientation.angle(for: UIDevice.current.orientation, previous: captureAngle)
        }
        .onChange(of: camera.ready) { _, ready in
            if ready && !advanced { camera.setExposureBias(0) }
        }
        .onChange(of: advanced) { _, enabled in
            if !enabled { camera.setExposureBias(0) }
        }
        .task(id: focusID) {
            try? await Task.sleep(for: .milliseconds(1400))
            if !Task.isCancelled { withAnimation { focusPoint = nil } }
        }
        .sheet(isPresented: $controls, onDismiss: {
            if showAboutAfterControls { showAboutAfterControls = false; onAbout() }
        }) { controlScreen }
        .alert("Unable to capture", isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(camera.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NATURAL").font(.system(size: 14, weight: .semibold)).tracking(3)
                Text("PHOTO").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(CameraTheme.accent)
            }
            Spacer()
            if advanced {
            Text(saveMode != .processed && camera.supportsRaw ? "RAW" : fileFormat.label)
                .font(.system(size: 11, weight: .semibold)).tracking(1)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Capture format")
                .accessibilityValue(saveMode != .processed && camera.supportsRaw ? "RAW" : fileFormat.label)
                .accessibilityIdentifier("captureFormat")
            Button { gridVisible.toggle() } label: {
                Image(systemName: "viewfinder").foregroundStyle(gridVisible ? CameraTheme.accent : .white)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Composition grid").accessibilityValue(gridVisible ? "On" : "Off")
            .accessibilityIdentifier("cameraGrid")
            }
            Menu {
                ForEach(PhotoAspectRatio.allCases) { option in
                    Button { ratio = option } label: {
                        Label(option.rawValue, systemImage: ratio == option ? "checkmark" : "crop")
                    }
                }
            } label: {
                Text(ratio.rawValue.uppercased()).font(.system(size: 11, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Photo aspect ratio").accessibilityValue(ratio.rawValue).accessibilityIdentifier("cameraRatio")
            Button { controls = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Camera controls").accessibilityIdentifier("cameraControls")
        }
        .foregroundStyle(.white).padding(.horizontal, 12)
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.09)
                if camera.isInterfaceTest && camera.ready {
                    LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.2), Color(white: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text("INTERFACE PREVIEW").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(.white.opacity(0.4))
                } else {
                    CameraPreview(session: camera.session) { devicePoint, screenPoint in
                        camera.focus(at: devicePoint)
                        focusPoint = screenPoint; focusID = UUID()
                    }
                }
                if advanced && gridVisible {
                    ThirdsGrid().stroke(.white.opacity(0.3), lineWidth: 0.5).allowsHitTesting(false)
                }
                if let point = focusPoint {
                    FocusCorners().stroke(CameraTheme.accent, lineWidth: 1.5)
                        .frame(width: 64, height: 64)
                        .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                        .allowsHitTesting(false)
                }
                if let reason = camera.unavailableReason {
                    VStack(spacing: 12) {
                        Image(systemName: camera.permissionDenied ? "camera.fill" : "camera")
                            .font(.system(size: 30, weight: .ultraLight))
                        Text(reason).font(.headline)
                        Text(camera.permissionDenied ? "Allow access to take a photo, or import an original below." : "Open a photo from your library or Files to start editing.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if camera.permissionDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }.font(.caption.weight(.semibold)).foregroundStyle(CameraTheme.accent)
                        }
                    }.padding(30)
                } else if !camera.ready {
                    ProgressView("Starting camera…").font(.caption)
                }
                if camera.ready {
                    VStack {
                        if advanced { HStack {
                            Text(camera.focusModeLabel).font(.system(size: 10, weight: .semibold)).padding(5).background(.black.opacity(0.45))
                            Spacer()
                            Text("AWB").font(.system(size: 10, weight: .medium)).padding(5).background(.black.opacity(0.45))
                        }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(camera.lenses) { lens in
                                Button { camera.switchLens(lens.id) } label: {
                                    Text(lens.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.7)
                                        .padding(.horizontal, 15).frame(height: 32)
                                        .background(camera.selectedLens == lens.id ? CameraTheme.accent : Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(camera.selectedLens == lens.id ? .black : .white)
                                }.disabled(camera.capturing).accessibilityLabel("\(lens.title) lens")
                            }
                        }
                    }.padding(16)
                }
            }.clipped()
        }
    }

    private var readouts: some View {
        HStack(spacing: 0) {
            readout("ISO", value: camera.iso > 0 ? String(Int(camera.iso.rounded())) : "—")
            Rectangle().fill(CameraTheme.rule).frame(width: 1, height: 30)
            readout("SHUTTER", value: camera.shutterText)
            Rectangle().fill(CameraTheme.rule).frame(width: 1, height: 30)
            readout("APERTURE", value: camera.aperture > 0 ? String(format: "ƒ %.1f", camera.aperture) : "—")
        }.padding(.horizontal, 18)
    }

    private func readout(_ name: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(name).font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(.white.opacity(0.45))
            Text(value).font(.system(size: 23, weight: .light, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }

    private var exposureScale: some View {
        Button { controls = true } label: {
            HStack(spacing: 12) {
                Text("A").font(.system(size: 13, weight: .semibold)).foregroundStyle(CameraTheme.accent)
                HStack(alignment: .center, spacing: 0) {
                    ForEach(0..<25, id: \.self) { index in
                        Rectangle().fill(index == 12 ? CameraTheme.accent : .white.opacity(0.35))
                            .frame(width: 1, height: index % 6 == 0 ? 10 : 5)
                            .frame(maxWidth: .infinity)
                    }
                }.overlay(alignment: .center) {
                    GeometryReader { proxy in
                        Rectangle().fill(CameraTheme.accent).frame(width: 3, height: 13)
                            .position(x: proxy.size.width * CGFloat((min(max(camera.exposureBias, -2), 2) + 2) / 4), y: proxy.size.height / 2)
                    }
                }.frame(height: 14)
                Text(String(format: "%+.1f EV", camera.exposureBias)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }.frame(height: 44).contentShape(Rectangle())
        }.foregroundStyle(.white).accessibilityLabel("Exposure compensation").accessibilityValue(String(format: "%+.1f EV", camera.exposureBias)).accessibilityIdentifier("cameraExposureControl")
    }

    private var captureControls: some View {
        HStack(spacing: 0) {
            Button(action: model.photo == nil ? onLibrary : onReview) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(CameraTheme.panel)
                    if let image = model.preview {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else { Image(systemName: "photo.on.rectangle").font(.system(size: 22, weight: .light)) }
                    if model.busy { ProgressView().tint(.white) }
                }.frame(width: 52, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(CameraTheme.rule))
            }.frame(maxWidth: .infinity).disabled(model.busy)
                .accessibilityLabel(model.photo == nil ? "Photo library" : "Review last photo").accessibilityIdentifier("reviewCapture")
            Button {
                shotRatio = ratio; shotSaveMode = camera.supportsRaw ? saveMode : .processed
                shotOutput = .init(format: fileFormat, quality: fileQuality)
                captureAngle = CaptureOrientation.angle(for: UIDevice.current.orientation, previous: captureAngle)
                camera.capture(rawRequested: saveMode != .processed, format: fileFormat, rotationAngle: captureAngle)
            } label: {
                ZStack {
                    Circle().stroke(.white.opacity(camera.canCapture ? 1 : 0.3), lineWidth: 2).frame(width: 76, height: 76)
                    Circle().fill(.white.opacity(camera.canCapture ? 1 : 0.3)).frame(width: 62, height: 62)
                    if camera.capturing { ProgressView().tint(.black) }
                }.frame(width: 88, height: 88)
            }.disabled(!camera.canCapture).accessibilityLabel("Take photo").accessibilityIdentifier("cameraShutter")
            Menu {
                Button("Photo library", systemImage: "photo.on.rectangle", action: onLibrary).accessibilityIdentifier("openLibrary")
                Button("Import from Files", systemImage: "folder", action: onFiles).accessibilityIdentifier("openFiles")
                Button("About Natural", systemImage: "info.circle", action: onAbout)
            } label: {
                VStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .light))
                    Text("IMPORT").font(.system(size: 8, weight: .medium)).tracking(1.2)
                }.frame(width: 68, height: 60)
            }.frame(maxWidth: .infinity).accessibilityLabel("Import photo").accessibilityIdentifier("cameraImport")
        }.foregroundStyle(.white)
    }

    private var controlScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                Toggle("Advanced mode", isOn: $advanced).accessibilityIdentifier("advancedMode")
                Text(advanced ? "Live exposure readings, composition grid and capture format." : "Just frame, focus and shoot. Auto exposure handles the rest.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("File format")
                    Spacer()
                    Picker("File format", selection: $fileFormat) {
                        ForEach(PhotoFileFormat.allCases) { format in Text("\(format.rawValue) (\(format.label))").tag(format) }
                    }.labelsHidden().accessibilityLabel("File format").accessibilityIdentifier("fileFormat")
                }
                HStack {
                    Text("Photo quality")
                    Spacer()
                    Picker("Photo quality", selection: $fileQuality) {
                        ForEach(PhotoFileQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
                    }.labelsHidden().accessibilityLabel("Photo quality").accessibilityIdentifier("fileQuality")
                }
                if camera.supportsRaw {
                    Toggle("Save RAW original", isOn: Binding(get: { saveMode != .processed }, set: { saveMode = $0 ? .both : .processed }))
                        .disabled(camera.capturing).accessibilityIdentifier("saveRAW")
                } else { Text("RAW isn’t available for this camera.").font(.caption).foregroundStyle(.secondary) }
                Text("One finished photo saves to Photos. HEIC keeps files smaller; JPEG is available for compatibility. RAW adds a separate original when enabled. Quality changes compression, not pixel dimensions.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Native uses the camera’s maximum supported photo dimensions without cropping or upscaling. Standard ratios crop the processed copy only.")
                    .font(.caption).foregroundStyle(.secondary)
                if advanced {
                readouts.padding(.top, 16)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("EXPOSURE COMPENSATION").font(.system(size: 10, weight: .medium)).tracking(1)
                        Spacer()
                        Text(String(format: "%+.1f EV", camera.exposureBias)).monospacedDigit().foregroundStyle(CameraTheme.accent)
                    }
                    Slider(value: Binding(get: { camera.exposureBias }, set: { camera.setExposureBias($0) }), in: -2...2, step: 0.1)
                        .disabled(!camera.ready).accessibilityLabel("Camera exposure").accessibilityValue(String(format: "%+.1f EV", camera.exposureBias)).accessibilityIdentifier("cameraExposureSlider")
                    HStack { Text("−2"); Spacer(); Text("0"); Spacer(); Text("+2") }.font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Composition grid", isOn: $gridVisible)
                Text("ISO, shutter and aperture are live readings. Exposure compensation changes the camera’s auto exposure.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Button("About Natural") { showAboutAfterControls = true; controls = false }.font(.footnote)
                }.padding(24)
            }.background(CameraTheme.panel)
                .navigationTitle("Camera controls").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controls = false } } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
            path.move(to: CGPoint(x: rect.width * fraction, y: 0)); path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height * fraction)); path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
        }
        return path
    }
}

private struct FocusCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: rect.width, y: 0), CGPoint(x: 0, y: rect.height), CGPoint(x: rect.width, y: rect.height)] {
            let dx: CGFloat = point.x == 0 ? 1 : -1
            let dy: CGFloat = point.y == 0 ? 1 : -1
            path.move(to: CGPoint(x: point.x + dx * 12, y: point.y)); path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x, y: point.y + dy * 12))
        }
        return path
    }
}
