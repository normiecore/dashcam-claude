import SwiftUI
import DashcamCore

/// First-run consent screen, presented full screen by RootView until the user taps Continue.
struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var coordinator: RecordingCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                OnboardingPoint(
                    systemImage: "video.fill",
                    title: "Records while the app is open",
                    text: "Dashcam records continuously while the app is open. Recent footage rolls over when it reaches your time, storage or free-space limit. Clips you save are kept."
                )
                OnboardingPoint(
                    systemImage: "mic.fill",
                    title: "Audio is optional",
                    text: "Recording audio is optional, and you can turn it off at any time in Settings. Some places require the consent of passengers, or a notice, before audio is recorded."
                )
                OnboardingPoint(
                    systemImage: "lock.fill",
                    title: "Footage stays on this iPhone",
                    text: "Footage is stored only on this iPhone and is never uploaded. A clip leaves the phone only if you share it or save it to Photos."
                )
                OnboardingPoint(
                    systemImage: "moon.fill",
                    title: "Keep the app open",
                    text: "iOS stops the camera when the phone locks or the app leaves the foreground. Keep Dashcam open while you drive, and use Dim screen to darken the display."
                )
                OnboardingPoint(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Drive safely",
                    text: "Mount the phone where it does not block your view of the road and where local law allows. Do not interact with the app while driving."
                )

                Toggle(isOn: $settings.audioEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record audio")
                            .font(.headline)
                        Text("You can change this later in Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                settings.hasCompletedOnboarding = true
                // Auto-start is deferred until consent; begin now if it was requested.
                Task { await coordinator.onboardingCompleted() }
            } label: {
                Text("Continue")
            }
            .buttonStyle(BigButtonStyle(color: Color(red: 0.95, green: 0.94, blue: 0.90), foreground: .black))
            .accessibilityIdentifier("onboarding.continue")
            .frame(maxWidth: 600)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "car.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to Dashcam")
                .font(.largeTitle.weight(.bold))
            Text("Before you start, here is how the app works.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }
}

private struct OnboardingPoint: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
