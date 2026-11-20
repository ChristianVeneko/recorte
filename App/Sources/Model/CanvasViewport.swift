import CoreGraphics
import Foundation

// MARK: - Canvas Viewport State (S24 Trackpad Zoom & Pan)

public struct CanvasViewport: Sendable, Equatable {
    public static let minZoom: CGFloat = 0.10
    public static let maxZoom: CGFloat = 8.0
    public static let zoomStepFactor: CGFloat = 1.25

    public var zoomScale: CGFloat = 1.0
    public var panOffset: CGSize = .zero
    public var isFitMode: Bool = true
    public var lastKnownFitScale: CGFloat = 1.0

    public init(
        zoomScale: CGFloat = 1.0,
        panOffset: CGSize = .zero,
        isFitMode: Bool = true,
        lastKnownFitScale: CGFloat = 1.0
    ) {
        self.zoomScale = Self.clampZoom(zoomScale)
        self.panOffset = panOffset
        self.isFitMode = isFitMode
        self.lastKnownFitScale = Self.clampZoom(lastKnownFitScale)
    }

    public var effectiveScale: CGFloat {
        Self.clampZoom(isFitMode ? lastKnownFitScale : zoomScale)
    }

    public var zoomPercentage: Int {
        Int((effectiveScale * 100.0).rounded())
    }

    public static func clampZoom(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minZoom), maxZoom)
    }

    public static func computeFitScale(documentSize: CGSize, availableSize: CGSize) -> CGFloat {
        let docW = max(1.0, documentSize.width)
        let docH = max(1.0, documentSize.height)
        let availW = max(80.0, availableSize.width)
        let availH = max(80.0, availableSize.height)
        return clampZoom(min(availW / docW, availH / docH, 1.0))
    }

    public mutating func updateFitScale(_ fitScale: CGFloat) {
        let clamped = Self.clampZoom(fitScale)
        if abs(lastKnownFitScale - clamped) > 0.0001 {
            lastKnownFitScale = clamped
            if isFitMode {
                zoomScale = clamped
            }
        }
    }

    public mutating func zoomToFit() {
        isFitMode = true
        zoomScale = lastKnownFitScale
        panOffset = .zero
    }

    public mutating func zoomToActualSize() {
        isFitMode = false
        zoomScale = 1.0
        panOffset = .zero
    }

    public mutating func zoomIn(around pointer: CGPoint? = nil, baseCenter: CGPoint = .zero) {
        let target = Self.clampZoom(effectiveScale * Self.zoomStepFactor)
        if let pointer {
            zoom(to: target, around: pointer, baseCenter: baseCenter)
        } else {
            isFitMode = false
            zoomScale = target
        }
    }

    public mutating func zoomOut(around pointer: CGPoint? = nil, baseCenter: CGPoint = .zero) {
        let target = Self.clampZoom(effectiveScale / Self.zoomStepFactor)
        if let pointer {
            zoom(to: target, around: pointer, baseCenter: baseCenter)
        } else {
            isFitMode = false
            zoomScale = target
        }
    }

    /// Zooms to `targetScale` while keeping the canvas point beneath `pointer` (in stage coordinates) stationary.
    public mutating func zoom(to targetScale: CGFloat, around pointer: CGPoint, baseCenter: CGPoint) {
        let oldScale = effectiveScale
        let newScale = Self.clampZoom(targetScale)
        guard oldScale > 0 else {
            isFitMode = false
            zoomScale = newScale
            return
        }
        let ratio = newScale / oldScale
        let currentCenterX = baseCenter.x + panOffset.width
        let currentCenterY = baseCenter.y + panOffset.height
        let newPanX = pointer.x - baseCenter.x - (pointer.x - currentCenterX) * ratio
        let newPanY = pointer.y - baseCenter.y - (pointer.y - currentCenterY) * ratio
        isFitMode = false
        zoomScale = newScale
        panOffset = CGSize(width: newPanX, height: newPanY)
    }

    /// Pans the canvas by `delta` in stage coordinates (two-finger trackpad scroll).
    public mutating func pan(by delta: CGSize) {
        if isFitMode {
            zoomScale = effectiveScale
            isFitMode = false
        }
        panOffset = CGSize(
            width: panOffset.width + delta.width,
            height: panOffset.height + delta.height
        )
    }

    /// Smart zoom (trackpad two-finger double-tap or canvas double-tap): toggles between Fit and 100%.
    /// If fit is already ~100% (small canvas), toggles between Fit (100%) and 200%.
    public mutating func toggleSmartZoom(around pointer: CGPoint? = nil, baseCenter: CGPoint = .zero) {
        let fit = lastKnownFitScale
        let atFit = isFitMode || abs(effectiveScale - fit) < 0.02
        if atFit {
            let target: CGFloat = abs(fit - 1.0) < 0.02 ? 2.0 : 1.0
            if let pointer {
                zoom(to: target, around: pointer, baseCenter: baseCenter)
            } else {
                isFitMode = false
                zoomScale = target
                panOffset = .zero
            }
        } else {
            zoomToFit()
        }
    }

    /// Computes the canvas frame in stage coordinates for a given document size and stage center.
    public func canvasFrame(documentSize: CGSize, baseCenter: CGPoint) -> CGRect {
        let s = effectiveScale
        let w = max(1.0, documentSize.width) * s
        let h = max(1.0, documentSize.height) * s
        let cx = baseCenter.x + panOffset.width
        let cy = baseCenter.y + panOffset.height
        return CGRect(x: cx - w / 2.0, y: cy - h / 2.0, width: w, height: h)
    }
}

// MARK: - Rotation & Shift-Snap Math (S25)

public enum RotationMath {

    /// Normalizes an angle in degrees to `(-180, 180]`, avoiding `-0.0`.
    public static func normalizeDegrees(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360.0)
        if angle > 180.0 {
            angle -= 360.0
        } else if angle <= -180.0 {
            angle += 360.0
        }
        if abs(angle) < 1e-9 {
            return 0.0
        }
        return angle
    }

    /// Applies Shift snapping to `increment` degrees (default 15°) when `isShiftPressed` is true.
    public static func snapDegrees(
        _ degrees: Double,
        increment: Double = 15.0,
        isShiftPressed: Bool
    ) -> Double {
        guard isShiftPressed, increment > 0 else {
            return normalizeDegrees(degrees)
        }
        let snapped = (degrees / increment).rounded() * increment
        return normalizeDegrees(snapped)
    }

    /// Computes clockwise layer angle in degrees when dragging the top rotation knob from `center` to `pointer`.
    public static func angleDegrees(from center: CGPoint, to pointer: CGPoint) -> Double {
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        let radians = atan2(dy, dx) + (.pi / 2.0)
        return normalizeDegrees(Double(radians * 180.0 / .pi))
    }

    /// Human-readable formatted angle string for the glass rotation badge (e.g. `"45°"`, `"-15°"`, `"0°"`).
    public static func formattedAngle(_ degrees: Double) -> String {
        let normalized = normalizeDegrees(degrees)
        let rounded = Int(normalized.rounded())
        let display = rounded == -180 ? 180 : (rounded == 0 ? 0 : rounded)
        return "\(display)°"
    }
}
