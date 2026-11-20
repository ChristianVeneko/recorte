import RecorteCore
import SwiftUI

struct DrawingOverlayView: View {
    let model: EditorModel
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var currentCanvasPoints: [CGPoint] = []

    private var strokeOpacity: Double {
        switch model.drawingToolKind {
        case .brush: 1.0
        case .marker: 0.85
        case .highlighter: 0.38
        }
    }

    private var strokeCap: CGLineCap {
        switch model.drawingToolKind {
        case .brush: .round
        case .marker: .round
        case .highlighter: .square
        }
    }

    var body: some View {
        Canvas { context, _ in
            guard !currentCanvasPoints.isEmpty else { return }
            let viewPoints = currentCanvasPoints.map { pt in
                CGPoint(
                    x: canvasFrame.minX + pt.x * displayScale,
                    y: canvasFrame.minY + pt.y * displayScale
                )
            }
            let effectiveWidth = max(1, CGFloat(model.brushLineWidth) * displayScale)
            let previewColor = model.brushColor.swiftUIColor.opacity(strokeOpacity)

            var path = Path()
            if viewPoints.count == 1, let first = viewPoints.first {
                let r = effectiveWidth / 2.0
                path.addEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
                context.fill(path, with: .color(previewColor))
            } else {
                path.move(to: viewPoints[0])
                for pt in viewPoints.dropFirst() {
                    path.addLine(to: pt)
                }
                context.stroke(
                    path,
                    with: .color(previewColor),
                    style: StrokeStyle(
                        lineWidth: effectiveWidth,
                        lineCap: strokeCap,
                        lineJoin: .round
                    )
                )
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvasStage"))
                .onChanged { value in
                    let pt = CGPoint(
                        x: (value.location.x - canvasFrame.minX) / max(displayScale, 0.01),
                        y: (value.location.y - canvasFrame.minY) / max(displayScale, 0.01)
                    )
                    currentCanvasPoints.append(pt)
                }
                .onEnded { _ in
                    let stroke = currentCanvasPoints
                    currentCanvasPoints = []
                    if !stroke.isEmpty {
                        model.commitBrushStroke(
                            points: stroke,
                            color: model.brushColor,
                            lineWidth: model.brushLineWidth,
                            tool: model.drawingToolKind
                        )
                    }
                }
        )
    }
}
