import AppKit
import RecorteCore
import RecorteIO
import SwiftUI
import UniformTypeIdentifiers

struct CanvasStageView: View {
    @Bindable var model: EditorModel
    let workspace: Workspace
    @Binding var zoomFactor: CGFloat
    @Binding var showTray: Bool
    let onOpenFile: () -> Void
    let onPaste: () -> Void

    @State private var isDropTargeted: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let stageSize = proxy.size
            let layout = computeCanvasLayout(in: stageSize)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .ignoresSafeArea()

                if !model.hasCanvasSurface {
                    emptyStateView
                } else {
                    ZStack {
                        // Transparency checkerboard + rendered composite image
                        CheckerboardView()
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .position(x: layout.frame.midX, y: layout.frame.midY)
                            .shadow(color: .black.opacity(0.22), radius: 14, y: 4)

                        if let rendered = model.renderedImage {
                            Image(decorative: rendered, scale: 1.0)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: layout.frame.width, height: layout.frame.height)
                                .position(x: layout.frame.midX, y: layout.frame.midY)
                        }

                        // Click-to-place for Text / Shapes tools
                        if model.activeTool == .text || model.activeTool == .shapes {
                            Color.clear
                                .contentShape(Rectangle())
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
                        } else if let selected = model.selectedLayer, !selected.isHidden {
                            SelectionOverlayView(
                                model: model,
                                layer: selected,
                                canvasFrame: layout.frame,
                                displayScale: layout.scale
                            )
                        }
                    }
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
            .coordinateSpace(name: "canvasStage")
            .onDrop(of: [.recorteTrayDocument, .fileURL, .image], isTargeted: $isDropTargeted) { providers, location in
                let canvasPt: CGPoint? = !model.hasCanvasSurface ? nil : CGPoint(
                    x: (location.x - layout.frame.minX) / max(layout.scale, 0.01),
                    y: (location.y - layout.frame.minY) / max(layout.scale, 0.01)
                )
                return handleDrop(providers: providers, canvasPoint: canvasPt)
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
    }

    private func computeCanvasLayout(in stageSize: CGSize) -> CanvasLayout {
        let docW = max(1, model.document.canvasSize.width)
        let docH = max(1, model.document.canvasSize.height)

        let leftInset: CGFloat = 76
        let rightInset: CGFloat = 28
        let topInset: CGFloat = (model.activeTool == .crop || model.activeTool == .perspective || model.activeTool == .lasso) ? 64 : 28
        let bottomInset: CGFloat = showTray ? 104 : 28

        let availW = max(80, stageSize.width - leftInset - rightInset)
        let availH = max(80, stageSize.height - topInset - bottomInset)

        let fitScale = min(availW / docW, availH / docH, 1.0)
        let effectiveScale = max(0.05, fitScale * zoomFactor)

        let renderedW = docW * effectiveScale
        let renderedH = docH * effectiveScale

        let centerX = leftInset + availW / 2.0
        let centerY = topInset + availH / 2.0

        let rect = CGRect(
            x: centerX - renderedW / 2.0,
            y: centerY - renderedH / 2.0,
            width: renderedW,
            height: renderedH
        )
        return CanvasLayout(frame: rect, scale: effectiveScale)
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
