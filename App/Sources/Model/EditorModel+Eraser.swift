import CoreGraphics
import Foundation
import Observation
import RecorteCore

/// Observable per-editor state for the manual brush eraser tool (S23).
@MainActor
@Observable
public final class EraserState {
    public var mode: EraserMode = .erase
    public var brushSize: Double = 36.0
    public var hardness: Double = 0.75

    fileprivate var activeStroke: ActiveEraserStroke?

    public init() {}
}

private struct ActiveEraserStroke {
    let layerID: UUID
    let layerSnapshot: Layer
    let imageSize: CGSize
    let mode: EraserMode
    var session: EraserStrokeSession
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

    public var canResetEraserMask: Bool {
        guard let (_, img) = targetImageLayer() else { return false }
        return img.alphaMask != nil
    }

    // MARK: - Interactive Live Stroke API (One Undo Step Per Stroke)

    /// Begins an interactive eraser or restore stroke at `canvasPoint` (top-left canvas coordinates).
    public func beginEraserStroke(at canvasPoint: CGPoint) {
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
            var session = try EraserStrokeSession(
                baseMask: sendableImg.alphaMask,
                width: sendableImg.width,
                height: sendableImg.height,
                brushSize: imageBrushSize,
                hardness: CGFloat(clampedHardness),
                mode: state.mode
            )
            let updatedMask = try session.appendPoint(imagePt)

            beginContinuousEdit()
            state.activeStroke = ActiveEraserStroke(
                layerID: layer.id,
                layerSnapshot: layer,
                imageSize: sendableImg.size,
                mode: state.mode,
                session: session
            )
            applyUpdatedAlphaMask(updatedMask, to: layer.id)
        } catch {
            lastErrorMessage = "Could not start eraser stroke."
        }
    }

    /// Continues the active eraser or restore stroke smoothly to `canvasPoint`.
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

        do {
            let updatedMask = try active.session.appendPoint(imagePt)
            state.activeStroke = active
            applyUpdatedAlphaMask(updatedMask, to: active.layerID)
        } catch {
            lastErrorMessage = "Could not update eraser stroke."
        }
    }

    /// Finishes the active eraser or restore stroke and commits the entire stroke as a single undo step.
    public func endEraserStroke() {
        let state = eraserState
        guard var active = state.activeStroke else { return }
        state.activeStroke = nil

        if let finalMask = try? active.session.finish() {
            applyUpdatedAlphaMask(finalMask, to: active.layerID)
        }

        let actionName = active.mode == .erase ? "Erase" : "Restore"
        endContinuousEdit(actionName: actionName)
    }

    // MARK: - Batch Stroke & Reset Helpers

    /// Applies a complete eraser or restore stroke (points in top-left canvas coordinates) as one undo step.
    public func applyEraserStroke(
        canvasPoints: [CGPoint],
        brushSize: CGFloat? = nil,
        hardness: CGFloat? = nil,
        mode: EraserMode? = nil
    ) throws {
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
        let updatedImage = try sendableImg.applyingEraserStroke(stroke)

        beginContinuousEdit()
        if let idx = document.layers.firstIndex(where: { $0.id == layer.id }) {
            document.layers[idx].kind = .image(updatedImage)
            rerender()
        }
        endContinuousEdit(actionName: resolvedMode == .erase ? "Erase" : "Restore")
    }

    /// Clears the target image layer's eraser mask, restoring all original pixels as one undo step.
    public func resetEraserMask() {
        guard let (layer, sendableImg) = targetImageLayer(),
              sendableImg.alphaMask != nil else { return }
        let restored = SendableImage(
            sendableImg.cgImage,
            filterPreset: sendableImg.filterPreset,
            adjustments: sendableImg.adjustments,
            frame: sendableImg.frame,
            alphaMask: nil
        )
        beginContinuousEdit()
        if let idx = document.layers.firstIndex(where: { $0.id == layer.id }) {
            document.layers[idx].kind = .image(restored)
            rerender()
        }
        endContinuousEdit(actionName: "Reset Eraser")
    }

    // MARK: - Private Helper

    private func applyUpdatedAlphaMask(_ mask: CGImage, to layerID: UUID) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              case .image(var img) = document.layers[idx].kind else { return }
        img.alphaMask = mask
        document.layers[idx].kind = .image(img)
        rerender()
    }
}
