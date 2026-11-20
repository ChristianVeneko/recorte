import RecorteCore
import SwiftUI

struct ToneCurveEditorView: View {
    @Binding var curve: ToneCurveSpec
    let onApply: () -> Void

    private let graphHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tone Curve")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !curve.isIdentity {
                    Button("Reset") {
                        curve = ToneCurveSpec()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height

                ZStack {
                    // Grid + diagonal reference
                    Canvas { context, size in
                        context.fill(
                            Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                            with: .color(Color(nsColor: .controlBackgroundColor))
                        )

                        var grid = Path()
                        for frac in [0.25, 0.5, 0.75] {
                            let x = size.width * frac
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                            let y = size.height * frac
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.75)

                        var diag = Path()
                        diag.move(to: CGPoint(x: 0, y: size.height))
                        diag.addLine(to: CGPoint(x: size.width, y: 0))
                        context.stroke(diag, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Curve polyline through the 5 control points
                        let viewPoints = curve.points.map { pt in
                            CGPoint(x: pt.x * size.width, y: (1.0 - pt.y) * size.height)
                        }
                        if viewPoints.count == 5 {
                            var curvePath = Path()
                            curvePath.move(to: viewPoints[0])
                            for i in 0..<4 {
                                let p0 = viewPoints[max(0, i - 1)]
                                let p1 = viewPoints[i]
                                let p2 = viewPoints[i + 1]
                                let p3 = viewPoints[min(4, i + 2)]
                                let cp1 = CGPoint(
                                    x: p1.x + (p2.x - p0.x) / 6.0,
                                    y: min(max(p1.y + (p2.y - p0.y) / 6.0, 0), size.height)
                                )
                                let cp2 = CGPoint(
                                    x: p2.x - (p3.x - p1.x) / 6.0,
                                    y: min(max(p2.y - (p3.y - p1.y) / 6.0, 0), size.height)
                                )
                                curvePath.addCurve(to: p2, control1: cp1, control2: cp2)
                            }
                            context.stroke(curvePath, with: .color(.accentColor), lineWidth: 2)
                        }
                    }

                    // 5 draggable handles
                    ForEach(0..<5, id: \.self) { index in
                        let pt = point(at: index)
                        let viewPos = CGPoint(x: pt.x * w, y: (1.0 - pt.y) * h)
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: 11, height: 11)
                            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                            .position(viewPos)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let normY = min(max(1.0 - (value.location.y / max(h, 1)), 0.0), 1.0)
                                        let minX: CGFloat = index == 0 ? 0.0 : (point(at: index - 1).x + 0.04)
                                        let maxX: CGFloat = index == 4 ? 1.0 : (point(at: index + 1).x - 0.04)
                                        let normX = (index == 0 || index == 4)
                                            ? (index == 0 ? 0.0 : 1.0)
                                            : min(max(value.location.x / max(w, 1), minX), maxX)
                                        setPoint(CGPoint(x: normX, y: normY), at: index)
                                    }
                            )
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )
            }
            .frame(height: graphHeight)

            HStack(spacing: 6) {
                Button("S-Curve") {
                    curve = ToneCurveSpec(
                        point0: CGPoint(x: 0.0, y: 0.0),
                        point1: CGPoint(x: 0.25, y: 0.18),
                        point2: CGPoint(x: 0.5, y: 0.5),
                        point3: CGPoint(x: 0.75, y: 0.82),
                        point4: CGPoint(x: 1.0, y: 1.0)
                    )
                }
                Button("Lift") {
                    curve = ToneCurveSpec(
                        point0: CGPoint(x: 0.0, y: 0.08),
                        point1: CGPoint(x: 0.25, y: 0.34),
                        point2: CGPoint(x: 0.5, y: 0.6),
                        point3: CGPoint(x: 0.75, y: 0.84),
                        point4: CGPoint(x: 1.0, y: 1.0)
                    )
                }
                Spacer()
                Button("Apply Curve") {
                    onApply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(curve.isIdentity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func point(at index: Int) -> CGPoint {
        switch index {
        case 0: curve.point0
        case 1: curve.point1
        case 2: curve.point2
        case 3: curve.point3
        default: curve.point4
        }
    }

    private func setPoint(_ pt: CGPoint, at index: Int) {
        switch index {
        case 0: curve.point0 = pt
        case 1: curve.point1 = pt
        case 2: curve.point2 = pt
        case 3: curve.point3 = pt
        default: curve.point4 = pt
        }
    }
}
