import CoreGraphics
import Foundation
import Observation
import RecorteCore

// MARK: - Persistent Preview-Resolution Live Eraser Canvas (S27 Fluid Eraser)

/// Holds the active image layer's persistent preview-resolution alpha mask and RGBA composite buffer
/// during an interactive eraser drag so pointer moves only touch the tiny dirty rect with zero
/// full-document re-renders and zero per-move full-image copies.
@MainActor
@Observable
public final class LiveEraserCanvas {
    @ObservationIgnored public let layerID: UUID
    @ObservationIgnored public let layerTransform: LayerTransform
    @ObservationIgnored public let layerOpacity: Double
    @ObservationIgnored public let layerFrame: ImageFrame
    @ObservationIgnored public let imageSize: CGSize
    @ObservationIgnored public let previewWidth: Int
    @ObservationIgnored public let previewHeight: Int
    @ObservationIgnored public let scaleX: CGFloat
    @ObservationIgnored public let scaleY: CGFloat

    /// Bumped whenever a dirty rect is updated so `LiveEraserLayerView` invalidates ONLY that rect.
    public private(set) var revision: Int = 0

    @ObservationIgnored private let baseRGBA: [UInt8]
    @ObservationIgnored private let maskBitmap: PersistentAlphaMask
    @ObservationIgnored private var compositeRGBA: [UInt8]
    @ObservationIgnored private var pendingViewDirtyRect: PixelDirtyRect?
    @ObservationIgnored private let sRGBSpace: CGColorSpace

    public init(
        layer: Layer,
        sendableImg: SendableImage,
        previewScale: CGFloat
    ) throws {
        self.layerID = layer.id
        self.layerTransform = layer.transform
        self.layerOpacity = layer.opacity
        self.layerFrame = sendableImg.frame
        self.imageSize = sendableImg.size
        self.sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Cap live preview buffer to view pixel size and at most 1024 px on longest edge
        // so even 2000x2000+ images composite dirty rects in microseconds with minimal RAM.
        let fullW = max(1, sendableImg.width)
        let fullH = max(1, sendableImg.height)
        let longestFull = CGFloat(max(fullW, fullH))
        let maxLiveEdge: CGFloat = 1024.0
        let desiredEdge = min(longestFull, min(maxLiveEdge, max(256.0, longestFull * max(previewScale, 0.25))))
        let ratio = min(1.0, desiredEdge / longestFull)

        let pw = max(1, Int((CGFloat(fullW) * ratio).rounded()))
        let ph = max(1, Int((CGFloat(fullH) * ratio).rounded()))
        self.previewWidth = pw
        self.previewHeight = ph
        self.scaleX = CGFloat(pw) / CGFloat(fullW)
        self.scaleY = CGFloat(ph) / CGFloat(fullH)

        // Pre-apply filters/adjustments ONCE at preview resolution (never per drag event).
        let previewSourceCG: CGImage
        let downscaled = ImageFilters.downsample(sendableImg.cgImage, maxDimension: CGFloat(max(pw, ph))) ?? sendableImg.cgImage
        if sendableImg.filterPreset != .none || !sendableImg.adjustments.isIdentity {
            previewSourceCG = (try? ImageFilters.apply(
                to: downscaled,
                preset: sendableImg.filterPreset,
                adjustments: sendableImg.adjustments
            )) ?? downscaled
        } else {
            previewSourceCG = downscaled
        }

        let base = try ImageEraser.readPremultipliedRGBABytes(previewSourceCG, targetWidth: pw, targetHeight: ph)
        let mask = try PersistentAlphaMask(baseMask: sendableImg.alphaMask, width: pw, height: ph)
        let composite: [UInt8]
        if let existingMask = sendableImg.alphaMask,
           let maskedPreview = try? ImageEraser.applyAlphaMask(existingMask, to: previewSourceCG),
           let maskedBytes = try? ImageEraser.readPremultipliedRGBABytes(maskedPreview, targetWidth: pw, targetHeight: ph) {
            composite = maskedBytes
        } else if sendableImg.alphaMask != nil {
            var buf = [UInt8](repeating: 0, count: pw * ph * 4)
            mask.compositeAll(baseRGBA: base, into: &buf)
            composite = buf
        } else {
            composite = base
        }

        self.baseRGBA = base
        self.maskBitmap = mask
        self.compositeRGBA = composite
        self.pendingViewDirtyRect = PixelDirtyRect(minX: 0, maxX: pw - 1, minY: 0, maxY: ph - 1)
    }

