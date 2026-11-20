import AppKit
import RecorteCore
import SwiftUI

// MARK: - Lasso Cutout Overlay (S15)

struct LassoOverlayView: View {
    @Bindable var model: EditorModel
    let canvasFrame: CGRect
    let displayScale: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, _ in
                guard model.lassoPoints.count >= 2 else { return }
                let viewPts = model.lassoPoints.map { canvasToView($0) }
                var path = Path()
                path.move(to: viewPts[0])
                for pt in viewPts.dropFirst() {
                    path.addLine(to: pt)
                }
                if viewPts.count >= 3 {
                    path.closeSubpath()
                    context.fill(path, with: .color(Color.accentColor.opacity(0.16)))
                }
                context.stroke(
                    path,
                    with: .color(.white),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    path,
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [6, 4])
                )
            }
            .contentShape(Rectangle())
            .pointerStyle(CanvasCursors.crosshairPointerStyle)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvasStage"))
                    .onChanged { value in
                        let pt = viewToCanvas(value.location)
                        if value.translation == .zero {
                            model.lassoPoints = [pt]
                        } else if let last = model.lassoPoints.last,
                                  hypot(pt.x - last.x, pt.y - last.y) >= 2.0 {
                            model.lassoPoints.append(pt)
                        }
                    }
            )

            if model.lassoPoints.count >= 3 {
                HStack(spacing: 8) {
                    Text("Lasso Cutout")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                    Divider().frame(height: 14)
                    Button {
                        model.lassoPoints = []
                    } label: {
                        Text("Clear")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Button {
                        do {
                            try model.applyLassoCutout(
                                points: model.lassoPoints,
                                cropToBounds: model.lassoCropToBounds
                            )
                        } catch {
                            model.lastErrorMessage = "Lasso cutout failed. Trace a region on an unlocked image layer."
                        }
                    } label: {
                        Text("Cut Out")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .fixedSize(horizontal: true, vertical: true)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                .padding(.top, 14)
            }
        }
    }

    private func canvasToView(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasFrame.minX + pt.x * displayScale,
            y: canvasFrame.minY + pt.y * displayScale
        )
    }

    private func viewToCanvas(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: (pt.x - canvasFrame.minX) / max(displayScale, 0.01),
            y: (pt.y - canvasFrame.minY) / max(displayScale, 0.01)
        )
    }
}

// MARK: - Clone Stamp Overlay (S15)

struct CloneStampOverlayView: View {
    @Bindable var model: EditorModel
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var strokeStartSource: CGPoint?
    @State private var strokeStartDest: CGPoint?
    @State private var currentHoverDest: CGPoint?
    @State private var didStampInCurrentDrag: Bool = false

