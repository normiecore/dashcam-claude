import AVFoundation
import SwiftUI
import UIKit
import DashcamCore

/// The main recording screen. Designed to be read at a glance and operated with large targets in
/// portrait or landscape. The screen is always dark regardless of the system appearance.
struct DashcamView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The coordinator owns these messages (read-only to the UI), so dismissal is tracked locally, by
    /// banner identity: two incidents in a row produce the same text and both must be shown.
    @State private var dismissedStatus: UUID? = nil
    @State private var dismissedError: UUID? = nil

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview
            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { coordinator.refreshPermissions() }
        .onChange(of: coordinator.lastError) { _, newValue in
            if newValue == nil { dismissedError = nil }
        }
        .onChange(of: coordinator.statusMessage) { _, newValue in
            if newValue == nil { dismissedStatus = nil }
        }
    }

    // MARK: Layout

    // Layout priorities: the information area is offered everything the controls do not need, so it
    // scrolls only when it truly cannot fit; the center message gets what is left; the Spacers, at the
    // default priority, only share out the remainder.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            statusBar
            adaptiveInformation(horizontalPadding: 12)
            controls
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .background(Color.black.opacity(0.94))
        }
    }

    private var landscapeLayout: some View {
        GeometryReader { geometry in
            let controlWidth = min(max(geometry.size.width * 0.36, 236), 320)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    statusBar
                    adaptiveInformation(horizontalPadding: 8)
                }
                controls
                    .padding(12)
                    .frame(width: controlWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.black.opacity(0.94))
            }
        }
    }

    /// The camera area grows to fill large phones and becomes vertically scrollable when warnings,
    /// Dynamic Type or a short landscape screen need more room. The driving controls remain fixed and
    /// reachable at every supported iPhone size.
    private func adaptiveInformation(horizontalPadding: CGFloat) -> some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    warningsAndMessages
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 8)
                    Spacer(minLength: 12)
                    centerMessage
                        .padding(.horizontal, horizontalPadding + 4)
                    Spacer(minLength: 12)
                    if let incident = coordinator.activeIncident {
                        IncidentProgressCard(incident: incident)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            stateIndicator
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("record.state")
            Spacer(minLength: 12)
            if coordinator.isRecording && coordinator.runHasAudio && !coordinator.audioInterrupted {
                Image(systemName: "waveform")
                    .accessibilityLabel("Audio recording on")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(Color.black.opacity(0.92))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var warningsAndMessages: some View {
        VStack(spacing: 8) {
            banners
            if showsHeatWarning {
                BannerView(text: heatText, systemImage: "thermometer.high", tint: .orange)
            }
            if coordinator.isRecording, !settings.keepScreenAwake {
                BannerView(text: "Auto-Lock can stop recording", systemImage: "lock.iphone", tint: .orange)
            }
            if let storage = coordinator.storage, let tint = storageWarningTint(storage.level) {
                BannerView(
                    text: "\(formatFreeSpace(storage.availableBytes)) storage remaining",
                    systemImage: "internaldrive.fill",
                    tint: tint
                )
            }
        }
    }

    /// The HUD, banners and incident card scroll when they do not fit (accessibility text sizes, landscape
    /// on a small phone) so the controls below always stay on screen.
    private var scrollableInformation: some View {
        ViewThatFits(in: .vertical) {
            informationStack
            ScrollView(showsIndicators: false) { informationStack }
        }
    }

    private var informationStack: some View {
        VStack(spacing: 10) {
            hud
            banners
            if let incident = coordinator.activeIncident {
                IncidentProgressCard(incident: incident)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.activeIncident?.id)
        .animation(.easeInOut(duration: 0.2), value: coordinator.lastError)
        .animation(.easeInOut(duration: 0.2), value: coordinator.statusMessage)
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if coordinator.permissions.cameraGranted {
            CameraPreviewView(capture: coordinator.capture, device: coordinator.previewDevice)
                .ignoresSafeArea()
                // Hidden rather than removed while dimmed so the capture session graph never changes.
                .opacity(coordinator.isDimmed ? 0 : 1)
                .accessibilityHidden(true)
            #if DEBUG
            if coordinator.capture is SimulatedCaptureService {
                Text("Simulated camera: synthetic frames are recorded, nothing is previewed.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            #endif
        }
    }

    // MARK: HUD

    private var hud: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                stateIndicator
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("record.state")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(bufferText)
                        .font(.headline.monospacedDigit())
                        .accessibilityLabel(bufferAccessibilityText)
                    Text(configurationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            chips
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Glanceable instrument, not reading matter: cap the largest accessibility sizes here only.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder private var stateIndicator: some View {
        switch coordinator.state {
        case .recording:
            HStack(spacing: 8) {
                PulsingDot(size: 10)
                Text("Recording")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
        case .starting:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("Starting")
            }
        case .interrupted(_, let reason):
            Label {
                Text("Paused: \(reason)")
                    .lineLimit(2)
            } icon: {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.yellow)
            }
        case .stopping:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("Stopping")
            }
        case .idle:
            Label("Stopped", systemImage: "stop.circle")
        case .failed:
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.red)
        }
    }

    private var bufferTarget: TimeInterval { TimeInterval(max(1, settings.recentHistoryHours) * 3_600) }

    private var bufferText: String {
        // Retention trims whole segments, so the buffer can briefly exceed the target; show at most the target.
        let shown = min(coordinator.bufferedSeconds, bufferTarget)
        return "Buffer \(formatDuration(shown)) / \(formatDuration(bufferTarget))"
    }

    private var bufferAccessibilityText: String {
        "Buffered \(formatDuration(min(coordinator.bufferedSeconds, bufferTarget))) of \(formatDuration(bufferTarget))"
    }

    private var configurationText: String {
        guard let config = coordinator.configuration else { return settings.quality.displayName }
        let fps = coordinator.state.isActive ? coordinator.currentFrameRate : config.frameRate
        var text = "\(min(config.width, config.height))p \(fps)fps"
        if config.codec != "pending" { text += " \(config.codec)" }
        return text
    }

    // MARK: Chips

    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipContent }
            VStack(alignment: .leading, spacing: 6) { chipContent }
        }
    }

    @ViewBuilder private var chipContent: some View {
        if let storage = coordinator.storage {
            HUDChip(
                systemImage: "internaldrive",
                text: "\(formatFreeSpace(storage.availableBytes)) free",
                tint: storageTint(storage.level),
                accessibilityText: "\(formatFreeSpace(storage.availableBytes)) of storage free"
            )
        }
        if showsHeatWarning {
            HUDChip(systemImage: "thermometer.high", text: heatText, tint: .orange, accessibilityText: "Phone is hot. \(heatText)")
        }
        if showsMicOff {
            HUDChip(systemImage: "mic.slash.fill", tint: .white, accessibilityText: "Audio is not being recorded")
        }
        if coordinator.isRecordingUnplugged {
            HUDChip(systemImage: "bolt.slash.fill", text: "Not charging", tint: .orange)
        }
        if coordinator.isRecording, !settings.keepScreenAwake {
            HUDChip(systemImage: "lock.iphone", text: "Auto-Lock will stop recording", tint: .orange)
        }
    }

    private func storageTint(_ level: StorageLevel) -> Color {
        switch level {
        case .ok: return .white
        case .low: return .orange
        case .critical: return .red
        }
    }

    private func storageWarningTint(_ level: StorageLevel) -> Color? {
        switch level {
        case .ok: return nil
        case .low: return .orange
        case .critical: return .red
        }
    }

    private var showsHeatWarning: Bool {
        let hot = coordinator.thermalState == .serious || coordinator.thermalState == .critical
        let pressure = coordinator.pressureLevel
        let pressureHigh = !(pressure == AVCaptureDevice.SystemPressureState.Level.nominal
            || pressure == AVCaptureDevice.SystemPressureState.Level.fair)
        return hot || pressureHigh
    }

    private var heatText: String {
        if coordinator.state.isActive, coordinator.currentFrameRate < settings.quality.frameRate {
            return "Hot · \(coordinator.currentFrameRate) fps"
        }
        return "Hot"
    }

    private var showsMicOff: Bool {
        coordinator.audioInterrupted
            || !settings.audioEnabled
            || (coordinator.isRecording && !coordinator.runHasAudio)
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if let error = coordinator.lastError, error.id != dismissedError {
            BannerView(text: error.text, systemImage: "exclamationmark.triangle.fill", tint: .red) {
                dismissedError = error.id
            }
            .transition(.opacity)
        }
        if let status = coordinator.statusMessage, status.id != dismissedStatus {
            BannerView(text: status.text, systemImage: "info.circle.fill", tint: Color(red: 0.05, green: 0.3, blue: 0.7)) {
                dismissedStatus = status.id
            }
            .transition(.opacity)
        }
    }

    // MARK: Center

    @ViewBuilder private var centerMessage: some View {
        if coordinator.permissions.cameraDenied {
            PermissionsView(mode: .denied)
        } else if coordinator.permissions.camera == .notDetermined {
            PermissionsView(mode: .notDetermined) {
                Task { await coordinator.requestPermissions() }
            }
        } else if showsIdleHint {
            // Dropped entirely when there is no room (for example landscape with banners showing).
            ViewThatFits(in: .vertical) {
                idleHint
                Color.clear.frame(height: 0)
            }
        }
    }

    private var showsIdleHint: Bool {
        switch coordinator.state {
        case .idle, .failed: return true
        default: return false
        }
    }

    private var idleHint: some View {
        VStack(spacing: 6) {
            Text("Ready to record")
                .font(.headline)
            Text("Mount the iPhone securely and keep Dashcam open while you drive.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 440)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if canSave {
                saveButton
            }
            if coordinator.state.isActive {
                secondaryControlsLayout {
                    startStopButton
                    dimButton
                }
            } else {
                startStopButton
            }
        }
    }

    private var secondaryControlsLayout: AnyLayout {
        if isLandscape || dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(VStackLayout(spacing: 12))
        }
        return AnyLayout(HStackLayout(spacing: 12))
    }

    private var canSave: Bool {
        coordinator.state.isActive || coordinator.bufferedSeconds > 0
    }

    private var saveButton: some View {
        Button {
            // The haptic is the driver's confirmation, so it follows the outcome rather than the tap.
            Task {
                let incident = await coordinator.triggerIncident(source: .manual, note: "Save clip button")
                if incident != nil { Haptics.success() } else { Haptics.warning() }
            }
        } label: {
            Label("Save clip", systemImage: "bookmark.fill")
        }
        .buttonStyle(BigButtonStyle(color: Color(red: 0.95, green: 0.94, blue: 0.90), foreground: .black, minHeight: 64))
        .disabled(!canSave)
        .accessibilityHint("Keeps the buffered footage and the next \(settings.postRollSeconds) seconds.")
        .accessibilityIdentifier("record.saveIncident")
    }

    private var isTransitioning: Bool {
        switch coordinator.state {
        case .starting, .stopping: return true
        default: return false
        }
    }

    private var startStopButton: some View {
        let active = coordinator.state.isActive
        let title: String = active ? "Stop" : "Start recording"
        let symbol: String = active ? "stop.fill" : "record.circle"
        let color: Color = active ? Color(white: 0.16) : Color(red: 0.95, green: 0.94, blue: 0.90)
        let foreground: Color = active ? .white : .black
        return Button {
            Task { await coordinator.toggle() }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(BigButtonStyle(color: color, foreground: foreground))
        .disabled(isTransitioning || (!active && coordinator.permissions.cameraDenied))
        .accessibilityIdentifier("record.startStop")
    }

    private var dimButton: some View {
        Button {
            coordinator.isDimmed = true
        } label: {
            Label("Dim screen", systemImage: "moon.fill")
        }
        .buttonStyle(BigButtonStyle(color: Color(white: 0.16)))
        .disabled(!coordinator.isRecording)
        .accessibilityHint("Blacks out the screen while recording continues. Tap to wake.")
        .accessibilityIdentifier("record.dim")
    }
}

