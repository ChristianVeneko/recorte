import AppKit
import SwiftUI

/// Bridges AppKit trackpad events (two-finger scroll pan, smart zoom double-tap, two-finger rotation)
/// directly to `CanvasStageView` in SwiftUI top-left stage coordinates without interfering with SwiftUI ScrollViews.
struct TrackpadGestureBridge: NSViewRepresentable {
    let onPan: @MainActor (CGSize) -> Void
    let onSmartZoom: @MainActor (CGPoint) -> Void
    let onRotate: @MainActor (Double, NSEvent.Phase) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPan: onPan, onSmartZoom: onSmartZoom, onRotate: onRotate)
    }

    func makeNSView(context: Context) -> FlippedTrackpadHostView {
        let view = FlippedTrackpadHostView()
        context.coordinator.hostView = view
        context.coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: FlippedTrackpadHostView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onPan = onPan
        context.coordinator.onSmartZoom = onSmartZoom
        context.coordinator.onRotate = onRotate
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: FlippedTrackpadHostView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class FlippedTrackpadHostView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var hostView: FlippedTrackpadHostView?
        var onPan: @MainActor (CGSize) -> Void
        var onSmartZoom: @MainActor (CGPoint) -> Void
        var onRotate: @MainActor (Double, NSEvent.Phase) -> Void
        private var monitor: Any?

        init(
            onPan: @escaping @MainActor (CGSize) -> Void,
            onSmartZoom: @escaping @MainActor (CGPoint) -> Void,
            onRotate: @escaping @MainActor (Double, NSEvent.Phase) -> Void
        ) {
            self.onPan = onPan
            self.onSmartZoom = onSmartZoom
            self.onRotate = onRotate
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.scrollWheel, .smartMagnify, .rotate]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self else { return event }
                return self.handleEvent(event)
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleEvent(_ event: NSEvent) -> NSEvent? {
            guard let hostView,
                  let window = hostView.window,
                  event.window === window else {
                return event
            }

            let locationInStage = hostView.convert(event.locationInWindow, from: nil)
            guard hostView.bounds.contains(locationInStage) else {
                return event
            }

            // Do not hijack scroll gestures when pointer is over an inner ScrollView (e.g. bottom document tray)
            if event.type == .scrollWheel,
               let hitView = window.contentView?.hitTest(event.locationInWindow),
               hitView.enclosingScrollView != nil {
                return event
            }

            switch event.type {
            case .scrollWheel:
                let dx: CGFloat
                let dy: CGFloat
                if event.hasPreciseScrollingDeltas {
                    dx = event.scrollingDeltaX
                    dy = event.scrollingDeltaY
                } else {
                    dx = event.scrollingDeltaX * 12.0
                    dy = event.scrollingDeltaY * 12.0
                }
                guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return event }
                onPan(CGSize(width: dx, height: dy))
                return nil

            case .smartMagnify:
                onSmartZoom(locationInStage)
                return nil

            case .rotate:
                // AppKit event.rotation is positive counterclockwise; canvas rotationDegrees is positive clockwise.
                let deltaClockwise = -Double(event.rotation)
                onRotate(deltaClockwise, event.phase)
                return nil

            default:
                return event
            }
        }
    }
}
