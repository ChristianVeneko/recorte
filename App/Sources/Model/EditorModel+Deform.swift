import CoreGraphics
import Foundation
import Observation
import RecorteCore

/// Observable per-editor state for the liquify-style deform brush tool (S26).
@MainActor
@Observable
public final class DeformBrushState {
    public var mode: DeformBrushMode = .push
    public fileprivate(set) var isDragging: Bool = false
    public fileprivate(set) var isApplyingFullResolution: Bool = false
    public fileprivate(set) var previewUpdateCount: Int = 0

    fileprivate var activeStroke: ActiveDeformStroke?
    fileprivate var pendingCommitTask: Task<Void, Never>?

    public init() {}
}

private struct ActiveDeformStroke {
    let layerID: UUID
    let layerSnapshot: Layer
    let originalSendable: SendableImage
    let mode: DeformBrushMode
    let canvasSize: CGSize
    let canvasPreviewScale: CGFloat
    let isDirectCanvasFastPath: Bool
    let underlayPreview: CGImage?
    let overlayPreview: CGImage?
    let previewAlphaMask: CGImage?
    let compositeContext: CGContext?
    var session: DeformBrushSession
}

@MainActor
private enum DeformBrushStateRegistry {
    static let table = NSMapTable<EditorModel, DeformBrushState>.weakToStrongObjects()

    static func state(for model: EditorModel) -> DeformBrushState {
        if let existing = table.object(forKey: model) {
            return existing
        }
        let created = DeformBrushState()
        table.setObject(created, forKey: model)
        return created
    }
}

extension EditorModel {
    /// Observable state object backing deform brush mode and live stroke status.
    public var deformState: DeformBrushState {
        DeformBrushStateRegistry.state(for: self)
    }

    /// Active liquify deform brush mode (`.push`, `.bulge`, `.pinch`, `.twirl`).
    public var deformMode: DeformBrushMode {
        get { deformState.mode }
        set {
            deformState.mode = newValue
            if let preset = newValue.legacyPreset, deformPreset != preset {
                deformPreset = preset
            }
        }
    }

    /// Brush diameter in canvas pixels (`20...600`), synced directly with `deformRadius`.
    public var deformBrushSize: Double {
        get { min(max(deformRadius * 2.0, 20.0), 600.0) }
        set {
            let clampedDiameter = min(max(newValue, 20.0), 600.0)
            deformRadius = clampedDiameter * 0.5
        }
    }

    // MARK: - Interactive Liquify Brush Stroke API