    public func beginStroke(imageBrushSize: CGFloat, hardness: CGFloat, mode: EraserMode) {
        let previewBrushSize = max(1.0, imageBrushSize * ((scaleX + scaleY) * 0.5))
        maskBitmap.beginStroke(brushSize: previewBrushSize, hardness: hardness, mode: mode)
    }

    public func appendImagePoint(_ imagePoint: CGPoint) {
        let previewPt = CGPoint(x: imagePoint.x * scaleX, y: imagePoint.y * scaleY)
        guard let dirty = maskBitmap.appendPoint(previewPt) else { return }
        maskBitmap.compositeDirtyRect(dirty, baseRGBA: baseRGBA, into: &compositeRGBA)
        pendingViewDirtyRect = pendingViewDirtyRect?.union(dirty) ?? dirty
        revision &+= 1
    }

    public func finishStroke() {
        if let dirty = maskBitmap.finishStroke() {
            maskBitmap.compositeDirtyRect(dirty, baseRGBA: baseRGBA, into: &compositeRGBA)
            pendingViewDirtyRect = pendingViewDirtyRect?.union(dirty) ?? dirty
            revision &+= 1
        }
    }

    /// Consumes and clears the accumulated dirty rect since the last NSView invalidation.
    public func consumePendingDirtyRect() -> PixelDirtyRect? {
        let rect = pendingViewDirtyRect
        pendingViewDirtyRect = nil
        return rect
    }