    var body: some View {
        ZStack {
            Canvas { context, _ in
                // Draw source crosshair
                if let src = model.cloneSourcePoint {
                    let pt = canvasToView(src)
                    let r = max(8, CGFloat(model.cloneRadius) * displayScale)
                    var circle = Path()
                    circle.addEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                    context.stroke(circle, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    context.stroke(circle, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    var cross = Path()
                    cross.move(to: CGPoint(x: pt.x - 8, y: pt.y))
                    cross.addLine(to: CGPoint(x: pt.x + 8, y: pt.y))
                    cross.move(to: CGPoint(x: pt.x, y: pt.y - 8))
                    cross.addLine(to: CGPoint(x: pt.x, y: pt.y + 8))
                    context.stroke(cross, with: .color(.accentColor), lineWidth: 1.5)
                }

                // Draw active brush circle
                if let dest = currentHoverDest {
                    let pt = canvasToView(dest)
                    let r = max(6, CGFloat(model.cloneRadius) * displayScale)
                    var circle = Path()
                    circle.addEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                    context.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(CanvasCursors.crosshairPointerStyle)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvasStage"))
                    .onChanged { value in
                        let canvasPt = viewToCanvas(value.location)
                        if NSEvent.modifierFlags.contains(.option) {
                            model.cloneSourcePoint = canvasPt
                            strokeStartSource = nil
                            strokeStartDest = nil
                            return
                        }

                        guard let baseSource = model.cloneSourcePoint else {
                            model.lastErrorMessage = "Option-click on the image first to set the clone source."
                            return
                        }

                        currentHoverDest = canvasPt
                        if strokeStartDest == nil {
                            strokeStartDest = canvasPt
                            strokeStartSource = baseSource
                        }
                        let offsetX = canvasPt.x - (strokeStartDest?.x ?? canvasPt.x)
                        let offsetY = canvasPt.y - (strokeStartDest?.y ?? canvasPt.y)
                        let activeSource = CGPoint(
                            x: (strokeStartSource?.x ?? baseSource.x) + offsetX,
                            y: (strokeStartSource?.y ?? baseSource.y) + offsetY
                        )

                        do {
                            try model.applyCloneStamp(
                                from: activeSource,
                                to: canvasPt,
                                radius: CGFloat(model.cloneRadius),
                                softness: CGFloat(model.cloneSoftness),
                                opacity: CGFloat(model.cloneOpacity),
                                continuous: true
                            )
                            didStampInCurrentDrag = true
                        } catch {
                            model.lastErrorMessage = "Clone stamp requires an unlocked image layer."
                        }
                    }
                    .onEnded { _ in
                        if didStampInCurrentDrag {
                            model.endContinuousEdit(actionName: "Clone Stamp")
                            didStampInCurrentDrag = false
                        }
                        strokeStartDest = nil
                        strokeStartSource = nil
                        currentHoverDest = nil
                    }
            )
        }
    }

    private func canvasToView(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasFrame.minX + pt.x * displayScale,
            y: canvasFrame.minY + pt.y * displayScale
        )
    }

    private func viewToCanvas(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: (pt.x - canvasFrame.minX) / max(displayScale, 0.01),
            y: (pt.y - canvasFrame.minY) / max(displayScale, 0.01)
        )
    }
}

// MARK: - Perspective 4-Corner Overlay (S15)

struct PerspectiveOverlayView: View {
    @Bindable var model: EditorModel
    let quad: PerspectiveQuad
    let canvasFrame: CGRect
    let displayScale: CGFloat

    private var tl: CGPoint { canvasToView(quad.topLeft) }
    private var tr: CGPoint { canvasToView(quad.topRight) }
    private var br: CGPoint { canvasToView(quad.bottomRight) }
    private var bl: CGPoint { canvasToView(quad.bottomLeft) }

    var body: some View {
        ZStack(alignment: .top) {
            // Quad outline + 3x3 grid
            Canvas { context, _ in
                var border = Path()
                border.move(to: tl)
                border.addLine(to: tr)
                border.addLine(to: br)
                border.addLine(to: bl)
                border.closeSubpath()

                context.stroke(border, with: .color(.white), lineWidth: 2.0)
                context.stroke(border, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))

                var grid = Path()
                for t in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                    let topPt = lerp(tl, tr, t)
                    let botPt = lerp(bl, br, t)
                    grid.move(to: topPt)
                    grid.addLine(to: botPt)

                    let leftPt = lerp(tl, bl, t)
                    let rightPt = lerp(tr, br, t)
                    grid.move(to: leftPt)
                    grid.addLine(to: rightPt)
                }
                context.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.75)
            }
            .allowsHitTesting(false)

            cornerHandle(position: tl, label: "TL") { newCanvasPt in
                var next = quad
                next.topLeft = newCanvasPt
                model.perspectiveQuad = next
            }
            cornerHandle(position: tr, label: "TR") { newCanvasPt in
                var next = quad
                next.topRight = newCanvasPt
                model.perspectiveQuad = next
            }
            cornerHandle(position: br, label: "BR") { newCanvasPt in
                var next = quad
                next.bottomRight = newCanvasPt
                model.perspectiveQuad = next
            }
            cornerHandle(position: bl, label: "BL") { newCanvasPt in
                var next = quad
                next.bottomLeft = newCanvasPt
                model.perspectiveQuad = next
            }

