import AppKit
import RecorteCore
import RecorteIO
import SwiftUI
import UniformTypeIdentifiers

struct CanvasStageView: View {
    @Bindable var model: EditorModel
    let workspace: Workspace
    @Binding var showTray: Bool
    let onOpenFile: () -> Void
    let onPaste: () -> Void

    @Environment(\.displayScale) private var backingScaleFactor
    @State private var isDropTargeted: Bool = false
    @State private var pinchStartScale: CGFloat?
    @State private var pinchStartPan: CGSize?

    private var activeCanvasPointerStyle: PointerStyle? {
        if model.activeTool == .draw || model.activeTool.rawValue == "eraser" {
            return CanvasCursors.crosshairPointerStyle
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let stageSize = proxy.size
            let layout = computeCanvasLayout(in: stageSize)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard model.hasCanvasSurface, model.activeTool == .move else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            model.viewport.toggleSmartZoom(baseCenter: layout.baseCenter)
                        }
                    }

                if !model.hasCanvasSurface {
                    emptyStateView
                } else {
                    ZStack {
                        // Transparency checkerboard + rendered composite image (or 60fps live GPU transform / dirty-rect eraser preview)
                        ZStack {
                            CheckerboardView()

                            if let eraserPreview = model.liveEraserPreview {
                                liveEraserComposite(preview: eraserPreview, layout: layout)
                            } else if let preview = model.liveTransformPreview {
                                liveTransformComposite(preview: preview, layout: layout)
                            } else if let rendered = model.renderedImage {
                                Image(decorative: rendered, scale: 1.0)
                                    .resizable()
                                    .interpolation(.high)
                            }
                        }
                        .frame(width: layout.frame.width, height: layout.frame.height)
                        .clipped()
                        .background(
                            Rectangle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
                        )
                        .position(x: layout.frame.midX, y: layout.frame.midY)
                        .onTapGesture(count: 2) {
                            guard model.activeTool == .move else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                model.viewport.toggleSmartZoom(baseCenter: layout.baseCenter)
                            }
                        }

                        // Click-to-place for Text / Shapes tools
                        if model.activeTool == .text || model.activeTool == .shapes {
                            Color.clear
                                .contentShape(Rectangle())
                                .pointerStyle(CanvasCursors.crosshairPointerStyle)
                                .onTapGesture(coordinateSpace: .named("canvasStage")) { location in
                                    let canvasPt = CGPoint(
                                        x: (location.x - layout.frame.minX) / max(layout.scale, 0.01),
                                        y: (location.y - layout.frame.minY) / max(layout.scale, 0.01)
                                    )
                                    switch model.activeTool {
                                    case .text:
                                        model.addTextLayer(model.defaultTextSpec, at: canvasPt)
                                        model.activeTool = .move
                                    case .shapes:
                                        model.addShapeLayer(model.defaultShapeSpec, at: canvasPt)
                                        model.activeTool = .move
                                    default:
                                        break
                                    }
                                }
                        }

                        // Tool-specific overlays
                        if model.activeTool == .crop, let spec = model.cropSpec {
                            CropOverlayView(
                                model: model,
                                spec: spec,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if model.activeTool == .lasso {
                            LassoOverlayView(
                                model: model,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if model.activeTool == .perspective, let quad = model.perspectiveQuad {
                            PerspectiveOverlayView(
                                model: model,
                                quad: quad,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if model.activeTool == .clone {
                            CloneStampOverlayView(
                                model: model,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if model.activeTool == .deform {
                            DeformOverlayView(
                                model: model,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if model.activeTool == .draw {
                            DrawingOverlayView(
                                model: model,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if model.activeTool == .eraser {
                            EraserOverlayView(
                                model: model,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        } else if let selected = model.selectedLayer, !selected.isHidden {
                            SelectionOverlayView(
                                model: model,
                                layer: selected,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        }
                    }
                    .pointerStyle(activeCanvasPointerStyle)
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                if pinchStartScale == nil {
                                    pinchStartScale = model.viewport.effectiveScale
                                    pinchStartPan = model.viewport.panOffset
                                }
                                guard let startScale = pinchStartScale,
                                      let startPan = pinchStartPan else { return }

                                // Recompute smoothly from gesture start so pointer anchor never drifts
                                var nextViewport = model.viewport
                                nextViewport.isFitMode = false
                                nextViewport.zoomScale = startScale
                                nextViewport.panOffset = startPan
                                let targetScale = startScale * value.magnification
                                nextViewport.zoom(
                                    to: targetScale,
                                    around: value.startLocation,
                                    baseCenter: layout.baseCenter
                                )
                                model.viewport = nextViewport
                            }
                            .onEnded { _ in
                                pinchStartScale = nil
                                pinchStartPan = nil
                                updatePreviewTargetSize(for: layout)
                            }
                    )
                }

                // Drop target highlight
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                        .allowsHitTesting(false)
                }

                // Floating Liquid Glass tool dock pinned to the left edge of the canvas
                HStack {
                    GlassToolDockView(model: model)
                        .padding(.leading, 14)
                    Spacer()
                }

                // Bottom Liquid Glass tray listing open documents as draggable thumbnails
                if showTray {
                    VStack {
                        Spacer()
                        GlassDocumentTrayView(currentModel: model, workspace: workspace)
                            .padding(.bottom, 14)
                    }
                }

                // Non-intrusive error or status toast
                if let errorMessage = model.lastErrorMessage {
                    toastBanner(icon: "exclamationmark.triangle.fill", iconColor: .yellow, message: errorMessage) {
                        model.lastErrorMessage = nil
                    }
                } else if let statusMessage = model.statusMessage {
                    toastBanner(icon: "checkmark.circle.fill", iconColor: .green, message: statusMessage) {
                        model.statusMessage = nil
                    }
                }
            }
            .background(
                TrackpadGestureBridge(
                    onPan: { delta in
                        guard model.hasCanvasSurface else { return }
                        model.viewport.pan(by: delta)
                    },
                    onSmartZoom: { pointer in
                        guard model.hasCanvasSurface else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            model.viewport.toggleSmartZoom(around: pointer, baseCenter: layout.baseCenter)
                        }
                    },
                    onRotate: { deltaDegrees, phase in
                        guard model.hasCanvasSurface else { return }
                        model.handleTrackpadRotate(deltaDegrees: deltaDegrees, phase: phase)
                    }
                )
            )
            .coordinateSpace(name: "canvasStage")
            .onAppear {
                model.viewport.updateFitScale(layout.fitScale)
                updatePreviewTargetSize(for: layout)
            }
            .onChange(of: layout.fitScale) { _, newFit in
                model.viewport.updateFitScale(newFit)
            }
            .onChange(of: layout.frame.size) { _, _ in
                if pinchStartScale == nil {
                    updatePreviewTargetSize(for: layout)
                }
            }
            .onDrop(of: [.recorteTrayDocument, .fileURL, .image], isTargeted: $isDropTargeted) { providers, location in
                let canvasPt: CGPoint? = !model.hasCanvasSurface ? nil : CGPoint(
                    x: (location.x - layout.frame.minX) / max(layout.scale, 0.01),
                    y: (location.y - layout.frame.minY) / max(layout.scale, 0.01)
                )
                return handleDrop(providers: providers, canvasPoint: canvasPt)
            }
        }
    }

    private func updatePreviewTargetSize(for layout: CanvasLayout) {
        let factor = max(1.0, backingScaleFactor)
        let pixelSize = CGSize(
            width: layout.frame.width * factor,
            height: layout.frame.height * factor
        )
        model.updatePreviewTargetPixelSize(pixelSize)
    }

    @ViewBuilder
    private func liveEraserComposite(preview: LiveEraserPreview, layout: CanvasLayout) -> some View {
        let canvas = preview.canvas
        let layerW = max(1.0, canvas.imageSize.width * layout.scale)
        let layerH = max(1.0, canvas.imageSize.height * layout.scale)
        let posX = canvas.layerTransform.position.x * layout.scale
        let posY = canvas.layerTransform.position.y * layout.scale

        ZStack {
            if let underlay = preview.underlay {
                Image(decorative: underlay, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
            }

            LiveEraserLayerContainerView(canvas: canvas)
                .frame(width: layerW, height: layerH)
                .modifier(LiveEraserFrameClipModifier(frame: canvas.layerFrame, displayScale: layout.scale))
                .scaleEffect(x: canvas.layerTransform.scale.width, y: canvas.layerTransform.scale.height)
                .rotationEffect(.degrees(canvas.layerTransform.rotationDegrees))
                .opacity(canvas.layerOpacity)
                .position(x: posX, y: posY)

            if let overlay = preview.overlay {
                Image(decorative: overlay, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
            }
        }
    }

    @ViewBuilder
    private func liveTransformComposite(preview: EditorModel.LiveTransformPreview, layout: CanvasLayout) -> some View {
        let docW = max(1.0, model.document.canvasSize.width)
        let docH = max(1.0, model.document.canvasSize.height)
        let start = preview.startTransform
        let current = preview.currentTransform

        let anchor = UnitPoint(
            x: start.position.x / docW,
            y: start.position.y / docH
        )
        let dsx = abs(start.scale.width) > 0.0001 ? (current.scale.width / start.scale.width) : 1.0
        let dsy = abs(start.scale.height) > 0.0001 ? (current.scale.height / start.scale.height) : 1.0
        let deltaRot = current.rotationDegrees - start.rotationDegrees
        let deltaOffset = CGSize(
            width: (current.position.x - start.position.x) * layout.scale,
            height: (current.position.y - start.position.y) * layout.scale
        )

        ZStack {
            if let underlay = preview.split.underlay {
                Image(decorative: underlay, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
            }

            Image(decorative: preview.split.activeLayerImage, scale: 1.0)
                .resizable()
                .interpolation(.high)
                .scaleEffect(x: dsx, y: dsy, anchor: anchor)
                .rotationEffect(.degrees(deltaRot), anchor: anchor)
                .offset(deltaOffset)

            if let overlay = preview.split.overlay {
                Image(decorative: overlay, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
            }
        }
    }

    private func toastBanner(icon: String, iconColor: Color, message: String, onDismiss: @escaping () -> Void) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(message)
                    .font(.callout)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(.top, 14)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("Paste a Screenshot or Drop an Image", systemImage: "photo.badge.plus")
        } description: {
            Text("Press ⌘V to paste from your clipboard, drag image files here, or open a file or .recorte project.")
        } actions: {
            HStack(spacing: 10) {
                Button("Paste Screenshot") {
                    onPaste()
                }
                .buttonStyle(.borderedProminent)

                Button("Open…") {
                    onOpenFile()
                }
                .buttonStyle(.bordered)

                Button("New Collage…") {
                    model.isPresentingCollageSheet = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.leading, 64)
        .padding(.bottom, showTray ? 84 : 0)
    }

    private struct CanvasLayout {
        let frame: CGRect
        let scale: CGFloat
        let fitScale: CGFloat
        let baseCenter: CGPoint
    }

    private func computeCanvasLayout(in stageSize: CGSize) -> CanvasLayout {
        let docSize = model.document.canvasSize
        let leftInset: CGFloat = 76
        let rightInset: CGFloat = 28
        let topInset: CGFloat = (model.activeTool == .crop || model.activeTool == .perspective || model.activeTool == .lasso || model.activeTool == .eraser) ? 64 : 28
        let bottomInset: CGFloat = showTray ? 104 : 28

        let availW = max(80, stageSize.width - leftInset - rightInset)
        let availH = max(80, stageSize.height - topInset - bottomInset)
        let fitScale = CanvasViewport.computeFitScale(
            documentSize: docSize,
            availableSize: CGSize(width: availW, height: availH)
        )
        let baseCenter = CGPoint(x: leftInset + availW / 2.0, y: topInset + availH / 2.0)

        var resolvedViewport = model.viewport
        resolvedViewport.lastKnownFitScale = fitScale
        let effectiveScale = resolvedViewport.effectiveScale
        let rect = resolvedViewport.canvasFrame(documentSize: docSize, baseCenter: baseCenter)
        return CanvasLayout(frame: rect, scale: effectiveScale, fitScale: fitScale, baseCenter: baseCenter)
    }

    private func handleDrop(providers: [NSItemProvider], canvasPoint: CGPoint?) -> Bool {
        guard !providers.isEmpty else { return false }
        let trayTypeID = UTType.recorteTrayDocument.identifier
        let fileURLTypeID = UTType.fileURL.identifier
        for provider in providers {
            let boxedProvider = UncheckedProviderBox(provider: provider)
            if provider.hasItemConformingToTypeIdentifier(trayTypeID) {
                boxedProvider.provider.loadDataRepresentation(forTypeIdentifier: trayTypeID) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(TrayDocumentTransfer.self, from: data) else {
                        return
                    }
                    Task { @MainActor in
                        _ = model.dropImageFromTray(
                            sourceEditorID: transfer.editorID,
                            from: workspace,
                            at: canvasPoint
                        )
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(fileURLTypeID) {
                boxedProvider.provider.loadDataRepresentation(forTypeIdentifier: fileURLTypeID) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if url.pathExtension.lowercased() == RecorteProject.fileExtension {
                            do {
                                try model.loadProject(from: url)
                            } catch {
                                model.lastErrorMessage = "Could not open project \(url.lastPathComponent)."
                            }
                        } else {
                            do {
                                let imported = try ImageImporter.importFromURL(url)
                                model.importDroppedImage(imported, at: canvasPoint)
                            } catch {
                                model.lastErrorMessage = "Could not import \(url.lastPathComponent)."
                            }
                        }
                    }
                }
            } else {
                Task { @MainActor in
                    do {
                        let imported = try await ImageImporter.importFromItemProvider(boxedProvider.provider)
                        model.importDroppedImage(imported, at: canvasPoint)
                    } catch {
                        model.lastErrorMessage = "Could not import dropped image."
                    }
                }
            }
        }
        return true
    }
}

private struct LiveEraserFrameClipModifier: ViewModifier {
    let frame: ImageFrame
    let displayScale: CGFloat

    func body(content: Content) -> some View {
        if case .roundedCorners(let radius) = frame, radius > 0 {
            content.clipShape(RoundedRectangle(cornerRadius: CGFloat(radius) * displayScale, style: .continuous))
        } else {
            content
        }
    }
}

/// Isolates observation of `canvas.revision` so ONLY the active layer view updates during eraser drags,
/// avoiding re-evaluation of `CanvasStageView`, `CheckerboardView`, and glass overlays per drag event.
private struct LiveEraserLayerContainerView: View {
    let canvas: LiveEraserCanvas

    var body: some View {
        LiveEraserLayerView(canvas: canvas, revision: canvas.revision)
    }
}

private struct LiveEraserLayerView: NSViewRepresentable {
    let canvas: LiveEraserCanvas
    let revision: Int

    func makeNSView(context: Context) -> LiveEraserHostNSView {
        let view = LiveEraserHostNSView(canvas: canvas)
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ nsView: LiveEraserHostNSView, context: Context) {
        nsView.update(canvas: canvas, revision: revision)
    }
}

private final class LiveEraserHostNSView: NSView {
    private var canvas: LiveEraserCanvas
    private var lastRevision: Int = -1

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(canvas: LiveEraserCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(canvas newCanvas: LiveEraserCanvas, revision: Int) {
        if self.canvas !== newCanvas {
            self.canvas = newCanvas
            self.lastRevision = revision
            _ = newCanvas.consumePendingDirtyRect()
            needsDisplay = true
            return
        }
        guard revision != lastRevision else { return }
        lastRevision = revision

        if let dirty = newCanvas.consumePendingDirtyRect(), bounds.width > 0, bounds.height > 0 {
            let sx = bounds.width / CGFloat(max(1, newCanvas.previewWidth))
            let sy = bounds.height / CGFloat(max(1, newCanvas.previewHeight))
            let viewRect = CGRect(
                x: floor(CGFloat(dirty.minX) * sx) - 1.0,
                y: floor(CGFloat(dirty.minY) * sy) - 1.0,
                width: ceil(CGFloat(dirty.width) * sx) + 2.0,
                height: ceil(CGFloat(dirty.height) * sy) + 2.0
            ).intersection(bounds)
            if !viewRect.isNull && !viewRect.isEmpty {
                setNeedsDisplay(viewRect)
            }
        } else {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              bounds.width > 0, bounds.height > 0 else { return }

        let pw = CGFloat(max(1, canvas.previewWidth))
        let ph = CGFloat(max(1, canvas.previewHeight))
        let sx = bounds.width / pw
        let sy = bounds.height / ph

        let clipped = dirtyRect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }

        let pxMin = max(0, Int(floor(clipped.minX / sx)) - 1)
        let pxMax = min(canvas.previewWidth - 1, Int(ceil(clipped.maxX / sx)) + 1)
        let pyMin = max(0, Int(floor(clipped.minY / sy)) - 1)
        let pyMax = min(canvas.previewHeight - 1, Int(ceil(clipped.maxY / sy)) + 1)
        guard pxMin <= pxMax, pyMin <= pyMax else { return }

        let pixelRect = PixelDirtyRect(minX: pxMin, maxX: pxMax, minY: pyMin, maxY: pyMax)
        guard let tile = canvas.makeTileImage(for: pixelRect) else { return }

        let drawRect = CGRect(
            x: CGFloat(pxMin) * sx,
            y: CGFloat(pyMin) * sy,
            width: CGFloat(pixelRect.width) * sx,
            height: CGFloat(pixelRect.height) * sy
        )

        ctx.saveGState()
        ctx.clip(to: clipped)
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: drawRect.minY + drawRect.maxY)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(tile, in: drawRect)
        ctx.restoreGState()
    }
}

private struct UncheckedProviderBox: @unchecked Sendable {
    let provider: NSItemProvider
}

private struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            let light = Color(nsColor: .controlBackgroundColor)
            let dark = Color.primary.opacity(0.08)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))

            let cols = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            var darkPath = Path()
            for row in 0..<rows {
                for col in 0..<cols where (row + col).isMultiple(of: 2) {
                    darkPath.addRect(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            context.fill(darkPath, with: .color(dark))
        }
    }
}
