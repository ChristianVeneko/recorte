import AppKit
import CoreGraphics
import RecorteCore
import RecorteIO
import SwiftUI

struct ContextualInspectorView: View {
    @Bindable var model: EditorModel

    @State private var stickerTab: StickerPickerTab = .emoji
    @State private var selectedEmojiCategory: String = StickerCatalog.emojiCategories.first?.name ?? "Reactions"
    @State private var filterThumbnails: [FilterPreset: CGImage] = [:]
    @State private var filterThumbnailSourceID: ObjectIdentifier?

    private static let systemFontFamilies: [String] = {
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        return families.isEmpty ? ["Helvetica Neue", "SF Pro", "Avenir Next", "Georgia", "Menlo"] : families
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let layer = model.selectedLayer,
                   model.activeTool != .crop && model.activeTool != .perspective {
                    layerOpacitySection(for: layer)
                    Divider()
                }

                contextualPrimarySection

                if let layer = model.selectedLayer,
                   model.activeTool != .crop && model.activeTool != .perspective {
                    Divider()
                    transformSection(for: layer)
                }

                Divider()
                canvasSection
            }
            .padding(14)
        }
        .frame(minWidth: 250, idealWidth: 280)
        .onChange(of: selectedImageIdentifier) { _, _ in
            regenerateFilterThumbnails()
        }
        .onAppear {
            regenerateFilterThumbnails()
        }
    }

    private var selectedImageIdentifier: ObjectIdentifier? {
        guard let layer = model.selectedLayer else { return nil }
        switch layer.kind {
        case .image(let img):
            return ObjectIdentifier(img.cgImage)
        case .text, .shape, .sticker, .drawing:
            return nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private var contextualPrimarySection: some View {
        switch model.activeTool {
        case .crop:
            cropInspectorSection
        case .lasso:
            lassoInspectorSection
        case .perspective:
            perspectiveInspectorSection
        case .clone:
            cloneInspectorSection
        case .deform:
            deformInspectorSection
        case .draw:
            drawInspectorSection
        case .text:
            textInspectorSection
        case .shapes:
            shapesInspectorSection
        case .stickers:
            stickersInspectorSection
        case .move, .eraser:
            selectedLayerInspectorSection
        }
    }

    @ViewBuilder
    private var selectedLayerInspectorSection: some View {
        if let layer = model.selectedLayer {
            switch layer.kind {
            case .image(let sendableImg):
                filtersAndAdjustmentsSection(layer: layer, image: sendableImg)
            case .text:
                textInspectorSection
            case .shape:
                shapesInspectorSection
            case .sticker:
                stickersInspectorSection
            case .drawing:
                drawInspectorSection
            default:
                inspectorHeader("Layer", systemImage: "square.stack.3d.up")
                Text("Select a tool or adjust transform properties below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            inspectorHeader("Inspector", systemImage: "slider.horizontal.3")
            Text("Paste an image (⌘V) or select a layer to inspect its properties.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - S15: Lasso, Perspective, Clone Stamp, Deform Inspectors

    @ViewBuilder
    private var lassoInspectorSection: some View {
        inspectorHeader("Lasso Cutout", systemImage: "lasso")

        VStack(alignment: .leading, spacing: 10) {
            Text("Drag freehand on the canvas to trace a cutout region, then click Cut Out (or press Return).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Crop to Cutout Bounds", isOn: $model.lassoCropToBounds)

            HStack(spacing: 8) {
                Button("Clear") {
                    model.lassoPoints = []
                }
                .disabled(model.lassoPoints.isEmpty)
                .frame(maxWidth: .infinity)

                Button("Cut Out") {
                    do {
                        try model.applyLassoCutout(
                            points: model.lassoPoints,
                            cropToBounds: model.lassoCropToBounds
                        )
                    } catch {
                        model.lastErrorMessage = "Trace a closed path on an unlocked image layer first."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.lassoPoints.count < 3)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var perspectiveInspectorSection: some View {
        inspectorHeader("Perspective", systemImage: "perspective")

        VStack(alignment: .leading, spacing: 10) {
            Text("Drag the 4 corner handles over the region to rectify, then click Apply (or press Return).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Reset Corners") {
                model.resetPerspective()
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button("Cancel") {
                    model.cancelPerspective()
                }
                .frame(maxWidth: .infinity)

                Button("Apply") {
                    do {
                        try model.applyPerspective()
                    } catch {
                        model.lastErrorMessage = "Perspective correction failed."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.perspectiveQuad == nil)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var cloneInspectorSection: some View {
        inspectorHeader("Clone Stamp", systemImage: "seal")

        VStack(alignment: .leading, spacing: 10) {
            Text("Option-click (⌥-Click) on the image to set the source point, then click or drag to paint cloned pixels.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let src = model.cloneSourcePoint {
                HStack {
                    Text("Source: \(Int(src.x.rounded())), \(Int(src.y.rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        model.cloneSourcePoint = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else {
                Label("No source set (⌥-Click image)", systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            sliderRow(
                title: "Radius",
                value: $model.cloneRadius,
                range: 4...120,
                format: "%.0f px"
            )

            sliderRow(
                title: "Softness",
                value: $model.cloneSoftness,
                range: 0...1,
                format: "%.0f%%",
                displayMultiplier: 100
            )

            sliderRow(
                title: "Opacity",
                value: $model.cloneOpacity,
                range: 0.05...1,
                format: "%.0f%%",
                displayMultiplier: 100
            )
        }
    }

    @ViewBuilder
    private var deformInspectorSection: some View {
        inspectorHeader("Deform", systemImage: "hurricane")

        VStack(alignment: .leading, spacing: 10) {
            Picker("Preset", selection: $model.deformPreset) {
                ForEach(DeformPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue.capitalized).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            sliderRow(
                title: "Radius",
                value: $model.deformRadius,
                range: 10...300,
                format: "%.0f px"
            )

            sliderRow(
                title: "Strength",
                value: $model.deformStrength,
                range: 0.1...1.0,
                format: "%.2f"
            )

            Text("Click on the image to apply the selected distortion at that point.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Crop Inspector

    @ViewBuilder
    private var cropInspectorSection: some View {
        inspectorHeader("Crop", systemImage: "crop")

        if let spec = model.cropSpec {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aspect Ratio")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Button {
                            model.updateCropAspect(aspect)
                        } label: {
                            Text(aspect.shortLabel)
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                        .tint(spec.aspect == aspect ? .accentColor : nil)
                    }
                }

                Text("Shape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(CropShapePreset.allCases) { preset in
                        Button {
                            model.updateCropShape(preset.toCropShape(current: spec.shape))
                        } label: {
                            Image(systemName: preset.systemImage)
                                .frame(maxWidth: .infinity, minHeight: 24)
                        }
                        .buttonStyle(.bordered)
                        .tint(preset.matches(spec.shape) ? .accentColor : nil)
                        .help(preset.label)
                    }
                }

                if case .roundedRect(let radius) = spec.shape {
                    sliderRow(
                        title: "Corner Radius",
                        value: Binding(
                            get: { radius },
                            set: { model.updateCropShape(.roundedRect(radius: $0)) }
                        ),
                        range: 0...160,
                        format: "%.0f px"
                    )
                }

                Divider()

                sliderRow(
                    title: "Straighten",
                    value: Binding(
                        get: { spec.rotationDegrees },
                        set: { model.setCropRotation($0) }
                    ),
                    range: -180...180,
                    format: "%.0f°"
                )

                HStack(spacing: 6) {
                    Button {
                        model.rotateCrop90(clockwise: false)
                    } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        model.rotateCrop90(clockwise: true)
                    } label: {
                        Label("Rotate Right", systemImage: "rotate.right")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        model.toggleCropFlipH()
                    } label: {
                        Label("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(spec.flipH ? .accentColor : nil)
                    Button {
                        model.toggleCropFlipV()
                    } label: {
                        Label("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(spec.flipV ? .accentColor : nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Size: \(Int(spec.rect.width.rounded())) × \(Int(spec.rect.height.rounded())) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Cancel") {
                        model.cancelCrop()
                    }
                    .frame(maxWidth: .infinity)

                    Button("Apply") {
                        try? model.applyCrop()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            Text("Open or paste an image to crop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filters, Adjustments, Frame (S17) & Tone Curve (S15) Inspector

    @ViewBuilder
    private func filtersAndAdjustmentsSection(layer: Layer, image: SendableImage) -> some View {
        inspectorHeader("Image", systemImage: "camera.filters")

        // Remove Background action
        Button {
            Task {
                await model.removeBackgroundFromSelectedLayer()
            }
        } label: {
            HStack {
                if model.isRemovingBackground {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "person.and.background.dotted")
                }
                Text(model.isRemovingBackground ? "Removing Background…" : "Remove Background")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!model.canRemoveBackground)

        // S17: Image Frame Picker
        Divider()
        imageFrameSection(layer: layer, frame: image.frame)

        Divider()

        Text("Filters")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(FilterPreset.allCases, id: \.self) { preset in
                let isSelected = image.filterPreset == preset
                Button {
                    model.setFilterPreset(preset, for: layer.id)
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let thumb = filterThumbnails[preset] {
                                Image(decorative: thumb, scale: 1.0)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(decorative: image.cgImage, scale: 1.0)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                        )

                        Text(preset.rawValue.capitalized)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }

        Divider()

        HStack {
            Text("Adjustments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !image.adjustments.isIdentity {
                Button("Reset") {
                    model.setAdjustments(Adjustments(), for: layer.id)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }

        let adj = image.adjustments
        adjustmentSlider("Brightness", value: adj.brightness, range: -0.5...0.5, format: "%.2f") { v in
            var next = adj; next.brightness = v; return next
        } layerID: { layer.id }

        adjustmentSlider("Contrast", value: adj.contrast, range: 0.25...2.5, format: "%.2f") { v in
            var next = adj; next.contrast = v; return next
        } layerID: { layer.id }

        adjustmentSlider("Saturation", value: adj.saturation, range: 0.0...2.0, format: "%.2f") { v in
            var next = adj; next.saturation = v; return next
        } layerID: { layer.id }

        adjustmentSlider("Exposure", value: adj.exposure, range: -2.0...2.0, format: "%.2f") { v in
            var next = adj; next.exposure = v; return next
        } layerID: { layer.id }

        adjustmentSlider("Warmth", value: adj.warmth, range: -1.0...1.0, format: "%.2f") { v in
            var next = adj; next.warmth = v; return next
        } layerID: { layer.id }

        adjustmentSlider("Sharpness", value: adj.sharpness, range: 0.0...2.0, format: "%.2f") { v in
            var next = adj; next.sharpness = v; return next
        } layerID: { layer.id }

        adjustmentSlider("Vignette", value: adj.vignette, range: 0.0...2.0, format: "%.2f") { v in
            var next = adj; next.vignette = v; return next
        } layerID: { layer.id }

        // S15: 5-point Tone Curve Editor
        Divider()
        ToneCurveEditorView(curve: $model.toneCurve) {
            do {
                try model.applyToneCurve(model.toneCurve, to: layer.id)
            } catch {
                model.lastErrorMessage = "Could not apply tone curve."
            }
        }
    }

    @ViewBuilder
    private func imageFrameSection(layer: Layer, frame: ImageFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frame")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(
                "Frame Style",
                selection: Binding(
                    get: { ImageFramePreset.from(frame) },
                    set: { preset in
                        model.setImageFrame(preset.defaultFrame(current: frame), for: layer.id)
                    }
                )
            ) {
                ForEach(ImageFramePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .controlSize(.small)

            switch frame {
            case .none:
                EmptyView()
            case .border(let width, let color):
                sliderRow(
                    title: "Border Width",
                    value: Binding(
                        get: { width },
                        set: { model.setImageFrame(.border(width: $0, color: color), for: layer.id, continuous: true) }
                    ),
                    range: 1...48,
                    format: "%.0f px",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Frame Border") }
                )
                ColorPicker(
                    "Border Color",
                    selection: Binding(
                        get: { color.swiftUIColor },
                        set: { model.setImageFrame(.border(width: width, color: RGBAColor(swiftUIColor: $0)), for: layer.id) }
                    )
                )
            case .roundedCorners(let radius):
                sliderRow(
                    title: "Corner Radius",
                    value: Binding(
                        get: { radius },
                        set: { model.setImageFrame(.roundedCorners(radius: $0), for: layer.id, continuous: true) }
                    ),
                    range: 0...120,
                    format: "%.0f px",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Corner Radius") }
                )
            case .polaroid(let caption, let borderColor):
                TextField(
                    "Polaroid Caption",
                    text: Binding(
                        get: { caption ?? "" },
                        set: {
                            let val = $0.isEmpty ? nil : $0
                            model.setImageFrame(.polaroid(caption: val, borderColor: borderColor), for: layer.id)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                ColorPicker(
                    "Frame Color",
                    selection: Binding(
                        get: { borderColor.swiftUIColor },
                        set: { model.setImageFrame(.polaroid(caption: caption, borderColor: RGBAColor(swiftUIColor: $0)), for: layer.id) }
                    )
                )
            case .dropShadow(let radius, let offsetX, let offsetY, let color):
                sliderRow(
                    title: "Shadow Radius",
                    value: Binding(
                        get: { radius },
                        set: {
                            model.setImageFrame(
                                .dropShadow(radius: $0, offsetX: offsetX, offsetY: offsetY, color: color),
                                for: layer.id,
                                continuous: true
                            )
                        }
                    ),
                    range: 0...48,
                    format: "%.0f px",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Drop Shadow") }
                )
                ColorPicker(
                    "Shadow Color",
                    selection: Binding(
                        get: { color.swiftUIColor },
                        set: {
                            model.setImageFrame(
                                .dropShadow(radius: radius, offsetX: offsetX, offsetY: offsetY, color: RGBAColor(swiftUIColor: $0)),
                                for: layer.id
                            )
                        }
                    )
                )
            }
        }
    }

    private func adjustmentSlider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        format: String,
        update: @escaping (Double) -> Adjustments,
        layerID: @escaping () -> UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { model.setAdjustments(update($0), for: layerID(), continuous: true) }
                ),
                in: range,
                onEditingChanged: { editing in
                    if !editing {
                        model.endContinuousEdit(actionName: "Adjust \(title)")
                    }
                }
            )
            .controlSize(.small)
        }
    }

    private func regenerateFilterThumbnails() {
        guard let layer = model.selectedLayer else {
            filterThumbnails = [:]
            filterThumbnailSourceID = nil
            return
        }
        let sourceCG: CGImage
        switch layer.kind {
        case .image(let sendableImg):
            sourceCG = sendableImg.cgImage
        case .text, .shape, .sticker, .drawing:
            filterThumbnails = [:]
            filterThumbnailSourceID = nil
            return
        default:
            filterThumbnails = [:]
            filterThumbnailSourceID = nil
            return
        }

        let objID = ObjectIdentifier(sourceCG)
        guard objID != filterThumbnailSourceID else { return }
        filterThumbnailSourceID = objID

        let downscaled = downsample(sourceCG, maxDimension: 96) ?? sourceCG
        var generated: [FilterPreset: CGImage] = [:]
        for preset in FilterPreset.allCases {
            if let filtered = try? ImageFilters.apply(to: downscaled, preset: preset) {
                generated[preset] = filtered
            }
        }
        filterThumbnails = generated
    }

    private func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(w, h))
        let targetW = max(1, Int((w * scale).rounded()))
        let targetH = max(1, Int((h * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage()
    }

    // MARK: - Text Inspector (S16: Gradient Fill + Speech Bubbles)

    @ViewBuilder
    private var textInspectorSection: some View {
        inspectorHeader("Text", systemImage: "textformat")

        let editingLayer: (UUID, TextSpec)? = {
            guard let layer = model.selectedLayer else { return nil }
            switch layer.kind {
            case .text(let spec): return (layer.id, spec)
            case .image, .shape, .sticker, .drawing: return nil
            default: return nil
            }
        }()

        let activeSpec = editingLayer?.1 ?? model.defaultTextSpec

        let updateSpec: (TextSpec, Bool) -> Void = { newSpec, continuous in
            model.defaultTextSpec = newSpec
            if let (layerID, _) = editingLayer {
                model.updateTextSpec(newSpec, for: layerID, continuous: continuous)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            if model.activeTool == .text {
                Button {
                    model.addTextLayer(model.defaultTextSpec)
                } label: {
                    Label("Add Text Layer", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            TextField(
                "Text",
                text: Binding(
                    get: { activeSpec.string },
                    set: {
                        var next = activeSpec
                        next.string = $0
                        updateSpec(next, false)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Picker(
                "Font",
                selection: Binding(
                    get: { activeSpec.fontName },
                    set: {
                        var next = activeSpec
                        next.fontName = $0
                        updateSpec(next, false)
                    }
                )
            ) {
                if !Self.systemFontFamilies.contains(activeSpec.fontName) {
                    Text(activeSpec.fontName).tag(activeSpec.fontName)
                }
                ForEach(Self.systemFontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .controlSize(.small)

            sliderRow(
                title: "Size",
                value: Binding(
                    get: { activeSpec.size },
                    set: {
                        var next = activeSpec
                        next.size = $0
                        updateSpec(next, true)
                    }
                ),
                range: 10...180,
                format: "%.0f pt",
                onEnd: { model.endContinuousEdit(actionName: "Resize Text") }
            )

            // S16: Solid Color or Gradient Fill
            Toggle(
                "Gradient Fill",
                isOn: Binding(
                    get: { activeSpec.gradient != nil },
                    set: { enabled in
                        var next = activeSpec
                        next.gradient = enabled
                            ? TextGradientSpec(colors: [activeSpec.color, .yellow], angleDegrees: 0)
                            : nil
                        updateSpec(next, false)
                    }
                )
            )

            if let gradient = activeSpec.gradient {
                let startColor = gradient.colors.first ?? .red
                let endColor = gradient.colors.dropFirst().first ?? .yellow

                ColorPicker(
                    "Start Color",
                    selection: Binding(
                        get: { startColor.swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.gradient = TextGradientSpec(
                                colors: [RGBAColor(swiftUIColor: $0), endColor],
                                angleDegrees: gradient.angleDegrees
                            )
                            updateSpec(next, false)
                        }
                    )
                )

                ColorPicker(
                    "End Color",
                    selection: Binding(
                        get: { endColor.swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.gradient = TextGradientSpec(
                                colors: [startColor, RGBAColor(swiftUIColor: $0)],
                                angleDegrees: gradient.angleDegrees
                            )
                            updateSpec(next, false)
                        }
                    )
                )

                sliderRow(
                    title: "Gradient Angle",
                    value: Binding(
                        get: { gradient.angleDegrees },
                        set: {
                            var next = activeSpec
                            next.gradient = TextGradientSpec(colors: [startColor, endColor], angleDegrees: $0)
                            updateSpec(next, true)
                        }
                    ),
                    range: 0...360,
                    format: "%.0f°",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Text Gradient") }
                )
            } else {
                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { activeSpec.color.swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.color = RGBAColor(swiftUIColor: $0)
                            updateSpec(next, false)
                        }
                    )
                )
            }

            Picker(
                "Alignment",
                selection: Binding(
                    get: { activeSpec.alignment },
                    set: {
                        var next = activeSpec
                        next.alignment = $0
                        updateSpec(next, false)
                    }
                )
            ) {
                Text("Left").tag(TextAlignmentSpec.left)
                Text("Center").tag(TextAlignmentSpec.center)
                Text("Right").tag(TextAlignmentSpec.right)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            // S16: Speech Bubble Style Picker
            Divider()
            Picker(
                "Bubble Style",
                selection: Binding(
                    get: { activeSpec.bubble },
                    set: { style in
                        var next = activeSpec
                        next.bubble = style
                        if style != .none && next.bubbleColor == nil {
                            next.bubbleColor = .white
                            next.bubbleStrokeColor = .black
                            if next.color == .white && next.gradient == nil {
                                next.color = .black
                            }
                        }
                        updateSpec(next, false)
                    }
                )
            ) {
                ForEach(TextBubbleStyle.allCases, id: \.self) { style in
                    Text(style.rawValue.capitalized).tag(style)
                }
            }
            .controlSize(.small)

            if activeSpec.bubble != .none {
                ColorPicker(
                    "Bubble Fill",
                    selection: Binding(
                        get: { (activeSpec.bubbleColor ?? .white).swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.bubbleColor = RGBAColor(swiftUIColor: $0)
                            updateSpec(next, false)
                        }
                    )
                )

                ColorPicker(
                    "Bubble Stroke",
                    selection: Binding(
                        get: { (activeSpec.bubbleStrokeColor ?? .black).swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.bubbleStrokeColor = RGBAColor(swiftUIColor: $0)
                            updateSpec(next, false)
                        }
                    )
                )

                sliderRow(
                    title: "Bubble Border",
                    value: Binding(
                        get: { activeSpec.bubbleStrokeWidth },
                        set: {
                            var next = activeSpec
                            next.bubbleStrokeWidth = $0
                            updateSpec(next, true)
                        }
                    ),
                    range: 0...10,
                    format: "%.1f pt",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Bubble Border") }
                )
            }

            Divider()

            Toggle(
                "Outline",
                isOn: Binding(
                    get: { activeSpec.stroke != nil },
                    set: { enabled in
                        var next = activeSpec
                        next.stroke = enabled ? TextStrokeSpec(color: .black, width: 2.0) : nil
                        updateSpec(next, false)
                    }
                )
            )

            if let stroke = activeSpec.stroke {
                ColorPicker(
                    "Outline Color",
                    selection: Binding(
                        get: { stroke.color.swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.stroke = TextStrokeSpec(color: RGBAColor(swiftUIColor: $0), width: stroke.width)
                            updateSpec(next, false)
                        }
                    )
                )
                sliderRow(
                    title: "Outline Width",
                    value: Binding(
                        get: { stroke.width },
                        set: {
                            var next = activeSpec
                            next.stroke = TextStrokeSpec(color: stroke.color, width: $0)
                            updateSpec(next, true)
                        }
                    ),
                    range: 0.5...12,
                    format: "%.1f pt",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Text Outline") }
                )
            }

            Toggle(
                "Background Badge",
                isOn: Binding(
                    get: { activeSpec.background != nil },
                    set: { enabled in
                        var next = activeSpec
                        next.background = enabled ? RGBAColor(r: 1.0, g: 0.84, b: 0.04, a: 1.0) : nil
                        updateSpec(next, false)
                    }
                )
            )

            if let bg = activeSpec.background {
                ColorPicker(
                    "Badge Color",
                    selection: Binding(
                        get: { bg.swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.background = RGBAColor(swiftUIColor: $0)
                            updateSpec(next, false)
                        }
                    )
                )
            }
        }
    }

    // MARK: - Shapes Inspector (S17: Basic Paint Shapes incl. Triangle & Star)

    @ViewBuilder
    private var shapesInspectorSection: some View {
        inspectorHeader("Shapes", systemImage: "square.on.circle")

        let editingLayer: (UUID, ShapeSpec)? = {
            guard let layer = model.selectedLayer else { return nil }
            switch layer.kind {
            case .shape(let spec): return (layer.id, spec)
            case .image, .text, .sticker, .drawing: return nil
            default: return nil
            }
        }()

        let activeSpec = editingLayer?.1 ?? model.defaultShapeSpec

        let updateSpec: (ShapeSpec, Bool) -> Void = { newSpec, continuous in
            model.defaultShapeSpec = newSpec
            if let (layerID, _) = editingLayer {
                model.updateShapeSpec(newSpec, for: layerID, continuous: continuous)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(ShapeKindPreset.allCases) { preset in
                    Button {
                        var next = activeSpec
                        next.kind = preset.toShapeKind(current: activeSpec.kind)
                        updateSpec(next, false)
                    } label: {
                        Image(systemName: preset.systemImage)
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(.bordered)
                    .tint(preset.matches(activeSpec.kind) ? .accentColor : nil)
                    .help(preset.label)
                }
            }

            if model.activeTool == .shapes {
                Button {
                    model.addShapeLayer(model.defaultShapeSpec)
                } label: {
                    Label("Add Shape", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if case .roundedRect(let radius) = activeSpec.kind {
                sliderRow(
                    title: "Corner Radius",
                    value: Binding(
                        get: { radius },
                        set: {
                            var next = activeSpec
                            next.kind = .roundedRect(cornerRadius: $0)
                            updateSpec(next, true)
                        }
                    ),
                    range: 0...80,
                    format: "%.0f px",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Corner Radius") }
                )
            }

            Toggle(
                "Stroke",
                isOn: Binding(
                    get: { activeSpec.strokeColor != nil },
                    set: { enabled in
                        var next = activeSpec
                        next.strokeColor = enabled ? .red : nil
                        updateSpec(next, false)
                    }
                )
            )

            if let strokeColor = activeSpec.strokeColor {
                ColorPicker(
                    "Stroke Color",
                    selection: Binding(
                        get: { strokeColor.swiftUIColor },
                        set: {
                            var next = activeSpec
                            next.strokeColor = RGBAColor(swiftUIColor: $0)
                            updateSpec(next, false)
                        }
                    )
                )
                sliderRow(
                    title: "Stroke Width",
                    value: Binding(
                        get: { activeSpec.lineWidth },
                        set: {
                            var next = activeSpec
                            next.lineWidth = $0
                            updateSpec(next, true)
                        }
                    ),
                    range: 1...24,
                    format: "%.0f pt",
                    onEnd: { model.endContinuousEdit(actionName: "Edit Stroke Width") }
                )
            }

            if activeSpec.kind != .line && activeSpec.kind != .arrow {
                Toggle(
                    "Fill",
                    isOn: Binding(
                        get: { activeSpec.fillColor != nil },
                        set: { enabled in
                            var next = activeSpec
                            next.fillColor = enabled ? RGBAColor(r: 0.04, g: 0.42, b: 1.0, a: 0.35) : nil
                            updateSpec(next, false)
                        }
                    )
                )

                if let fillColor = activeSpec.fillColor {
                    ColorPicker(
                        "Fill Color",
                        selection: Binding(
                            get: { fillColor.swiftUIColor },
                            set: {
                                var next = activeSpec
                                next.fillColor = RGBAColor(swiftUIColor: $0)
                                updateSpec(next, false)
                            }
                        )
                    )
                }
            }

            sliderRow(
                title: "Width",
                value: Binding(
                    get: { Double(activeSpec.size.width) },
                    set: {
                        var next = activeSpec
                        next.size.width = CGFloat($0)
                        updateSpec(next, true)
                    }
                ),
                range: 24...800,
                format: "%.0f px",
                onEnd: { model.endContinuousEdit(actionName: "Resize Shape") }
            )

            sliderRow(
                title: "Height",
                value: Binding(
                    get: { Double(activeSpec.size.height) },
                    set: {
                        var next = activeSpec
                        next.size.height = CGFloat($0)
                        updateSpec(next, true)
                    }
                ),
                range: 24...800,
                format: "%.0f px",
                onEnd: { model.endContinuousEdit(actionName: "Resize Shape") }
            )
        }
    }

    // MARK: - Stickers Inspector (StickerCatalog)

    @ViewBuilder
    private var stickersInspectorSection: some View {
        inspectorHeader("Stickers", systemImage: "face.smiling")

        let editingSticker: (UUID, StickerSpec)? = {
            guard let layer = model.selectedLayer else { return nil }
            switch layer.kind {
            case .sticker(let spec): return (layer.id, spec)
            case .image, .text, .shape, .drawing: return nil
            default: return nil
            }
        }()

        let activeStickerBackground: RGBAColor? = {
            if let (layerID, _) = editingSticker {
                return model.stickerBackground(for: layerID)
            }
            return model.defaultStickerBackground
        }()

        let isEditingSFSymbol: Bool = {
            if let (_, spec) = editingSticker, case .sfSymbol = spec.content {
                return true
            }
            return false
        }()

        VStack(alignment: .leading, spacing: 10) {
            Picker("Type", selection: $stickerTab) {
                Text("Emoji").tag(StickerPickerTab.emoji)
                Text("Symbols").tag(StickerPickerTab.sfSymbols)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            sliderRow(
                title: "Size",
                value: Binding(
                    get: { editingSticker?.1.pointSize ?? model.defaultStickerPointSize },
                    set: { newSize in
                        model.defaultStickerPointSize = newSize
                        if let (layerID, existing) = editingSticker {
                            var next = existing
                            next.pointSize = newSize
                            model.updateStickerSpec(next, for: layerID, continuous: true)
                        }
                    }
                ),
                range: 24...200,
                format: "%.0f pt",
                onEnd: { model.endContinuousEdit(actionName: "Resize Sticker") }
            )

            // S21: Solid background badge for stickers (applies live to selected sticker and default for new stickers)
            Toggle(
                "Solid Background",
                isOn: Binding(
                    get: { activeStickerBackground != nil },
                    set: { enabled in
                        let newColor: RGBAColor? = enabled ? model.lastSolidStickerBackgroundColor : nil
                        model.defaultStickerBackground = newColor
                        if let (layerID, _) = editingSticker {
                            model.setStickerBackground(newColor, for: layerID)
                        }
                    }
                )
            )

            if let bgColor = activeStickerBackground {
                ColorPicker(
                    "Background Color",
                    selection: Binding(
                        get: { bgColor.swiftUIColor },
                        set: { newColor in
                            let rgba = RGBAColor(swiftUIColor: newColor)
                            model.lastSolidStickerBackgroundColor = rgba
                            model.defaultStickerBackground = rgba
                            if let (layerID, _) = editingSticker {
                                model.setStickerBackground(rgba, for: layerID)
                            }
                        }
                    )
                )
            }

            if stickerTab == .sfSymbols || isEditingSFSymbol {
                ColorPicker(
                    "Tint",
                    selection: Binding(
                        get: { (editingSticker?.1.tintColor ?? model.defaultStickerTint).swiftUIColor },
                        set: { newColor in
                            let rgba = RGBAColor(swiftUIColor: newColor)
                            model.defaultStickerTint = rgba
                            if let (layerID, existing) = editingSticker {
                                var next = existing
                                next.tintColor = rgba
                                model.updateStickerSpec(next, for: layerID)
                            }
                        }
                    )
                )
            }

            if stickerTab == .sfSymbols {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(StickerCatalog.sfSymbols, id: \.self) { symbol in
                        let displayName = StickerDisplayName.humanName(for: symbol)
                        Button {
                            model.addStickerLayer(
                                .sfSymbol(symbol, pointSize: model.defaultStickerPointSize, tintColor: model.defaultStickerTint),
                                background: model.defaultStickerBackground
                            )
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .help(displayName)
                        .accessibilityLabel(displayName)
                    }
                }
            } else {
                Picker("Category", selection: $selectedEmojiCategory) {
                    ForEach(StickerCatalog.emojiCategories) { category in
                        Text(category.name).tag(category.name)
                    }
                }
                .controlSize(.small)

                let emojis = StickerCatalog.emojisByCategory[selectedEmojiCategory] ?? StickerCatalog.allEmojis
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            model.addStickerLayer(
                                .emoji(emoji, pointSize: model.defaultStickerPointSize),
                                background: model.defaultStickerBackground
                            )
                        } label: {
                            Text(emoji)
                                .font(.title2)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - Draw Inspector (S17: Brush / Marker / Highlighter)

    @ViewBuilder
    private var drawInspectorSection: some View {
        inspectorHeader("Draw", systemImage: "paintbrush.pointed")

        VStack(alignment: .leading, spacing: 10) {
            Picker("Tool", selection: $model.drawingToolKind) {
                Text("Brush").tag(DrawingToolKind.brush)
                Text("Marker").tag(DrawingToolKind.marker)
                Text("Highlighter").tag(DrawingToolKind.highlighter)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            ColorPicker(
                "Color",
                selection: Binding(
                    get: { model.brushColor.swiftUIColor },
                    set: { model.brushColor = RGBAColor(swiftUIColor: $0) }
                )
            )

            sliderRow(
                title: "Line Width",
                value: $model.brushLineWidth,
                range: 1...64,
                format: "%.0f px"
            )

            HStack(spacing: 8) {
                ForEach(
                    [RGBAColor.red, .yellow, .green, .blue, .white, .black],
                    id: \.self
                ) { swatch in
                    Button {
                        model.brushColor = swatch
                    } label: {
                        Circle()
                            .fill(swatch.swiftUIColor)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        model.brushColor == swatch ? Color.accentColor : Color.secondary.opacity(0.4),
                                        lineWidth: model.brushColor == swatch ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Drag on the canvas to paint strokes with \(model.drawingToolKind.rawValue).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - S22 Layer Opacity (Top of Inspector)

    @ViewBuilder
    private func layerOpacitySection(for layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(layer.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("Opacity")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { layer.opacity },
                        set: { model.setOpacity(id: layer.id, opacity: $0, continuous: true) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            model.endContinuousEdit(actionName: "Change Opacity")
                        }
                    }
                )
                .controlSize(.small)
                .accessibilityLabel("Layer Opacity")
            }
        }
    }

    // MARK: - Layer Transform & Canvas

    @ViewBuilder
    private func transformSection(for layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("X: \(Int(layer.transform.position.x.rounded()))")
                Text("Y: \(Int(layer.transform.position.y.rounded()))")
                Spacer()
                Button("Reset") {
                    model.setLayerTransform(
                        id: layer.id,
                        transform: LayerTransform(position: model.canvasCenter),
                        actionName: "Reset Transform"
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(layer.isLocked)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            sliderRow(
                title: "Scale",
                value: Binding(
                    get: { Double(layer.transform.scale.width) },
                    set: { newScale in
                        var next = layer.transform
                        next.scale = CGSize(width: newScale, height: newScale)
                        model.setLayerTransform(id: layer.id, transform: next, continuous: true, actionName: "Scale Layer")
                    }
                ),
                range: 0.1...4.0,
                format: "%.2f×",
                disabled: layer.isLocked,
                onEnd: { model.endContinuousEdit(actionName: "Scale Layer") }
            )

            sliderRow(
                title: "Rotation",
                value: Binding(
                    get: { layer.transform.rotationDegrees },
                    set: { newDeg in
                        var next = layer.transform
                        next.rotationDegrees = newDeg
                        model.setLayerTransform(id: layer.id, transform: next, continuous: true, actionName: "Rotate Layer")
                    }
                ),
                range: -180...180,
                format: "%.0f°",
                disabled: layer.isLocked,
                onEnd: { model.endContinuousEdit(actionName: "Rotate Layer") }
            )
        }
    }

    @ViewBuilder
    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Canvas")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(Int(model.document.canvasSize.width.rounded())) × \(Int(model.document.canvasSize.height.rounded())) px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Toggle(
                "Solid Background",
                isOn: Binding(
                    get: {
                        if case .solid = model.document.background { return true }
                        return false
                    },
                    set: { isSolid in
                        model.setCanvasBackground(isSolid ? .solid(model.lastSolidCanvasBackgroundColor) : .transparent)
                    }
                )
            )

            if case .solid(let bgColor) = model.document.background {
                ColorPicker(
                    "Background Color",
                    selection: Binding(
                        get: { bgColor.swiftUIColor },
                        set: { model.setCanvasBackground(.solid(RGBAColor(swiftUIColor: $0))) }
                    )
                )
            }
        }
    }

    // MARK: - Helpers

    private func inspectorHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        displayMultiplier: Double = 1.0,
        disabled: Bool = false,
        onEnd: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue * displayMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: range,
                onEditingChanged: { editing in
                    if !editing {
                        onEnd?()
                    }
                }
            )
            .controlSize(.small)
            .disabled(disabled)
        }
    }
}

private enum StickerPickerTab {
    case emoji
    case sfSymbols
}

private enum ImageFramePreset: String, CaseIterable, Identifiable {
    case none
    case border
    case roundedCorners
    case polaroid
    case dropShadow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .border: "Border"
        case .roundedCorners: "Rounded Corners"
        case .polaroid: "Polaroid"
        case .dropShadow: "Drop Shadow"
        }
    }

    static func from(_ frame: ImageFrame) -> ImageFramePreset {
        switch frame {
        case .none: .none
        case .border: .border
        case .roundedCorners: .roundedCorners
        case .polaroid: .polaroid
        case .dropShadow: .dropShadow
        }
    }

    func defaultFrame(current: ImageFrame) -> ImageFrame {
        switch self {
        case .none:
            return .none
        case .border:
            if case .border = current { return current }
            return .border(width: 8, color: .white)
        case .roundedCorners:
            if case .roundedCorners = current { return current }
            return .roundedCorners(radius: 20)
        case .polaroid:
            if case .polaroid = current { return current }
            return .polaroid(caption: nil, borderColor: .white)
        case .dropShadow:
            if case .dropShadow = current { return current }
            return .dropShadow(radius: 14, offsetX: 0, offsetY: 6, color: RGBAColor(r: 0, g: 0, b: 0, a: 0.45))
        }
    }
}

private enum ShapeKindPreset: String, CaseIterable, Identifiable {
    case rect
    case roundedRect
    case ellipse
    case triangle
    case star
    case line
    case arrow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rect: "Rectangle"
        case .roundedRect: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .star: "Star"
        case .line: "Line"
        case .arrow: "Arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .rect: "rectangle"
        case .roundedRect: "rectangle.roundedtop"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .star: "star"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        }
    }

    func matches(_ kind: ShapeKind) -> Bool {
        switch (self, kind) {
        case (.rect, .rect): true
        case (.roundedRect, .roundedRect): true
        case (.ellipse, .ellipse): true
        case (.triangle, .triangle): true
        case (.star, .star): true
        case (.line, .line): true
        case (.arrow, .arrow): true
        default: false
        }
    }

    func toShapeKind(current: ShapeKind) -> ShapeKind {
        switch self {
        case .rect: return .rect
        case .roundedRect:
            if case .roundedRect(let r) = current { return .roundedRect(cornerRadius: r) }
            return .roundedRect(cornerRadius: 12)
        case .ellipse: return .ellipse
        case .triangle: return .triangle
        case .star: return .star
        case .line: return .line
        case .arrow: return .arrow
        }
    }
}
