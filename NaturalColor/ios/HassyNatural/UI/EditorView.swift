import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var comparing = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = comparing ? model.originalPreview : model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(false)
                        .accessibilityLabel(comparing ? "Original photo" : "Edited photo")
                        .accessibilityIdentifier("editorPreview")
                }
                Text(comparing ? "ORIGINAL" : "NATURAL")
                    .font(.caption2.weight(.bold)).tracking(2)
                    .padding(10).background(.black.opacity(0.65), in: Capsule())
                    .padding(16)
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in comparing = true }.onEnded { _ in comparing = false })
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.photo?.name ?? "Photo").font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(model.photo?.dimensions ?? "") · \(model.photo?.isRaw == true ? "RAW decoded" : "Rendered image")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    Button { comparing.toggle() } label: { Image(systemName: "square.on.square") }
                        .accessibilityLabel("Compare original")
                        .accessibilityValue(comparing ? "Original" : "Edited")
                        .accessibilityIdentifier("compareButton")
                }
                VStack(spacing: 5) {
                    HStack { Text("Strength"); Spacer(); Text("\(Int(model.settings.strength * 100))% ").monospacedDigit() }
                    Slider(value: $model.settings.strength, in: 0...1)
                        .accessibilityLabel("Strength").accessibilityIdentifier("strengthSlider")
                }
                VStack(spacing: 5) {
                    HStack { Text("Exposure"); Spacer(); Text(String(format: "%+.1f EV", model.settings.exposure)).monospacedDigit() }
                    Slider(value: $model.settings.exposure, in: -2...2, step: 0.05)
                        .accessibilityLabel("Exposure").accessibilityIdentifier("exposureSlider")
                }
                HStack(spacing: 16) {
                    Button("Reset") { comparing = false; model.reset() }.accessibilityIdentifier("resetButton")
                    Spacer()
                    Button { Task { await model.export(saveToPhotos: false) } } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("shareButton")
                    Button { Task { await model.export(saveToPhotos: true) } } label: {
                        Label("Save", systemImage: "arrow.down.to.line")
                    }.buttonStyle(.borderedProminent).foregroundStyle(.black).accessibilityIdentifier("saveButton")
                }
                .disabled(model.exporting || model.busy)
                if model.exporting { ProgressView("Rendering full resolution…").font(.caption) }
                Text("Hold the photo to compare with the original.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(20)
            .background(Color(white: 0.075))
        }
        .onChange(of: model.settings) { _, _ in model.updatePreview() }
    }
}
