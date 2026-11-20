import RecorteCore
import SwiftUI

struct CropOverlayView: View {
    let model: EditorModel
    let spec: CropSpec
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var dragStartRect: CGRect?

    private var cropViewRect: CGRect {
        CGRect(
            x: canvasFrame.minX + spec.rect.minX * displayScale,
            y: canvasFrame.minY + spec.rect.minY * displayScale,
            width: spec.rect.width * displayScale,
            height: spec.rect.height * displayScale
        )
    }

    private func swiftUIShapePath(in rect: CGRect) -> Path {
        let cgPath = Cropper.maskPath(for: spec.shape, in: rect)
        // Cropper.maskPath uses CG bottom-left coordinates for asymmetric shapes like .heart;
        // flip vertically around the rect midpoint so SwiftUI preview matches cropped CGImage output.
        var flip = CGAffineTransform(translationX: 0, y: rect.minY + rect.maxY)
            .scaledBy(x: 1, y: -1)
        if let flipped = cgPath.copy(using: &flip) {
            return Path(flipped)
        }
        return Path(cgPath)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed scrim outside the active crop shape
            Path { path in
                path.addRect(canvasFrame)
                path.addPath(swiftUIShapePath(in: cropViewRect))
            }
            .fill(Color.black.opacity(0.52), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Shape mask outline
            swiftUIShapePath(in: cropViewRect)
                .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
                .allowsHitTesting(false)

            // Interactive crop rectangle with rule-of-thirds and 8 handles
            ZStack {
                // Drag inside to pan crop box
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .gesture(panCropGesture)

                // Rule-of-thirds grid
                RuleOfThirdsGrid()
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.75)
                    .allowsHitTesting(false)

                // Outer frame
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .allowsHitTesting(false)

                // 4 Corner handles
                cropHandleView(isCorner: true)
                    .position(x: 0, y: 0)
                    .gesture(resizeHandleGesture(edge: .topLeft))
                cropHandleView(isCorner: true)
                    .position(x: cropViewRect.width, y: 0)
                    .gesture(resizeHandleGesture(edge: .topRight))
                cropHandleView(isCorner: true)
                    .position(x: 0, y: cropViewRect.height)
                    .gesture(resizeHandleGesture(edge: .bottomLeft))
                cropHandleView(isCorner: true)
                    .position(x: cropViewRect.width, y: cropViewRect.height)
                    .gesture(resizeHandleGesture(edge: .bottomRight))

                // 4 Edge midpoint handles
                cropHandleView(isCorner: false)
                    .position(x: cropViewRect.width / 2, y: 0)
                    .gesture(resizeHandleGesture(edge: .top))
                cropHandleView(isCorner: false)
                    .position(x: cropViewRect.width / 2, y: cropViewRect.height)
                    .gesture(resizeHandleGesture(edge: .bottom))
                cropHandleView(isCorner: false)
                    .position(x: 0, y: cropViewRect.height / 2)
                    .gesture(resizeHandleGesture(edge: .left))
                cropHandleView(isCorner: false)
                    .position(x: cropViewRect.width, y: cropViewRect.height / 2)
                    .gesture(resizeHandleGesture(edge: .right))
            }
            .frame(width: max(20, cropViewRect.width), height: max(20, cropViewRect.height))
            .position(x: cropViewRect.midX, y: cropViewRect.midY)

            // Floating crop quick bar at the top of the canvas
            cropFloatingBar
                .padding(.top, 14)
        }
    }

    private var cropFloatingBar: some View {
        HStack(spacing: 6) {
            // Compact shape picker buttons (aspect ratio & rotation live in the inspector)
            HStack(spacing: 2) {
                ForEach(CropShapePreset.allCases) { preset in
                    Button {
                        model.updateCropShape(preset.toCropShape(current: spec.shape))
                    } label: {
                        Image(systemName: preset.systemImage)
                            .font(.caption)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .background(
                        preset.matches(spec.shape) ? Color.accentColor : Color.clear,
                        in: Capsule()
                    )
                    .foregroundStyle(preset.matches(spec.shape) ? Color.white : Color.primary)
                    .help(preset.label)
                    .accessibilityLabel(preset.label)
                }
            }

            Divider()
                .frame(height: 16)

            Button {
                model.cancelCrop()
            } label: {
                Text("Cancel")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Cancel Crop (Esc)")

            Button {
                try? model.applyCrop()
            } label: {
                Text("Done")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Apply Crop (Return)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: true)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private func cropHandleView(isCorner: Bool) -> some View {
        RoundedRectangle(cornerRadius: isCorner ? 3 : 2, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: isCorner ? 3 : 2, style: .continuous)
                    .stroke(Color.black.opacity(0.35), lineWidth: 1)
            )
            .frame(width: isCorner ? 12 : 10, height: isCorner ? 12 : 10)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private var panCropGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                let start = dragStartRect ?? spec.rect
                if dragStartRect == nil { dragStartRect = start }

                let dx = value.translation.width / max(displayScale, 0.01)
                let dy = value.translation.height / max(displayScale, 0.01)
                let maxX = max(0, model.document.canvasSize.width - start.width)
                let maxY = max(0, model.document.canvasSize.height - start.height)
                let nextRect = CGRect(
                    x: min(max(start.minX + dx, 0), maxX),
                    y: min(max(start.minY + dy, 0), maxY),
                    width: start.width,
                    height: start.height
                )
                model.updateCropRect(nextRect)
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private enum HandleEdge {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    private func resizeHandleGesture(edge: HandleEdge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasStage"))
            .onChanged { value in
                let start = dragStartRect ?? spec.rect
                if dragStartRect == nil { dragStartRect = start }

                let dx = value.translation.width / max(displayScale, 0.01)
                let dy = value.translation.height / max(displayScale, 0.01)
                let minSize: CGFloat = 16
                let canvasW = model.document.canvasSize.width
                let canvasH = model.document.canvasSize.height

                var minX = start.minX
                var maxX = start.maxX
                var minY = start.minY
                var maxY = start.maxY

                switch edge {
                case .topLeft:
                    minX = min(max(0, start.minX + dx), start.maxX - minSize)
                    minY = min(max(0, start.minY + dy), start.maxY - minSize)
                case .topRight:
                    maxX = max(min(canvasW, start.maxX + dx), start.minX + minSize)
                    minY = min(max(0, start.minY + dy), start.maxY - minSize)
                case .bottomLeft:
                    minX = min(max(0, start.minX + dx), start.maxX - minSize)
                    maxY = max(min(canvasH, start.maxY + dy), start.minY + minSize)
                case .bottomRight:
                    maxX = max(min(canvasW, start.maxX + dx), start.minX + minSize)
                    maxY = max(min(canvasH, start.maxY + dy), start.minY + minSize)
                case .top:
                    minY = min(max(0, start.minY + dy), start.maxY - minSize)
                case .bottom:
                    maxY = max(min(canvasH, start.maxY + dy), start.minY + minSize)
                case .left:
                    minX = min(max(0, start.minX + dx), start.maxX - minSize)
                case .right:
                    maxX = max(min(canvasW, start.maxX + dx), start.minX + minSize)
                }

                let proposed = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                model.updateCropRect(proposed)
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }
}

private struct RuleOfThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

extension CropAspect {
    var shortLabel: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .ratio1x1: "1:1"
        case .ratio4x3: "4:3"
        case .ratio3x4: "3:4"
        case .ratio16x9: "16:9"
        case .ratio9x16: "9:16"
        }
    }
}

enum CropShapePreset: String, CaseIterable, Identifiable {
    case rectangle
    case roundedRect
    case ellipse
    case star
    case heart

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRect: "Rounded"
        case .ellipse: "Ellipse"
        case .star: "Star"
        case .heart: "Heart"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .roundedRect: "rectangle.roundedtop"
        case .ellipse: "circle"
        case .star: "star"
        case .heart: "heart"
        }
    }

    func matches(_ shape: CropShape) -> Bool {
        switch (self, shape) {
        case (.rectangle, .rectangle): true
        case (.roundedRect, .roundedRect): true
        case (.ellipse, .ellipse): true
        case (.star, .star): true
        case (.heart, .heart): true
        default: false
        }
    }

    func toCropShape(current: CropShape) -> CropShape {
        switch self {
        case .rectangle: return .rectangle
        case .roundedRect:
            if case .roundedRect(let r) = current { return .roundedRect(radius: r) }
            return .roundedRect(radius: 24)
        case .ellipse: return .ellipse
        case .star: return .star
        case .heart: return .heart
        }
    }
}