            HStack(spacing: 8) {
                Text("Perspective")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                Divider().frame(height: 14)
                Button {
                    model.resetPerspective()
                } label: {
                    Text("Reset")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button {
                    model.cancelPerspective()
                } label: {
                    Text("Cancel")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button {
                    do {
                        try model.applyPerspective()
                    } catch {
                        model.lastErrorMessage = "Perspective correction failed."
                    }
                } label: {
                    Text("Apply")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: true)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .padding(.top, 14)
        }
    }

    private func cornerHandle(
        position: CGPoint,
        label: String,
        onMove: @escaping (CGPoint) -> Void
    ) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .position(position)
            .pointerStyle(.grabIdle)
            .accessibilityLabel("Perspective Corner \(label)")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvasStage"))
                    .onChanged { value in
                        onMove(viewToCanvas(value.location))
                    }
            )
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func canvasToView(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasFrame.minX + pt.x * displayScale,
            y: canvasFrame.minY + pt.y * displayScale
        )
    }

    private func viewToCanvas(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: (pt.x - canvasFrame.minX) / max(displayScale, 0.01),
            y: (pt.y - canvasFrame.minY) / max(displayScale, 0.01)
        )
    }
}

// MARK: - Deform Liquify Brush Overlay (S15, S26)

struct DeformOverlayView: View {
    @Bindable var model: EditorModel
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var pointerLocation: CGPoint?
    @State private var isDragging: Bool = false
    @State private var isHoveringBar: Bool = false
    @State private var hasPushedCrosshair: Bool = false