    /// Extracts a `CGImage` covering ONLY `pixelRect` (`minX...maxX`, `minY...maxY`) from `compositeRGBA`
    /// so `NSView.draw(_ dirtyRect:)` copies only a tiny dirty tile instead of the entire bitmap.
    public func makeTileImage(for pixelRect: PixelDirtyRect) -> CGImage? {
        let minX = max(0, pixelRect.minX)
        let maxX = min(previewWidth - 1, pixelRect.maxX)
        let minY = max(0, pixelRect.minY)
        let maxY = min(previewHeight - 1, pixelRect.maxY)
        guard minX <= maxX, minY <= maxY else { return nil }

        let tileW = maxX - minX + 1
        let tileH = maxY - minY + 1
        let tileRowBytes = tileW * 4
        let fullRowBytes = previewWidth * 4

        var tileData = Data(count: tileH * tileRowBytes)
        tileData.withUnsafeMutableBytes { dstRaw in
            compositeRGBA.withUnsafeBytes { srcRaw in
                guard let dstBase = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let srcBase = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0..<tileH {
                    let srcOffset = (minY + row) * fullRowBytes + minX * 4
                    memcpy(dstBase + row * tileRowBytes, srcBase + srcOffset, tileRowBytes)
                }
            }
        }

        guard let provider = CGDataProvider(data: tileData as CFData) else { return nil }
        return CGImage(
            width: tileW,
            height: tileH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: tileRowBytes,
            space: sRGBSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Active live preview bundle shown in `CanvasStageView` while an eraser stroke is dragging
/// or committing off the main thread. Dropped immediately when idle (S28).
public struct LiveEraserPreview: Sendable {
    public let underlay: CGImage?
    public let canvas: LiveEraserCanvas
    public let overlay: CGImage?
}

/// Observable per-editor state for the manual brush eraser tool (S23, S27, S28).
@MainActor
@Observable
public final class EraserState {
    public var mode: EraserMode = .erase
    public var brushSize: Double = 36.0
    public var hardness: Double = 0.75
    public var livePreview: LiveEraserPreview?

    @ObservationIgnored fileprivate var activeStroke: ActiveEraserStroke?
    @ObservationIgnored fileprivate var pendingCommit: PendingEraserCommit?
    @ObservationIgnored fileprivate var maskHistories: [UUID: EraserLayerHistory] = [:]

    public init() {}
}

private struct ActiveEraserStroke {
    let layerID: UUID
    let layerSnapshot: Layer
    let imageSize: CGSize
    let imageWidth: Int
    let imageHeight: Int
    let baseMask: CGImage?
    let imageBrushSize: CGFloat
    let hardness: CGFloat
    let mode: EraserMode
    var rawImagePoints: [CGPoint]
    let canvas: LiveEraserCanvas
}

private struct PendingEraserCommit {
    let id: UUID
    let layerID: UUID
    let baseMask: CGImage?
    let width: Int
    let height: Int
    let stroke: EraserStroke
    let actionName: String
    let task: Task<Void, Never>
}

/// Compact stroke-record history per layer so eraser undo/redo stores tiny `EraserStroke` point lists
/// (~KB) instead of full-size mask `CGImage` bitmaps (S28).
private struct EraserLayerHistory {
    var sourceImageID: ObjectIdentifier
    var baseMask: CGImage?
    var strokes: [EraserStroke]
}

@MainActor
private enum EraserStateRegistry {
    static let table = NSMapTable<EditorModel, EraserState>.weakToStrongObjects()

    static func state(for model: EditorModel) -> EraserState {
        if let existing = table.object(forKey: model) {
            return existing
        }
        let created = EraserState()
        table.setObject(created, forKey: model)
        return created
    }
}

extension EditorModel {
    /// Observable state object backing eraser controls (mode, size, hardness).
    public var eraserState: EraserState {
        EraserStateRegistry.state(for: self)
    }

    public var eraserMode: EraserMode {
        get { eraserState.mode }
        set { eraserState.mode = newValue }
    }

    public var eraserBrushSize: Double {
        get { eraserState.brushSize }
        set { eraserState.brushSize = min(max(newValue, 4.0), 200.0) }
    }

    public var eraserHardness: Double {
        get { eraserState.hardness }
        set { eraserState.hardness = min(max(newValue, 0.0), 1.0) }
    }

    /// Live preview composite shown during an interactive eraser drag or background stroke commit.
    public var liveEraserPreview: LiveEraserPreview? {
        eraserState.livePreview
    }

    public var isEraserStrokeActive: Bool {
        eraserState.activeStroke != nil || eraserState.pendingCommit != nil
    }

    public var canResetEraserMask: Bool {
        guard let (_, img) = targetImageLayer() else { return false }
        return img.alphaMask != nil
    }

    // MARK: - Interactive Live Stroke API (Dirty-Rect Preview + Off-Main-Thread Full-Res Commit)

    /// Begins an interactive eraser or restore stroke at `canvasPoint` (top-left canvas coordinates).
    /// Builds a preview-resolution live canvas once and NEVER re-renders the whole document per drag event.
    public func beginEraserStroke(at canvasPoint: CGPoint) {
        flushPendingEraserCommitSynchronously()

        guard let (layer, sendableImg) = targetImageLayer() else {
            lastErrorMessage = "Select an unlocked image layer to erase."
            return
        }

        let state = eraserState
        let clampedSize = min(max(state.brushSize, 4.0), 200.0)
        let clampedHardness = min(max(state.hardness, 0.0), 1.0)
        let avgScale = max(0.01, (abs(layer.transform.scale.width) + abs(layer.transform.scale.height)) / 2.0)
        let imageBrushSize = max(1.0, CGFloat(clampedSize) / avgScale)
        let imagePt = canvasPointToImagePoint(canvasPoint, for: layer, imageSize: sendableImg.size)

        do {
            let canvas = try LiveEraserCanvas(
                layer: layer,
                sendableImg: sendableImg,
                previewScale: previewRenderScale
            )
            canvas.beginStroke(imageBrushSize: imageBrushSize, hardness: CGFloat(clampedHardness), mode: state.mode)
            canvas.appendImagePoint(imagePt)

            let surrounding = DocumentRenderer.renderLayerSurroundingSplit(
                document,
                activeLayerID: layer.id,
                scale: previewRenderScale
            )

            state.livePreview = LiveEraserPreview(
                underlay: surrounding?.underlay,
                canvas: canvas,
                overlay: surrounding?.overlay
            )
            state.activeStroke = ActiveEraserStroke(
                layerID: layer.id,
                layerSnapshot: layer,
                imageSize: sendableImg.size,
                imageWidth: sendableImg.width,
                imageHeight: sendableImg.height,
                baseMask: sendableImg.alphaMask,
                imageBrushSize: imageBrushSize,
                hardness: CGFloat(clampedHardness),
                mode: state.mode,
                rawImagePoints: [imagePt],
                canvas: canvas
            )
        } catch {
            lastErrorMessage = "Could not start eraser stroke."
        }
    }

    /// Continues the active eraser or restore stroke smoothly to `canvasPoint`.
    /// Updates ONLY the dirty rect in the persistent preview alpha mask and active layer buffer.
    public func continueEraserStroke(to canvasPoint: CGPoint) {
        let state = eraserState
        guard var active = state.activeStroke else {
            beginEraserStroke(at: canvasPoint)
            return
        }

        let imagePt = canvasPointToImagePoint(
            canvasPoint,
            for: active.layerSnapshot,
            imageSize: active.imageSize
        )

        if let last = active.rawImagePoints.last,
           hypot(imagePt.x - last.x, imagePt.y - last.y) < 0.25 {
            return
        }

        active.rawImagePoints.append(imagePt)
        active.canvas.appendImagePoint(imagePt)
        state.activeStroke = active
    }

    /// Finishes the active stroke and applies the full-resolution mask synchronously (1 undo step).
    /// Keeps synchronous callers and unit tests deterministic; interactive UI uses `endEraserStrokeInBackground()`.
    public func endEraserStroke() {
        let state = eraserState
        guard let active = state.activeStroke else {
            flushPendingEraserCommitSynchronously()
            return
        }
        state.activeStroke = nil
        active.canvas.finishStroke()

        let stroke = EraserStroke(
            points: active.rawImagePoints,
            brushSize: active.imageBrushSize,
            hardness: active.hardness,
            mode: active.mode
        )
        let actionName = active.mode == .erase ? "Erase" : "Restore"

        if let finalMask = try? ImageEraser.applyStrokeToMask(
            active.baseMask,
            width: active.imageWidth,
            height: active.imageHeight,
            stroke: stroke
        ) {
            commitCompletedEraserStroke(
                layerID: active.layerID,
                stroke: stroke,
                finalMask: finalMask,
                preRenderedPreview: nil,
                preRenderedScale: previewRenderScale,
                actionName: actionName
            )
        }

        // Drop split underlay/overlay and live preview buffers immediately when stroke ends (S28).
        state.livePreview = nil
    }

    /// Non-blocking stroke finish for interactive pointer-up: runs full-resolution mask rasterization
    /// and preview render OFF the main thread, then commits on MainActor and drops temporary preview buffers.
    public func endEraserStrokeInBackground() {
        guard eraserState.activeStroke != nil else { return }
        _ = startBackgroundEraserCommit()
    }

    /// Async stroke finish that applies full-resolution mask work off the main thread and awaits completion.
    public func endEraserStrokeAsync() async {
        if let task = startBackgroundEraserCommit() {
            await task.value
        } else if let pending = eraserState.pendingCommit {
            await pending.task.value
        }
    }

    @discardableResult
    private func startBackgroundEraserCommit() -> Task<Void, Never>? {
        let state = eraserState
        guard let active = state.activeStroke else { return nil }
        state.activeStroke = nil
        active.canvas.finishStroke()

        let stroke = EraserStroke(
            points: active.rawImagePoints,
            brushSize: active.imageBrushSize,
            hardness: active.hardness,
            mode: active.mode
        )
        let actionName = active.mode == .erase ? "Erase" : "Restore"
        let commitID = UUID()
        let layerID = active.layerID
        let baseMask = active.baseMask
        let width = active.imageWidth
        let height = active.imageHeight
        let targetScale = previewRenderScale
        let docSnapshot = document

        let task = Task<Void, Never> { [weak self] in
            let computed: (mask: CGImage, preview: CGImage?)? = await Task.detached(priority: .userInitiated) {
                guard let mask = try? ImageEraser.applyStrokeToMask(
                    baseMask,
                    width: width,
                    height: height,
                    stroke: stroke
                ) else {
                    return nil
                }
                var updatedDoc = docSnapshot
                if let idx = updatedDoc.layers.firstIndex(where: { $0.id == layerID }),
                   case .image(var img) = updatedDoc.layers[idx].kind {
                    img.alphaMask = mask
                    updatedDoc.layers[idx].kind = .image(img)
                }
                let preview = try? DocumentRenderer.render(updatedDoc, scale: targetScale)
                return (mask, preview)
            }.value

            guard !Task.isCancelled, let self else { return }
            let currentState = self.eraserState
            guard currentState.pendingCommit?.id == commitID else { return }
            currentState.pendingCommit = nil

            if let computed {
                self.commitCompletedEraserStroke(
                    layerID: layerID,
                    stroke: stroke,
                    finalMask: computed.mask,
                    preRenderedPreview: computed.preview,
                    preRenderedScale: targetScale,
                    actionName: actionName
                )
            }
            // Drop split images & live preview buffers immediately when idle (S28).
            currentState.livePreview = nil
        }

        state.pendingCommit = PendingEraserCommit(
            id: commitID,
            layerID: layerID,
            baseMask: baseMask,
            width: width,
            height: height,
            stroke: stroke,
            actionName: actionName,
            task: task
        )
        return task
    }

    /// Ensures any in-flight off-main-thread eraser commit finishes deterministically before
    /// undo, redo, export, save, tool change, or a new mutation touches the document.
    internal func flushPendingEraserCommitSynchronously() {
        let state = eraserState
        if state.activeStroke != nil {
            endEraserStroke()
            return
        }
        guard let pending = state.pendingCommit else { return }
        pending.task.cancel()
        state.pendingCommit = nil

        if let finalMask = try? ImageEraser.applyStrokeToMask(
            pending.baseMask,
            width: pending.width,
            height: pending.height,
            stroke: pending.stroke
        ) {
            commitCompletedEraserStroke(
                layerID: pending.layerID,
                stroke: pending.stroke,
                finalMask: finalMask,
                preRenderedPreview: nil,
                preRenderedScale: previewRenderScale,
                actionName: pending.actionName
            )
        }
        state.livePreview = nil
    }

    // MARK: - Batch Stroke & Reset Helpers

    /// Applies a complete eraser or restore stroke (points in top-left canvas coordinates) as one undo step.
    public func applyEraserStroke(
        canvasPoints: [CGPoint],
        brushSize: CGFloat? = nil,
        hardness: CGFloat? = nil,
        mode: EraserMode? = nil
    ) throws {
        flushPendingEraserCommitSynchronously()
        guard !canvasPoints.isEmpty else { return }
        guard let (layer, sendableImg) = targetImageLayer() else {
            throw ImageToolError.invalidParameters
        }

        let resolvedMode = mode ?? eraserMode
        let resolvedSize = brushSize ?? CGFloat(eraserBrushSize)
        let resolvedHardness = hardness ?? CGFloat(eraserHardness)
        let avgScale = max(0.01, (abs(layer.transform.scale.width) + abs(layer.transform.scale.height)) / 2.0)
        let imageBrushSize = max(1.0, resolvedSize / avgScale)
        let imagePoints = canvasPoints.map {
            canvasPointToImagePoint($0, for: layer, imageSize: sendableImg.size)
        }

        let stroke = EraserStroke(
            points: imagePoints,
            brushSize: imageBrushSize,
            hardness: resolvedHardness,
            mode: resolvedMode
        )
        let finalMask = try ImageEraser.applyStrokeToMask(
            sendableImg.alphaMask,
            width: sendableImg.width,
            height: sendableImg.height,
            stroke: stroke
        )
        let actionName = resolvedMode == .erase ? "Erase" : "Restore"
        commitCompletedEraserStroke(
            layerID: layer.id,
            stroke: stroke,
            finalMask: finalMask,
            preRenderedPreview: nil,
            preRenderedScale: previewRenderScale,
            actionName: actionName
        )
    }

    /// Clears the target image layer's eraser mask, restoring all original pixels as one undo step.
    public func resetEraserMask() {
        flushPendingEraserCommitSynchronously()
        guard let (layer, sendableImg) = targetImageLayer(),
              sendableImg.alphaMask != nil else { return }

        let state = eraserState
        let priorHistory = ensureLayerHistory(for: layer.id, image: sendableImg)
        state.maskHistories[layer.id] = EraserLayerHistory(
            sourceImageID: ObjectIdentifier(sendableImg.cgImage),
            baseMask: nil,
            strokes: []
        )

        if let idx = document.layers.firstIndex(where: { $0.id == layer.id }),
           case .image(var img) = document.layers[idx].kind {
            img.alphaMask = nil
            document.layers[idx].kind = .image(img)
            rerender()
        }

        registerUndoAction(actionName: "Reset Eraser") { target in
            target.restoreEraserHistory(priorHistory, for: layer.id, actionName: "Reset Eraser")
        }
    }

    // MARK: - Compact Stroke-Record Undo / Redo (Zero Full-Mask Snapshots in Undo)

    private func ensureLayerHistory(for layerID: UUID, image: SendableImage) -> EraserLayerHistory {
        let state = eraserState
        let currentSourceID = ObjectIdentifier(image.cgImage)
        if let existing = state.maskHistories[layerID], existing.sourceImageID == currentSourceID {
            return existing
        }
        let fresh = EraserLayerHistory(
            sourceImageID: currentSourceID,
            baseMask: image.alphaMask,
            strokes: []
        )
        state.maskHistories[layerID] = fresh
        return fresh
    }

    private func commitCompletedEraserStroke(
        layerID: UUID,
        stroke: EraserStroke,
        finalMask: CGImage,
        preRenderedPreview: CGImage?,
        preRenderedScale: CGFloat,
        actionName: String
    ) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              case .image(var img) = document.layers[idx].kind else { return }

        let state = eraserState
        var history = ensureLayerHistory(for: layerID, image: img)
        history.strokes.append(stroke)

        // Bake strokes beyond the undo cap into baseMask so replay stays bounded to <= maxUndoLevels.
        let maxStoredStrokes = EditorModel.maxUndoLevels + 2
        if history.strokes.count > maxStoredStrokes {
            let overflowCount = history.strokes.count - maxStoredStrokes
            let toBake = Array(history.strokes.prefix(overflowCount))
            if let baked = try? ImageEraser.applyStrokesToMask(
                history.baseMask,
                width: img.width,
                height: img.height,
                strokes: toBake
            ) {
                history.baseMask = baked
                history.strokes.removeFirst(overflowCount)
            }
        }
        state.maskHistories[layerID] = history

        img.alphaMask = finalMask
        document.layers[idx].kind = .image(img)

        if let preRenderedPreview, abs(preRenderedScale - previewRenderScale) < 0.01 {
            applyRenderedPreview(preRenderedPreview, scale: preRenderedScale)
        } else {
            rerender()
        }

        registerUndoAction(actionName: actionName) { target in
            target.undoEraserStroke(stroke, for: layerID, actionName: actionName)
        }
    }

    private func undoEraserStroke(_ stroke: EraserStroke, for layerID: UUID, actionName: String) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              case .image(var img) = document.layers[idx].kind else { return }

        let state = eraserState
        var history = ensureLayerHistory(for: layerID, image: img)
        if !history.strokes.isEmpty {
            history.strokes.removeLast()
        }
        state.maskHistories[layerID] = history

        if history.strokes.isEmpty {
            img.alphaMask = history.baseMask
        } else {
            img.alphaMask = try? ImageEraser.applyStrokesToMask(
                history.baseMask,
                width: img.width,
                height: img.height,
                strokes: history.strokes
            )
        }
        document.layers[idx].kind = .image(img)
        rerender()

        registerUndoAction(actionName: actionName) { target in
            target.redoEraserStroke(stroke, for: layerID, actionName: actionName)
        }
    }

    private func redoEraserStroke(_ stroke: EraserStroke, for layerID: UUID, actionName: String) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              case .image(var img) = document.layers[idx].kind else { return }

        let state = eraserState
        var history = ensureLayerHistory(for: layerID, image: img)
        history.strokes.append(stroke)
        state.maskHistories[layerID] = history

        img.alphaMask = try? ImageEraser.applyStrokeToMask(
            img.alphaMask,
            width: img.width,
            height: img.height,
            stroke: stroke
        )
        document.layers[idx].kind = .image(img)
        rerender()

        registerUndoAction(actionName: actionName) { target in
            target.undoEraserStroke(stroke, for: layerID, actionName: actionName)
        }
    }

    private func restoreEraserHistory(_ snapshot: EraserLayerHistory, for layerID: UUID, actionName: String) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              case .image(var img) = document.layers[idx].kind else { return }

        let state = eraserState
        let currentHistory = ensureLayerHistory(for: layerID, image: img)
        state.maskHistories[layerID] = snapshot

        if snapshot.strokes.isEmpty {
            img.alphaMask = snapshot.baseMask
        } else {
            img.alphaMask = try? ImageEraser.applyStrokesToMask(
                snapshot.baseMask,
                width: img.width,
                height: img.height,
                strokes: snapshot.strokes
            )
        }
        document.layers[idx].kind = .image(img)
        rerender()

        registerUndoAction(actionName: actionName) { target in
            target.restoreEraserHistory(currentHistory, for: layerID, actionName: actionName)
        }
    }
}
