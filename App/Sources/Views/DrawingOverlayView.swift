import RecorteCore
import SwiftUI

struct DrawingOverlayView: View {
    let model: EditorModel
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var currentCanvasPoints: [CGPoint] = []

    var body: some View {
        Canvas { context, _ in
            guard !currentCanvasPoints.isEmpty else { return }
            let viewPoints = currentCanvasPoints.map { pt in
                CGPoint(
                    x: canvasFrame.minX + pt.x * displayScale,
                    y: canvasFrame.minY + pt.y * displayScale
                )
            }
            var path = Path()
            if viewPoints.count == 1, let first = viewPoints.first {
                let r = max(1, CGFloat(model.brushLineWidth) * displayScale / 2.0)
                path.addEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
                context.fill(path, with: .color(model.brushColor.swiftUIColor))
            } else {
                path.move(to: viewPoints[0])
                for pt in viewPoints.dropFirst() {
                    path.addLine(to: pt)
                }
                context.stroke(
                    path,
                    with: .color(model.brushColor.swiftUIColor),
                    style: StrokeStyle(
                        lineWidth: max(1, CGFloat(model.brushLineWidth) * displayScale),
                        lineCap: .round,
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
                            lineWidth: model.brushLineWidth
                        )
                    }
                }
        )
    }
}
