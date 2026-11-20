import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Context Cursor Logic (S25)

public enum ResizeHandlePosition: String, Sendable, Equatable, CaseIterable {
    case topLeading
    case top
    case topTrailing
    case trailing
    case bottomTrailing
    case bottom
    case bottomLeading
    case leading

    public var frameResizePosition: FrameResizePosition {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .trailing: .trailing
        case .bottomTrailing: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeading: .bottomLeading
        case .leading: .leading
        }
    }
}

public enum CanvasCursorLogic {

    /// Maps an unrotated handle direction (`baseAngleDegrees`, where 0° = right, 90° = down, 180° = left, 270° = up)
    /// plus the layer's clockwise rotation to the matching 8-way resize handle orientation.
    public static func resizePosition(
        baseAngleDegrees: Double,
        layerRotationDegrees: Double = 0.0
    ) -> ResizeHandlePosition {
        var total = (baseAngleDegrees + layerRotationDegrees).truncatingRemainder(dividingBy: 360.0)
        if total < 0 { total += 360.0 }
        let sector = Int(((total + 22.5) / 45.0).rounded(.down)) % 8
        switch sector {
        case 0: return .trailing
        case 1: return .bottomTrailing
        case 2: return .bottom
        case 3: return .bottomLeading
        case 4: return .leading
        case 5: return .topLeading
        case 6: return .top
        default: return .topTrailing
        }
    }

    /// Maps a selection corner (`xSign`, `ySign` in `{-1, 1}`) and layer rotation to the matching resize cursor orientation.
    public static func resizePosition(
        xSign: CGFloat,
        ySign: CGFloat,
        layerRotationDegrees: Double = 0.0
    ) -> ResizeHandlePosition {
        let baseAngle = Double(atan2(ySign, xSign) * 180.0 / .pi)
        return resizePosition(baseAngleDegrees: baseAngle, layerRotationDegrees: layerRotationDegrees)
    }
}

@MainActor
public enum CanvasCursors {

    public static let crosshairPointerStyle: PointerStyle = .rectSelection

    public static func resizePointerStyle(for position: ResizeHandlePosition) -> PointerStyle {
        .frameResize(position: position.frameResizePosition)
    }

    /// Crisp custom curved double-arrow rotate cursor matching native macOS graphics apps.
    public static let rotateCursorImage: NSImage = {
        let logicalSize: CGFloat = 20
        let scale: CGFloat = 2
        let px = Int(logicalSize * scale)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: px,
            height: px,
            bitsPerComponent: 8,
            bytesPerRow: px * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise", accessibilityDescription: "Rotate")
                ?? NSImage(size: NSSize(width: logicalSize, height: logicalSize))
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let center = CGPoint(x: logicalSize / 2.0, y: logicalSize / 2.0)
        let radius: CGFloat = 6.0

        func buildRotateArrowPath() -> CGPath {
            let path = CGMutablePath()
            // Top-right curved arc (from ~165° to ~15° in CG bottom-left space = curved top arc)
            let startAngle: CGFloat = .pi * 0.82
            let endAngle: CGFloat = .pi * 0.14
            path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)

            // Arrowhead at start (left-top)
            let p1 = CGPoint(x: center.x + radius * cos(startAngle), y: center.y + radius * sin(startAngle))
            let t1 = startAngle + .pi / 2.0 // tangent pointing counter-clockwise
            path.move(to: p1)
            path.addLine(to: CGPoint(x: p1.x + 3.6 * cos(t1 + 0.55), y: p1.y + 3.6 * sin(t1 + 0.55)))
            path.move(to: p1)
            path.addLine(to: CGPoint(x: p1.x + 3.6 * cos(t1 - 0.55), y: p1.y + 3.6 * sin(t1 - 0.55)))

            // Arrowhead at end (right-top)
            let p2 = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
            let t2 = endAngle - .pi / 2.0 // tangent pointing clockwise
            path.move(to: p2)
            path.addLine(to: CGPoint(x: p2.x + 3.6 * cos(t2 + 0.55), y: p2.y + 3.6 * sin(t2 + 0.55)))
            path.move(to: p2)
            path.addLine(to: CGPoint(x: p2.x + 3.6 * cos(t2 - 0.55), y: p2.y + 3.6 * sin(t2 - 0.55)))

            // Bottom curved arc
            let bStart: CGFloat = -.pi * 0.18
            let bEnd: CGFloat = -.pi * 0.86
            path.move(to: CGPoint(x: center.x + radius * cos(bStart), y: center.y + radius * sin(bStart)))
            path.addArc(center: center, radius: radius, startAngle: bStart, endAngle: bEnd, clockwise: true)

            return path
        }

        let arrowPath = buildRotateArrowPath()

        // White halo for contrast on dark backgrounds
        ctx.addPath(arrowPath)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(3.4)
        ctx.strokePath()

        // Crisp black inner stroke for contrast on light backgrounds
        ctx.addPath(arrowPath)
        ctx.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0))
        ctx.setLineWidth(1.6)
        ctx.strokePath()

        guard let cgImage = ctx.makeImage() else {
            return NSImage(size: NSSize(width: logicalSize, height: logicalSize))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: logicalSize, height: logicalSize))
    }()

    public static let rotatePointerStyle: PointerStyle = .image(
        Image(nsImage: rotateCursorImage),
        hotSpot: .center
    )

    public static let rotateNSCursor: NSCursor = NSCursor(
        image: rotateCursorImage,
        hotSpot: NSPoint(x: 10, y: 10)
    )
}
