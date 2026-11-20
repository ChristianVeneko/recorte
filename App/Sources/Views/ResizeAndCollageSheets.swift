import RecorteCore
import RecorteIO
import SwiftUI

// MARK: - Image > Resize Sheet (S15)

struct ResizeSheetView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var widthText: String = ""
    @State private var heightText: String = ""
    @State private var keepAspect: Bool = true
    @State private var aspectRatio: Double = 1.0
    @State private var isSyncing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Image")
                .font(.headline)

            Text("Current size: \(Int(model.document.canvasSize.width.rounded())) × \(Int(model.document.canvasSize.height.rounded())) px")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Width:")
                        .gridColumnAlignment(.trailing)
                    TextField("Width", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onChange(of: widthText) { _, newValue in
                            guard keepAspect, !isSyncing, let w = Double(newValue), w >= 1, aspectRatio > 0 else { return }
                            isSyncing = true
                            heightText = "\(max(1, Int((w / aspectRatio).rounded())))"
                            isSyncing = false
                        }
                    Text("px")
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    Text("Height:")
                    TextField("Height", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onChange(of: heightText) { _, newValue in
                            guard keepAspect, !isSyncing, let h = Double(newValue), h >= 1, aspectRatio > 0 else { return }
                            isSyncing = true
                            widthText = "\(max(1, Int((h * aspectRatio).rounded())))"
                            isSyncing = false
                        }
                    Text("px")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Keep Aspect Ratio", isOn: $keepAspect)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Resize") {
                    applyResize()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(parsedSize == nil)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            let w = max(1.0, Double(model.document.canvasSize.width))
            let h = max(1.0, Double(model.document.canvasSize.height))
            aspectRatio = w / h
            widthText = "\(Int(w.rounded()))"
            heightText = "\(Int(h.rounded()))"
        }
    }

    private var parsedSize: CGSize? {
        guard let w = Double(widthText), let h = Double(heightText), w >= 1, h >= 1 else {
            return nil
        }
        return CGSize(width: w, height: h)
    }

    private func applyResize() {
        guard let target = parsedSize else { return }
        do {
            try model.resizeDocument(to: target, keepAspect: keepAspect)
            dismiss()
        } catch {
            model.lastErrorMessage = "Could not resize image."
        }
    }
}

// MARK: - File > New Collage Sheet (S18)

struct CollageSheetView: View {
    let model: EditorModel
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLayout: CollageLayout = .fourGrid
    @State private var selectedCanvasPreset: CollageCanvasPreset = .square
    @State private var spacing: Double = 12
    @State private var cornerRadius: Double = 8
    @State private var backgroundColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Collage")
                .font(.headline)

            Text("Choose a layout preset or start with a Free Style blank canvas.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(CollageLayout.allCases, id: \.self) { layout in
                        let isSelected = selectedLayout == layout
                        Button {
                            selectedLayout = layout
                        } label: {
                            VStack(spacing: 6) {
                                CollageLayoutThumbnail(layout: layout, isSelected: isSelected)
                                    .frame(height: 62)
                                Text(layout.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            }
                            .padding(6)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 230)

            Divider()

            HStack(spacing: 16) {
                Picker("Canvas", selection: $selectedCanvasPreset) {
                    ForEach(CollageCanvasPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .frame(maxWidth: 210)

                ColorPicker("Background", selection: $backgroundColor)
            }

            if selectedLayout != .freeStyle {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Spacing")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(spacing.rounded())) px")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $spacing, in: 0...40)
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Corners")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(cornerRadius.rounded())) px")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $cornerRadius, in: 0...48)
                            .controlSize(.small)
                    }
                }
            }

            HStack {
                if selectedLayout != .freeStyle && !openTabImages.isEmpty {
                    Button("Use Open Tabs (\(openTabImages.count))") {
                        buildCollage(with: openTabImages)
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if selectedLayout == .freeStyle {
                    Button("Create Blank Canvas") {
                        buildCollage(with: [])
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Choose Images (\(selectedLayout.cellCount))…") {
                        promptAndBuildCollage()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var openTabImages: [CGImage] {
        workspace.editors.compactMap { $0.renderComposite() }
    }

    private func promptAndBuildCollage() {
        ExportPanelController.presentOpenPanel(allowProjects: false) { urls in
            let images = urls.compactMap { try? ImageImporter.importFromURL($0).image }
            guard !images.isEmpty else { return }
            buildCollage(with: images)
        }
    }

    private func buildCollage(with images: [CGImage]) {
        do {
            try model.createCollage(
                layout: selectedLayout,
                images: images,
                canvasSize: selectedCanvasPreset.size,
                background: .solid(RGBAColor(swiftUIColor: backgroundColor)),
                spacing: CGFloat(spacing),
                cornerRadius: cornerRadius
            )
            dismiss()
        } catch {
            model.lastErrorMessage = "Could not create collage: \(error.localizedDescription)"
        }
    }
}

private struct CollageLayoutThumbnail: View {
    let layout: CollageLayout
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            if layout == .freeStyle {
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
                let path = Path(roundedRect: rect, cornerRadius: 5)
                context.stroke(
                    path,
                    with: .color(isSelected ? .accentColor : .secondary),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
            } else {
                let rects = layout.cellRects(in: size, spacing: 3)
                for r in rects {
                    let path = Path(roundedRect: r, cornerRadius: 2.5)
                    context.fill(path, with: .color(isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.28)))
                    context.stroke(path, with: .color(isSelected ? Color.accentColor : Color.secondary.opacity(0.5)), lineWidth: 1)
                }
            }
        }
    }
}

private enum CollageCanvasPreset: String, CaseIterable, Identifiable {
    case square
    case landscape
    case portrait
    case widescreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: "Square (1200×1200)"
        case .landscape: "Landscape (1600×1200)"
        case .portrait: "Portrait (1200×1600)"
        case .widescreen: "16:9 (1920×1080)"
        }
    }

    var size: CGSize {
        switch self {
        case .square: CGSize(width: 1200, height: 1200)
        case .landscape: CGSize(width: 1600, height: 1200)
        case .portrait: CGSize(width: 1200, height: 1600)
        case .widescreen: CGSize(width: 1920, height: 1080)
        }
    }
}

extension CollageLayout {
    var displayName: String {
        switch self {
        case .freeStyle: "Free Style"
        case .twoHorizontal: "2 Columns"
        case .twoVertical: "2 Rows"
        case .threeGrid: "3 Columns"
        case .threeMosaicLeft: "3 Mosaic Left"
        case .threeMosaicTop: "3 Mosaic Top"
        case .fourGrid: "4 Grid"
        case .fourMosaic: "4 Mosaic"
        case .fiveMosaic: "5 Mosaic"
        case .sixGrid: "6 Grid"
        case .sixMosaic: "6 Mosaic"
        }
    }
}