    /// Starts a liquify deform brush stroke at `canvasPoint` (top-left canvas coordinates).
    /// Creates a preview-resolution working copy for smooth live feedback during dragging.
    public func beginDeformStroke(at canvasPoint: CGPoint, maxPreviewDimension: Int = 900) {
        let state = deformState
        guard !state.isApplyingFullResolution else { return }
        guard let (layer, sendableImg) = targetImageLayer() else {
            lastErrorMessage = "Deform requires an unlocked image layer."
            return
        }

        let avgScale = max(0.01, (abs(layer.transform.scale.width) + abs(layer.transform.scale.height)) / 2.0)
        let imageRadius = max(1.0, CGFloat(deformRadius) / avgScale)
        let clampedStrength = min(max(CGFloat(deformStrength), 0.0), 1.0)
        let mode = state.mode

        do {
            var session = try DeformBrushSession(
                sourceImage: sendableImg.cgImage,
                mode: mode,
                radius: imageRadius,
                strength: clampedStrength,
                maxPreviewDimension: maxPreviewDimension
            )

            let canvasSize = document.canvasSize
            let longestCanvas = max(canvasSize.width, canvasSize.height)
            let canvasPreviewScale: CGFloat = longestCanvas > CGFloat(maxPreviewDimension)
                ? CGFloat(maxPreviewDimension) / longestCanvas
                : 1.0

            let isDirectFastPath = canUseDirectPreviewFastPath(
                layer: layer,
                image: sendableImg,
                canvasSize: canvasSize
            )

            var underlayPreview: CGImage?
            var overlayPreview: CGImage?
            var previewAlphaMask: CGImage?
            var compositeContext: CGContext?

            if !isDirectFastPath {
                if let activeIndex = document.layers.firstIndex(where: { $0.id == layer.id }) {
                    let belowLayers = Array(document.layers[..<activeIndex])
                    let aboveLayers = activeIndex + 1 < document.layers.count
                        ? Array(document.layers[(activeIndex + 1)...])
                        : []

                    if !belowLayers.isEmpty || document.background != .transparent {
                        let underlayDoc = EditorDocument(
                            canvasSize: canvasSize,
                            background: document.background,
                            layers: belowLayers,
                            selection: nil
                        )
                        underlayPreview = try? DocumentRenderer.render(underlayDoc, scale: canvasPreviewScale)
                    }

                    if !aboveLayers.isEmpty {
                        let overlayDoc = EditorDocument(
                            canvasSize: canvasSize,
                            background: .transparent,
                            layers: aboveLayers,
                            selection: nil
                        )
                        overlayPreview = try? DocumentRenderer.render(overlayDoc, scale: canvasPreviewScale)
                    }
                }

                if let alphaMask = sendableImg.alphaMask {
                    previewAlphaMask = downsampleGrayscaleMask(
                        alphaMask,
                        width: Int(session.previewSize.width),
                        height: Int(session.previewSize.height)
                    )
                }

                let previewCanvasW = max(1, Int((canvasSize.width * canvasPreviewScale).rounded()))
                let previewCanvasH = max(1, Int((canvasSize.height * canvasPreviewScale).rounded()))
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                compositeContext = CGContext(
                    data: nil,
                    width: previewCanvasW,
                    height: previewCanvasH,
                    bitsPerComponent: 8,
                    bytesPerRow: previewCanvasW * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            }

            let imagePt = canvasPointToImagePoint(canvasPoint, for: layer, imageSize: sendableImg.size)
            let initialPreview = session.begin(at: imagePt)

            let active = ActiveDeformStroke(
                layerID: layer.id,
                layerSnapshot: layer,
                originalSendable: sendableImg,
                mode: mode,
                canvasSize: canvasSize,
                canvasPreviewScale: canvasPreviewScale,
                isDirectCanvasFastPath: isDirectFastPath,
                underlayPreview: underlayPreview,
                overlayPreview: overlayPreview,
                previewAlphaMask: previewAlphaMask,
                compositeContext: compositeContext,
                session: session
            )
            state.activeStroke = active
            state.isDragging = true
            state.previewUpdateCount = 0

            if let initialPreview {
                publishDeformPreview(initialPreview, active: active)
                state.previewUpdateCount += 1
            }
        } catch {
            lastErrorMessage = "Could not start deform brush stroke."
        }
    }

    /// Continues the active deform brush stroke smoothly to `canvasPoint`, updating the live preview.
    public func continueDeformStroke(to canvasPoint: CGPoint) {
        let state = deformState
        guard var active = state.activeStroke else {
            beginDeformStroke(at: canvasPoint)
            return
        }

        let imagePt = canvasPointToImagePoint(
            canvasPoint,
            for: active.layerSnapshot,
            imageSize: active.originalSendable.size
        )

        if let updatedPreview = active.session.append(point: imagePt) {
            state.activeStroke = active
            publishDeformPreview(updatedPreview, active: active)
            state.previewUpdateCount += 1
        } else {
            state.activeStroke = active
        }
    }

    /// Finishes the active deform stroke: applies the recorded stroke once at full resolution
    /// off the main thread, updates the layer, and registers a single undo step for the entire stroke.
    @discardableResult
    public func endDeformStroke() -> Task<Void, Never> {
        let state = deformState
        guard let active = state.activeStroke else {
            return state.pendingCommitTask ?? Task {}
        }
        state.activeStroke = nil
        state.isDragging = false

        guard active.session.hasEffectiveMutation else {
            rerender()
            return Task {}
        }

        let sourceCG = active.originalSendable.cgImage
        let stroke = active.session.stroke
        let layerID = active.layerID
        let actionName = "Deform (\(active.mode.displayName))"

        state.isApplyingFullResolution = true

        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.deformState.isApplyingFullResolution = false
                    self.deformState.pendingCommitTask = nil
                }
            }