// MARK: - Incident progress

/// Shown while an incident is still collecting its post-roll.
struct IncidentProgressCard: View {
    let incident: Incident

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(now: context.date)
        }
    }

    private func card(now: Date) -> some View {
        let total = max(incident.windowEnd.timeIntervalSince(incident.triggerTime), 1)
        let elapsed = now.timeIntervalSince(incident.triggerTime)
        let progress = min(max(elapsed / total, 0), 1)
        let remaining = max(0, incident.windowEnd.timeIntervalSince(now))
        let countdown: String = remaining > 0 ? formatDuration(remaining) : "Finishing"
        let detail: String = remaining > 0
            ? "Saving the next \(Int(remaining.rounded(.up))) s. Keep Dashcam open."
            : "Writing the last segment…"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                Text("Saving clip")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(countdown)
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: progress)
                .tint(.orange)
            Text(detail)
                .font(.subheadline)
            Text("\(formatDuration(incident.footageDuration)) included so far")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.28)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record.incidentCard")
    }
}

// MARK: - Permissions

/// Replaces the camera preview when camera access is missing.
struct PermissionsView: View {
    enum Mode {
        case notDetermined
        case denied
    }

    let mode: Mode
    var onRequest: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: mode == .denied ? "video.slash.fill" : "video.fill")
                .font(.system(size: 44))
            Text(mode == .denied ? "Camera access is off" : "Camera access needed")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            switch mode {
            case .denied:
                Button {
                    SystemSettings.open()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(BigButtonStyle(color: .blue))
                .accessibilityIdentifier("permissions.openSettings")
            case .notDetermined:
                Button(action: onRequest) {
                    Label("Allow camera access", systemImage: "video.fill")
                }
                .buttonStyle(BigButtonStyle(color: .blue))
                .accessibilityIdentifier("permissions.allow")
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 460)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var message: String {
        switch mode {
        case .denied:
            return "Dashcam needs the camera to record the road ahead. Turn on Camera for Dashcam in Settings. Footage stays on this iPhone."
        case .notDetermined:
            return "Dashcam records the road ahead while the app is open. Recent footage rolls over automatically; clips you save remain on this iPhone."
        }
    }
}

