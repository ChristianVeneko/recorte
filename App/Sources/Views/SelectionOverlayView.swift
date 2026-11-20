import AppKit
import RecorteCore
import SwiftUI

struct SelectionOverlayView: View {
    let model: EditorModel
    let layer: Layer
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var dragStartTransform: LayerTransform?
    @State private var isMoving: Bool = false
    @State private var isRotatingHandle: Bool = false

    private var activeTransform: LayerTransform {
        if let preview = model.liveTransformPreview, preview.layerID == layer.id {
            return preview.currentTransform
        }
        return layer.transform
    }

    private var isShowingRotationBadge: Bool {
        if isRotatingHandle { return true }
        if let preview = model.liveTransformPreview,
           preview.layerID == layer.id,
           preview.isRotating {
            return true
        }
        return false
    }

    private var isShiftSnapped: Bool {
        if let preview = model.liveTransformPreview, preview.layerID == layer.id {
            return preview.isShiftSnapped
        }
        return false
    }

    private var intrinsicSize: CGSize {
        model.layerIntrinsicSize(for: layer)
    }

    private var boxWidth: CGFloat {
        max(20, intrinsicSize.width * abs(activeTransform.scale.width) * displayScale)
    }

    private var boxHeight: CGFloat {
        max(20, intrinsicSize.height * abs(activeTransform.scale.height) * displayScale)
    }

    private var centerInView: CGPoint {
        CGPoint(
            x: canvasFrame.minX + activeTransform.position.x * displayScale,
            y: canvasFrame.minY + activeTransform.position.y * displayScale
        )
    }

    private var rotationBadgePosition: CGPoint {
        let stemRadius = (boxHeight / 2.0) + 46.0
        let rad = CGFloat(activeTransform.rotationDegrees) * .pi / 180.0
        return CGPoint(
            x: centerInView.x + stemRadius * sin(rad),
            y: centerInView.y - stemRadius * cos(rad)
        )
    }

    var body: some View {
        ZStack {
            ZStack {
                // Selection box & move gesture (open hand on hover, closed hand while dragging)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.001))
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                layer.isLocked ? Color.secondary : Color.accentColor,
                                style: StrokeStyle(lineWidth: 1.5, dash: layer.isLocked ? [4, 4] : [])
                            )
                    )
                    .frame(width: boxWidth, height: boxHeight)
                    .pointerStyle(layer.isLocked ? .default : (isMoving ? .grabActive : .grabIdle))
                    .gesture(moveGesture)

                if !layer.isLocked {
                    // Top rotation stem + knob with custom rotate cursor
                    VStack(spacing: 0) {
                        ZStack {
                            Color.clear
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                            Circle()
                                .fill(Color.white)
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                                .frame(width: 12, height: 12)
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        }
                        .pointerStyle(CanvasCursors.rotatePointerStyle)
                        .gesture(rotateGesture)

                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 1.5, height: 14)
                            .allowsHitTesting(false)
                    }
                    .offset(y: -(boxHeight / 2.0) - 19)

                    // 4 corner resize handles with rotation-aware resize cursors
                    cornerHandle(xSign: -1, ySign: -1)
                        .offset(x: -boxWidth / 2.0, y: -boxHeight / 2.0)
                    cornerHandle(xSign: 1, ySign: -1)
                        .offset(x: boxWidth / 2.0, y: -boxHeight / 2.0)
                    cornerHandle(xSign: -1, ySign: 1)
                        .offset(x: -boxWidth / 2.0, y: boxHeight / 2.0)
                    cornerHandle(xSign: 1, ySign: 1)
                        .offset(x: boxWidth / 2.0, y: boxHeight / 2.0)
                }
            }
            .rotationEffect(.degrees(activeTransform.rotationDegrees))
            .position(centerInView)

            // S25: Upright Liquid Glass angle badge while rotating via handle or trackpad
            if isShowingRotationBadge {
                HStack(spacing: 4) {
                    Text(RotationMath.formattedAngle(activeTransform.rotationDegrees))
                        .font(.caption.weight(.semibold).monospacedDigit())
                    if isShiftSnapped {
                        Image(systemName: "angle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                .position(rotationBadgePosition)
                .allowsHitTesting(false)
            }
        }
    }

    private func cornerHandle(xSign: CGFloat, ySign: CGFloat) -> some View {
        let cursorPos = CanvasCursorLogic.resizePosition(
            xSign: xSign,
            ySign: ySign,
            layerRotationDegrees: activeTransform.rotationDegrees
        )

        return ZStack {
            Color.clear
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .pointerStyle(CanvasCursors.resizePointerStyle(for: cursorPos))
        .gesture(resizeGesture(xSign: xSign, ySign: ySign))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                let start = dragStartTransform ?? layer.transform
                if dragStartTransform == nil {
                    dragStartTransform = start
                    isMoving = true
                    model.beginLiveTransform(for: layer.id, isRotating: false)
                }
                let dx = value.translation.width / max(displayScale, 0.01)
                let dy = value.translation.height / max(displayScale, 0.01)
                var next = start
                next.position = CGPoint(x: start.position.x + dx, y: start.position.y + dy)
                model.updateLiveTransform(next, isRotating: false)
            }
            .onEnded { _ in
                dragStartTransform = nil
                isMoving = false
                model.endLiveTransform(actionName: "Move Layer")
            }
    }

    private func resizeGesture(xSign: CGFloat, ySign: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                let start = dragStartTransform ?? layer.transform
                if dragStartTransform == nil {
                    dragStartTransform = start
                    model.beginLiveTransform(for: layer.id, isRotating: false)
                }
                let startCenter = CGPoint(
                    x: canvasFrame.minX + start.position.x * displayScale,
                    y: canvasFrame.minY + start.position.y * displayScale
                )
                let baseHalfW = max(8, intrinsicSize.width * abs(start.scale.width) * displayScale / 2.0)
                let baseHalfH = max(8, intrinsicSize.height * abs(start.scale.height) * displayScale / 2.0)
                let startDist = max(8, hypot(baseHalfW, baseHalfH))
                let currentDist = max(8, hypot(value.location.x - startCenter.x, value.location.y - startCenter.y))
                let factor = max(0.05, min(10.0, currentDist / startDist))

                var next = start
                next.scale = CGSize(
                    width: start.scale.width * factor,
                    height: start.scale.height * factor
                )
                model.updateLiveTransform(next, isRotating: false)
            }
            .onEnded { _ in
                dragStartTransform = nil
                model.endLiveTransform(actionName: "Resize Layer")
            }
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                let start = dragStartTransform ?? layer.transform
                if dragStartTransform == nil {
                    dragStartTransform = start
                    isRotatingHandle = true
                    model.beginLiveTransform(for: layer.id, isRotating: true)
                }
                let center = CGPoint(
                    x: canvasFrame.minX + start.position.x * displayScale,
                    y: canvasFrame.minY + start.position.y * displayScale
                )
                let rawDegrees = RotationMath.angleDegrees(from: center, to: value.location)
                let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                let finalDegrees = RotationMath.snapDegrees(rawDegrees, increment: 15.0, isShiftPressed: shiftHeld)

                var next = start
                next.rotationDegrees = finalDegrees
                model.updateLiveTransform(next, isRotating: true, isShiftSnapped: shiftHeld)
            }
            .onEnded { _ in
                dragStartTransform = nil
                isRotatingHandle = false
                model.endLiveTransform(actionName: "Rotate Layer")
            }
    }
}
