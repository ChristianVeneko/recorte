import RecorteCore
import SwiftUI

struct SelectionOverlayView: View {
    let model: EditorModel
    let layer: Layer
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var dragStartTransform: LayerTransform?

    private var intrinsicSize: CGSize {
        model.layerIntrinsicSize(for: layer)
    }

    private var boxWidth: CGFloat {
        max(20, intrinsicSize.width * abs(layer.transform.scale.width) * displayScale)
    }

    private var boxHeight: CGFloat {
        max(20, intrinsicSize.height * abs(layer.transform.scale.height) * displayScale)
    }

    private var centerInView: CGPoint {
        CGPoint(
            x: canvasFrame.minX + layer.transform.position.x * displayScale,
            y: canvasFrame.minY + layer.transform.position.y * displayScale
        )
    }

    var body: some View {
        ZStack {
            // Selection box & move gesture
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
                .gesture(moveGesture)

            if !layer.isLocked {
                // Top rotation stem + knob
                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .gesture(rotateGesture)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: 18)
                }
                .offset(y: -(boxHeight / 2.0) - 15)

                // 4 corner resize handles
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
        .rotationEffect(.degrees(layer.transform.rotationDegrees))
        .position(centerInView)
    }

    private func cornerHandle(xSign: CGFloat, ySign: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .gesture(resizeGesture(xSign: xSign, ySign: ySign))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                let start = dragStartTransform ?? layer.transform
                if dragStartTransform == nil {
                    dragStartTransform = start
                }
                let dx = value.translation.width / max(displayScale, 0.01)
                let dy = value.translation.height / max(displayScale, 0.01)
                var next = start
                next.position = CGPoint(x: start.position.x + dx, y: start.position.y + dy)
                model.setLayerTransform(id: layer.id, transform: next, continuous: true, actionName: "Move Layer")
            }
            .onEnded { _ in
                dragStartTransform = nil
                model.endContinuousEdit(actionName: "Move Layer")
            }
    }

    private func resizeGesture(xSign: CGFloat, ySign: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                let start = dragStartTransform ?? layer.transform
                if dragStartTransform == nil {
                    dragStartTransform = start
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
                model.setLayerTransform(id: layer.id, transform: next, continuous: true, actionName: "Resize Layer")
            }
            .onEnded { _ in
                dragStartTransform = nil
                model.endContinuousEdit(actionName: "Resize Layer")
            }
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                guard !layer.isLocked else { return }
                let start = dragStartTransform ?? layer.transform
                if dragStartTransform == nil {
                    dragStartTransform = start
                }
                let center = CGPoint(
                    x: canvasFrame.minX + start.position.x * displayScale,
                    y: canvasFrame.minY + start.position.y * displayScale
                )
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                let angleRad = atan2(dy, dx) + (.pi / 2.0)
                var degrees = Double(angleRad * 180.0 / .pi)
                if NSEvent.modifierFlags.contains(.shift) {
                    degrees = (degrees / 15.0).rounded() * 15.0
                }
                var next = start
                next.rotationDegrees = degrees
                model.setLayerTransform(id: layer.id, transform: next, continuous: true, actionName: "Rotate Layer")
            }
            .onEnded { _ in
                dragStartTransform = nil
                model.endContinuousEdit(actionName: "Rotate Layer")
            }
    }
}