// MARK: - Dimmed mode

/// Opaque black cover shown over the whole app while recording continues underneath.
/// Tap anywhere to wake; press and hold for one second to save a clip.
struct DimmedRecordingView: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    /// Brightness before dimming; restored on wake, when the app leaves the foreground and on disappear.
    @State private var previousBrightness: CGFloat? = nil

    var body: some View {
        ZStack {
            // The gestures live on the full-screen black layer (which extends under the safe areas) so a
            // touch anywhere, including over where the tab bar sits, wakes or saves. The tap is declared
            // before the long press so both are recognized.
            Color.black
                .ignoresSafeArea()
                .onTapGesture { wake() }
                .onLongPressGesture(minimumDuration: 1) { saveIncident() }
            // Shift the text a few points every 30 s to avoid OLED burn-in during long drives.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content
                    .offset(burnInOffset(for: context.date))
            }
            .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .onAppear { dim() }
        .onDisappear { restoreBrightness() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dim()
            } else {
                restoreBrightness()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to wake the screen.")
        .accessibilityAction { wake() }
        .accessibilityAction(named: "Save clip") { saveIncident() }
        .accessibilityIdentifier("dimmed.cover")
    }

    private var content: some View {
        VStack(spacing: 10) {
            // The recording indication stays visible at all times in dimmed mode (App Review 2.5.14),
            // and it is truthful: a paused or restarting session shows a pause mark, not REC.
            HStack(spacing: 8) {
                if coordinator.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text("REC")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text("PAUSED")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.yellow)
                }
                if coordinator.isRecording && coordinator.runHasAudio && !coordinator.audioInterrupted {
                    Text("AUDIO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(white: 0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color(white: 0.4), lineWidth: 1))
                }
            }
            Text("Recent \(formatDuration(coordinator.bufferedSeconds))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color(white: 0.45))
            if !coordinator.isRecording {
                Text(DisplayText.recorderState(coordinator.state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }
            if coordinator.activeIncident != nil {
                Label("Saving clip", systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.orange.opacity(0.85))
            }
            Spacer(minLength: 0)
            Text("Tap to wake · Hold 1 s to save clip")
                .font(.caption2)
                .foregroundStyle(Color(white: 0.3))
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func burnInOffset(for date: Date) -> CGSize {
        let offsets = [CGSize.zero, CGSize(width: 6, height: 4), CGSize(width: -5, height: 8), CGSize(width: 4, height: -3)]
        let step = Int(date.timeIntervalSinceReferenceDate / 30) % offsets.count
        return offsets[max(0, step)]
    }

    private func dim() {
        if previousBrightness == nil {
            previousBrightness = ScreenBrightness.current()
        }
        ScreenBrightness.set(0.05)
    }

    private func restoreBrightness() {
        guard let previous = previousBrightness else { return }
        ScreenBrightness.set(previous)
        previousBrightness = nil
    }

    private func wake() {
        restoreBrightness()
        coordinator.isDimmed = false
    }

    private func saveIncident() {
        Task {
            let incident = await coordinator.triggerIncident(source: .manual, note: "Dimmed screen Save clip")
            if incident != nil { Haptics.success() } else { Haptics.warning() }
        }
    }
}

// MARK: - Screen brightness

/// Reads and sets the brightness of the screen showing the app's foreground scene
/// (`UIScreen.main` is deprecated).
@MainActor
struct ScreenBrightness {
    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
        return (active ?? scenes.first)?.screen
    }

    static func current() -> CGFloat? {
        screen?.brightness
    }

    static func set(_ value: CGFloat) {
        screen?.brightness = min(max(value, 0), 1)
    }
}