    var body: some View {
        let state = model.deformState

        ZStack(alignment: .top) {
            // Interactive liquify brush capture surface
            Color.clear
                .contentShape(Rectangle())
                .pointerStyle(isHoveringBar ? nil : CanvasCursors.crosshairPointerStyle)
                .onContinuousHover(coordinateSpace: .named("canvasStage")) { phase in
                    switch phase {
                    case .active(let location):
                        pointerLocation = location
                        updateCrosshairCursor(active: !isHoveringBar)
                    case .ended:
                        if !isDragging {
                            pointerLocation = nil
                        }
                        updateCrosshairCursor(active: false)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvasStage"))
                        .onChanged { value in
                            pointerLocation = value.location
                            let canvasPt = viewToCanvas(value.location)
                            if !isDragging {
                                isDragging = true
                                model.beginDeformStroke(at: canvasPt)
                            } else {
                                model.continueDeformStroke(to: canvasPt)
                            }
                        }
                        .onEnded { _ in
                            if isDragging {
                                isDragging = false
                                model.endDeformStroke()
                            }
                        }
                )

            // Crosshair circle cursor sized accurately to the deform brush radius
            Canvas { context, _ in
                guard let location = pointerLocation, !isHoveringBar else { return }
                let radius = max(4.0, CGFloat(model.deformRadius) * displayScale)
                let diameter = radius * 2.0
                let outerRect = CGRect(
                    x: location.x - radius,
                    y: location.y - radius,
                    width: diameter,
                    height: diameter
                )
                let outerCircle = Path(ellipseIn: outerRect)
                let innerStrokeColor: Color = isDragging ? .accentColor : .white

                // Dual high-contrast stroke visible on both light and dark canvas pixels
                context.stroke(outerCircle, with: .color(.black.opacity(0.65)), lineWidth: 2.2)
                context.stroke(outerCircle, with: .color(innerStrokeColor.opacity(0.95)), lineWidth: 1.2)

                // Subtle falloff ring at 50% radius for larger brushes
                if radius >= 18.0 {
                    let midR = radius * 0.5
                    let midRect = CGRect(
                        x: location.x - midR,
                        y: location.y - midR,
                        width: midR * 2.0,
                        height: midR * 2.0
                    )
                    context.stroke(
                        Path(ellipseIn: midRect),
                        with: .color(innerStrokeColor.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
                    )
                }

                // Crisp center crosshair (+)
                let arm = min(6.0, max(3.5, radius * 0.22))
                var cross = Path()
                cross.move(to: CGPoint(x: location.x - arm, y: location.y))
                cross.addLine(to: CGPoint(x: location.x + arm, y: location.y))
                cross.move(to: CGPoint(x: location.x, y: location.y - arm))
                cross.addLine(to: CGPoint(x: location.x, y: location.y + arm))
                context.stroke(cross, with: .color(.black.opacity(0.65)), lineWidth: 2.0)
                context.stroke(cross, with: .color(innerStrokeColor.opacity(0.95)), lineWidth: 1.0)
            }
            .allowsHitTesting(false)

            // Floating Liquid Glass controls bar (Modes, Size, Strength, Done)
            deformFloatingGlassBar(state: state)
                .padding(.top, 14)
        }
        .onChange(of: model.deformPreset) { _, newPreset in
            let mapped = DeformBrushMode(preset: newPreset)
            if state.mode != .push && state.mode != mapped {
                state.mode = mapped
            }
        }
        .onDisappear {
            if isDragging {
                isDragging = false
                model.endDeformStroke()
            }
            updateCrosshairCursor(active: false)
        }
    }

    @ViewBuilder
    private func deformFloatingGlassBar(state: DeformBrushState) -> some View {
        let sizeBinding = Binding<Double>(
            get: { model.deformBrushSize },
            set: { model.deformBrushSize = $0 }
        )

        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 8) {
                // Mode buttons: Push, Bulge, Pinch, Twirl
                HStack(spacing: 2) {
                    ForEach(DeformBrushMode.allCases, id: \.self) { mode in
                        deformModeButton(mode: mode, state: state)
                    }
                }

                Divider()
                    .frame(height: 16)

                // Brush Size slider (diameter in px)
                HStack(spacing: 5) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()

                    Slider(value: sizeBinding, in: 20...600)
                        .controlSize(.small)
                        .frame(width: 78)
                        .accessibilityLabel("Deform Brush Size")

                    Text("\(Int(model.deformBrushSize.rounded()))px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 40, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize()
                }

                Divider()
                    .frame(height: 16)

                // Brush Strength slider
                HStack(spacing: 5) {
                    Text("Strength")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()

                    Slider(value: $model.deformStrength, in: 0.05...1.0)
                        .controlSize(.small)
                        .frame(width: 68)
                        .accessibilityLabel("Deform Brush Strength")

                    Text("\(Int((model.deformStrength * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 34, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize()
                }

                Divider()
                    .frame(height: 16)

                Button {
                    model.activeTool = .move
                } label: {
                    Text("Done")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Finish Deforming (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: true)
            .glassEffect(.regular, in: .capsule)
        }
        .onHover { hovering in
            isHoveringBar = hovering
            if hovering {
                updateCrosshairCursor(active: false)
            }
        }
    }

    private func deformModeButton(mode: DeformBrushMode, state: DeformBrushState) -> some View {
        let isSelected = state.mode == mode
        return Button {
            model.deformMode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                    .font(.caption)
                Text(mode.displayName)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(mode.displayName) Mode")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func updateCrosshairCursor(active: Bool) {
        if active && !hasPushedCrosshair {
            NSCursor.crosshair.push()
            hasPushedCrosshair = true
        } else if !active && hasPushedCrosshair {
            NSCursor.pop()
            hasPushedCrosshair = false
        }
    }

    private func viewToCanvas(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: (pt.x - canvasFrame.minX) / max(displayScale, 0.01),
            y: (pt.y - canvasFrame.minY) / max(displayScale, 0.01)
        )
    }
}