            do {
                let fullResDeformed = try await Task.detached(priority: .userInitiated) {
                    try DeformBrush.applyStroke(sourceCG, stroke: stroke)
                }.value

                guard let self else { return }
                self.commitFullResolutionDeform(
                    fullResDeformed,
                    expectedSource: sourceCG,
                    layerID: layerID,
                    actionName: actionName
                )
            } catch {
                guard let self else { return }
                self.lastErrorMessage = "Could not apply deform stroke."
                self.rerender()
            }
        }
        state.pendingCommitTask = task
        return task
    }

    /// Awaits any in-flight off-main-thread full-resolution deform commit.
    public func waitForPendingDeformCommit() async {
        if let pending = deformState.pendingCommitTask {
            await pending.value
        }
    }

    /// Convenience async helper to apply a complete deform brush stroke (in top-left canvas coordinates)
    /// off the main thread and record it as a single undo step.
    public func applyDeformStroke(
        canvasPoints: [CGPoint],
        mode: DeformBrushMode? = nil,
        radius: CGFloat? = nil,
        strength: CGFloat? = nil
    ) async throws {
        guard !canvasPoints.isEmpty else { return }
        guard let (layer, sendableImg) = targetImageLayer() else {
            throw ImageToolError.invalidParameters
        }

        let resolvedMode = mode ?? deformMode
        let resolvedRadius = radius ?? CGFloat(deformRadius)
        let resolvedStrength = strength ?? CGFloat(deformStrength)
        let avgScale = max(0.01, (abs(layer.transform.scale.width) + abs(layer.transform.scale.height)) / 2.0)
        let imageRadius = max(1.0, resolvedRadius / avgScale)
        let imagePoints = canvasPoints.map {
            canvasPointToImagePoint($0, for: layer, imageSize: sendableImg.size)
        }

        let stroke = DeformStroke(
            mode: resolvedMode,
            points: imagePoints,
            radius: imageRadius,
            strength: resolvedStrength
        )
        let sourceCG = sendableImg.cgImage
        let deformed = try await Task.detached(priority: .userInitiated) {
            try DeformBrush.applyStroke(sourceCG, stroke: stroke)
        }.value

        commitFullResolutionDeform(
            deformed,
            expectedSource: sourceCG,
            layerID: layer.id,
            actionName: "Deform (\(resolvedMode.displayName))"
        )
    }

    // MARK: - Private Commit & Preview Compositing Helpers

    private func commitFullResolutionDeform(
        _ deformedCG: CGImage,
        expectedSource: CGImage,
        layerID: UUID,
        actionName: String
    ) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked,
              case .image(let currentImg) = document.layers[idx].kind,
              currentImg.cgImage === expectedSource else {
            rerender()
            return
        }

        let updated = SendableImage(
            deformedCG,
            filterPreset: currentImg.filterPreset,
            adjustments: currentImg.adjustments,
            frame: currentImg.frame,
            alphaMask: currentImg.alphaMask
        )

        beginContinuousEdit()
        document.layers[idx].kind = .image(updated)
        rerender()
        endContinuousEdit(actionName: actionName)
    }

    private func canUseDirectPreviewFastPath(
        layer: Layer,
        image: SendableImage,
        canvasSize: CGSize
    ) -> Bool {
        guard document.layers.count == 1,
              document.background == .transparent,
              !layer.isHidden,
              abs(layer.opacity - 1.0) < 0.001,
              image.filterPreset == .none,
              image.adjustments.isIdentity,
              image.frame == .none,
              image.alphaMask == nil,
              abs(layer.transform.rotationDegrees) < 0.001,
              abs(layer.transform.scale.width - 1.0) < 0.001,
              abs(layer.transform.scale.height - 1.0) < 0.001 else {
            return false
        }
        let matchesCanvasSize = abs(image.size.width - canvasSize.width) < 0.5 &&
            abs(image.size.height - canvasSize.height) < 0.5
        let centered = abs(layer.transform.position.x - canvasSize.width * 0.5) < 0.5 &&
            abs(layer.transform.position.y - canvasSize.height * 0.5) < 0.5
        return matchesCanvasSize && centered
    }

    private func publishDeformPreview(_ previewWarpedCG: CGImage, active: ActiveDeformStroke) {
        if active.isDirectCanvasFastPath {
            renderedImage = previewWarpedCG
            return
        }

        guard let ctx = active.compositeContext else {
            renderedImage = previewWarpedCG
            return
        }

        var styledPreview = previewWarpedCG
        let orig = active.originalSendable
        if orig.filterPreset != .none || !orig.adjustments.isIdentity {
            if let filtered = try? ImageFilters.apply(
                to: styledPreview,
                preset: orig.filterPreset,
                adjustments: orig.adjustments
            ) {
                styledPreview = filtered
            }
        }
        if let mask = active.previewAlphaMask {
            if let masked = try? ImageEraser.applyAlphaMask(mask, to: styledPreview) {
                styledPreview = masked
            }
        }

        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(ctx.width), height: CGFloat(ctx.height))
        ctx.clear(fullRect)

        if let underlay = active.underlayPreview {
            ctx.draw(underlay, in: fullRect)
        }

        let layer = active.layerSnapshot
        if !layer.isHidden && layer.opacity > 0.0 {
            ctx.saveGState()
            ctx.scaleBy(x: active.canvasPreviewScale, y: active.canvasPreviewScale)
            ctx.translateBy(x: 0, y: active.canvasSize.height)
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.setAlpha(CGFloat(layer.opacity))

            ctx.translateBy(x: layer.transform.position.x, y: layer.transform.position.y)
            if layer.transform.rotationDegrees != 0 {
                ctx.rotate(by: CGFloat(layer.transform.rotationDegrees) * .pi / 180.0)
            }
            ctx.scaleBy(x: layer.transform.scale.width, y: layer.transform.scale.height)
            ctx.scaleBy(x: 1.0, y: -1.0)

            let origW = orig.size.width
            let origH = orig.size.height
            let localRect = CGRect(x: -origW * 0.5, y: -origH * 0.5, width: origW, height: origH)
            ctx.draw(styledPreview, in: localRect)
            ctx.restoreGState()
        }

        if let overlay = active.overlayPreview {
            ctx.draw(overlay, in: fullRect)
        }

        if let composite = ctx.makeImage() {
            renderedImage = composite
        }
    }

    private func downsampleGrayscaleMask(_ mask: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        if mask.width == width && mask.height == height {
            return mask
        }
        let graySpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
