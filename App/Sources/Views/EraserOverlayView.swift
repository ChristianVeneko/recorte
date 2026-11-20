import AppKit
import RecorteCore
import SwiftUI

/// Interactive canvas overlay for the manual brush eraser tool (S23).
/// Provides smooth mouse/trackpad brush strokes, a live brush-sized circle cursor preview,
/// and an inspector-free floating Liquid Glass control bar (Erase/Restore, Size, Hardness).
struct EraserOverlayView: View {
    @Bindable var model: EditorModel
    let canvasFrame: CGRect
    let displayScale: CGFloat

    @State private var pointerLocation: CGPoint?
    @State private var isDragging: Bool = false
    @State private var isHoveringBar: Bool = false
    @State private var hasPushedCrosshair: Bool = false

    var body: some View {
        let state = model.eraserState

        ZStack(alignment: .top) {
            // Interactive stroke capture layer (mouse & trackpad drag/tap)
            Color.clear
                .contentShape(Rectangle())
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
                                model.beginEraserStroke(at: canvasPt)
                            } else {
                                model.continueEraserStroke(to: canvasPt)
                            }
                        }
                        .onEnded { _ in
                            if isDragging {
                                model.endEraserStrokeInBackground()
                                isDragging = false
                            }
                        }
                )

            // Circle brush cursor preview following the pointer at exact scaled brush size
            Canvas { context, _ in
                guard let location = pointerLocation, !isHoveringBar else { return }
                let diameter = max(4.0, CGFloat(state.brushSize) * displayScale)
                let radius = diameter * 0.5
                let outerRect = CGRect(
                    x: location.x - radius,
                    y: location.y - radius,
                    width: diameter,
                    height: diameter
                )
                let outerCircle = Path(ellipseIn: outerRect)

                let accentStroke: Color = state.mode == .restore ? .green : .white

                // Dual high-contrast stroke so cursor stays visible on both light and dark pixels
                context.stroke(outerCircle, with: .color(.black.opacity(0.65)), lineWidth: 2.2)
                context.stroke(outerCircle, with: .color(accentStroke.opacity(0.95)), lineWidth: 1.2)

                // Softness inner core ring preview when hardness < 1
                if state.hardness < 0.98, diameter >= 14.0 {
                    let innerRadius = max(1.5, radius * CGFloat(state.hardness))
                    let innerRect = CGRect(
                        x: location.x - innerRadius,
                        y: location.y - innerRadius,
                        width: innerRadius * 2.0,
                        height: innerRadius * 2.0
                    )
                    let innerCircle = Path(ellipseIn: innerRect)
                    context.stroke(
                        innerCircle,
                        with: .color(accentStroke.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
                    )
                }

                // Subtle center indicator (+ for Restore, tiny dot for Erase)
                if state.mode == .restore {
                    var plus = Path()
                    let arm: CGFloat = 3.5
                    plus.move(to: CGPoint(x: location.x - arm, y: location.y))
                    plus.addLine(to: CGPoint(x: location.x + arm, y: location.y))
                    plus.move(to: CGPoint(x: location.x, y: location.y - arm))
                    plus.addLine(to: CGPoint(x: location.x, y: location.y + arm))
                    context.stroke(plus, with: .color(.black.opacity(0.6)), lineWidth: 2.0)
                    context.stroke(plus, with: .color(.green), lineWidth: 1.0)
                } else if diameter >= 12.0 {
                    let dotRect = CGRect(x: location.x - 1.25, y: location.y - 1.25, width: 2.5, height: 2.5)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.85)))
                }
            }
            .allowsHitTesting(false)

            // Inspector-free floating Liquid Glass controls bar
            eraserFloatingGlassBar(state: state)
                .padding(.top, 14)
        }
        .onDisappear {
            if isDragging {
                model.endEraserStrokeInBackground()
                isDragging = false
            }
            updateCrosshairCursor(active: false)
        }
    }

    @ViewBuilder
    private func eraserFloatingGlassBar(state: EraserState) -> some View {
        @Bindable var bindableState = state

        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 8) {
                // Erase / Restore toggle
                HStack(spacing: 2) {
                    modeButton(
                        title: "Erase",
                        systemImage: "eraser",
                        mode: .erase,
                        activeColor: .accentColor,
                        state: state
                    )
                    modeButton(
                        title: "Restore",
                        systemImage: "arrow.uturn.backward.circle",
                        mode: .restore,
                        activeColor: .green,
                        state: state
                    )
                }

                Divider()
                    .frame(height: 16)

                // Brush Size slider
                HStack(spacing: 5) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()

                    Slider(value: $bindableState.brushSize, in: 4...200)
                        .controlSize(.small)
                        .frame(width: 78)
                        .accessibilityLabel("Brush Size")

                    Text("\(Int(state.brushSize.rounded()))px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 36, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize()
                }

                Divider()
                    .frame(height: 16)

                // Brush Hardness slider
                HStack(spacing: 5) {
                    Text("Hard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()

                    Slider(value: $bindableState.hardness, in: 0...1)
                        .controlSize(.small)
                        .frame(width: 66)
                        .accessibilityLabel("Brush Hardness")

                    Text("\(Int((state.hardness * 100).rounded()))%")
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
                .help("Finish Erasing (Esc)")
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

    private func modeButton(
        title: String,
        systemImage: String,
        mode: EraserMode,
        activeColor: Color,
        state: EraserState
    ) -> some View {
        let isSelected = state.mode == mode
        return Button {
            state.mode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? activeColor : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) Mode (X to toggle)")
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

// MARK: - Window-Scoped Keyboard Shortcut Bridge for Eraser (E, [, ], X, Esc)

struct EraserShortcutBridge: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = EraserShortcutHostView()
        let coordinator = context.coordinator
        view.onWindowChanged = { [weak coordinator] window in
            coordinator?.hostWindow = window
        }
        coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        if let window = nsView.window {
            context.coordinator.hostWindow = window
        }
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var model: EditorModel
        weak var hostWindow: NSWindow?
        private var monitor: Any?

        init(model: EditorModel) {
            self.model = model
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyEvent(event)
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
            guard let hostWindow, event.window === hostWindow else { return event }
            if hostWindow.firstResponder is NSTextView {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            if event.keyCode == 53, model.activeTool == .eraser {
                model.endEraserStrokeInBackground()
                model.activeTool = .move
                return nil
            }

            guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch chars {
            case "e":
                if model.hasEditableImageLayer {
                    model.activeTool = .eraser
                }
                return nil
            case "[" where model.activeTool == .eraser:
                model.eraserBrushSize = max(4.0, model.eraserBrushSize - 6.0)
                return nil
            case "]" where model.activeTool == .eraser:
                model.eraserBrushSize = min(200.0, model.eraserBrushSize + 6.0)
                return nil
            case "x" where model.activeTool == .eraser:
                model.eraserMode = model.eraserMode == .erase ? .restore : .erase
                return nil
            default:
                return event
            }
        }
    }
}

private final class EraserShortcutHostView: NSView {
    var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}
