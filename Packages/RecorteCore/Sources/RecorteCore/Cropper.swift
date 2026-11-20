import Foundation
import CoreGraphics

public enum CropAspect: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case free
    case original
    case ratio1x1
    case ratio4x3
    case ratio3x4
    case ratio16x9
    case ratio9x16

    /// Returns the width/height ratio for fixed presets, or `nil` for `.free`.
    public func ratioValue(in bounds: CGRect) -> CGFloat? {
        switch self {
        case .free:
            return nil
        case .original:
            guard bounds.height > 0 else { return 1.0 }
            return bounds.width / bounds.height
        case .ratio1x1:
            return 1.0
        case .ratio4x3:
            return 4.0 / 3.0
        case .ratio3x4:
            return 3.0 / 4.0
        case .ratio16x9:
            return 16.0 / 9.0
        case .ratio9x16:
            return 9.0 / 16.0
        }
    }
}

public enum CropShape: Sendable, Equatable, Hashable, Codable {
    case rectangle
    case roundedRect(radius: Double)
    case ellipse
    case star
    case heart
}

public struct CropSpec: Sendable, Equatable, Hashable, Codable {
    public var rect: CGRect
    public var aspect: CropAspect
    public var shape: CropShape
    public var rotationDegrees: Double
    public var flipH: Bool
    public var flipV: Bool

    public var rotation: Double {
        get { rotationDegrees }
        set { rotationDegrees = newValue }
    }

    public init(
        rect: CGRect,
        aspect: CropAspect = .free,
        shape: CropShape = .rectangle,
        rotationDegrees: Double = 0.0,
        flipH: Bool = false,
        flipV: Bool = false
    ) {
        self.rect = rect
        self.aspect = aspect
        self.shape = shape
        self.rotationDegrees = rotationDegrees
        self.flipH = flipH
        self.flipV = flipV
    }

    public init(
        rect: CGRect,
        aspect: CropAspect = .free,
        shape: CropShape = .rectangle,
        rotation: Double,
        flipH: Bool = false,
        flipV: Bool = false
    ) {
        self.init(
            rect: rect,
            aspect: aspect,
            shape: shape,
            rotationDegrees: rotation,
            flipH: flipH,
            flipV: flipV
        )
    }
}

public enum CropError: Error, Sendable, Equatable {
    case invalidBounds
    case contextCreationFailed
    case imageCreationFailed
}

public enum Cropper {

    /// Pure function that constrains `rect` to `aspect` while staying completely inside `imageBounds`.
    public static func constrainRect(_ rect: CGRect, aspect: CropAspect, in imageBounds: CGRect) -> CGRect {
        guard imageBounds.width > 0, imageBounds.height > 0 else { return .zero }

        var w = max(1.0, min(abs(rect.width), imageBounds.width))
        var h = max(1.0, min(abs(rect.height), imageBounds.height))

        if let targetRatio = aspect.ratioValue(in: imageBounds), targetRatio > 0 {
            // Fit (w, h) to targetRatio without exceeding (w, h) or imageBounds
            if w / h > targetRatio {
                w = h * targetRatio
            } else {
                h = w / targetRatio
            }
            if w > imageBounds.width {
                w = imageBounds.width
                h = w / targetRatio
            }
            if h > imageBounds.height {
                h = imageBounds.height
                w = h * targetRatio
            }
        }

        // Preserve center where possible, then clamp origin to imageBounds
        let centerX = rect.midX
        let centerY = rect.midY
        var x = centerX - w / 2.0
        var y = centerY - h / 2.0

        x = min(max(x, imageBounds.minX), imageBounds.maxX - w)
        y = min(max(y, imageBounds.minY), imageBounds.maxY - h)

        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Builds a `CGPath` for the given `CropShape` inside `rect`.
    public static func maskPath(for shape: CropShape, in rect: CGRect) -> CGPath {
        switch shape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)

        case .roundedRect(let radius):
            let maxRadius = min(rect.width, rect.height) / 2.0
            let r = min(max(CGFloat(radius), 0), maxRadius)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)

        case .star:
            let path = CGMutablePath()
            let cx = rect.midX
            let cy = rect.midY
            let outerR = min(rect.width, rect.height) / 2.0
            let innerR = outerR * 0.382
            let points = 5
            for i in 0..<(points * 2) {
                let r = (i % 2 == 0) ? outerR : innerR
                let angle = (CGFloat(i) * .pi / CGFloat(points)) - (.pi / 2.0)
                let pt = CGPoint(
                    x: cx + r * cos(angle),
                    y: cy + r * sin(angle)
                )
                if i == 0 {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
            }
            path.closeSubpath()
            return path

        case .heart:
            let path = CGMutablePath()
            let w = rect.width
            let h = rect.height
            let x0 = rect.minX
            let y0 = rect.minY

            // In standard CG coordinates (y=0 at bottom, y=h at top):
            // Bottom tip at (0.5, 0.08), top cleft at (0.5, 0.72), top lobes reaching y ~ 0.95
            let bottomTip = CGPoint(x: x0 + w * 0.5, y: y0 + h * 0.08)
            let topCleft = CGPoint(x: x0 + w * 0.5, y: y0 + h * 0.74)

            path.move(to: bottomTip)
            // Right half curve up to top cleft
            path.addCurve(
                to: CGPoint(x: x0 + w * 0.95, y: y0 + h * 0.65),
                control1: CGPoint(x: x0 + w * 0.80, y: y0 + h * 0.25),
                control2: CGPoint(x: x0 + w * 0.95, y: y0 + h * 0.45)
            )
            path.addCurve(
                to: topCleft,
                control1: CGPoint(x: x0 + w * 0.95, y: y0 + h * 0.92),
                control2: CGPoint(x: x0 + w * 0.62, y: y0 + h * 0.92)
            )
            // Left half curve down to bottom tip
            path.addCurve(
                to: CGPoint(x: x0 + w * 0.05, y: y0 + h * 0.65),
                control1: CGPoint(x: x0 + w * 0.38, y: y0 + h * 0.92),
                control2: CGPoint(x: x0 + w * 0.05, y: y0 + h * 0.92)
            )
            path.addCurve(
                to: bottomTip,
                control1: CGPoint(x: x0 + w * 0.05, y: y0 + h * 0.45),
                control2: CGPoint(x: x0 + w * 0.20, y: y0 + h * 0.25)
            )
            path.closeSubpath()
            return path
        }
    }

    /// Crops `image` according to `spec`, producing transparent pixels outside non-rectangular shape masks.
    public static func crop(_ image: CGImage, _ spec: CropSpec) throws -> CGImage {
        try crop(image, spec: spec)
    }

    /// Crops `image` according to `spec`, producing transparent pixels outside non-rectangular shape masks.
    public static func crop(_ image: CGImage, spec: CropSpec) throws -> CGImage {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let constrained = constrainRect(spec.rect, aspect: spec.aspect, in: imageBounds)
        let outW = max(1, Int(constrained.width.rounded()))
        let outH = max(1, Int(constrained.height.rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CropError.contextCreationFailed
        }

        let destRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
        ctx.clear(destRect)

        // Apply shape clipping mask in output coordinates
        let clipPath = maskPath(for: spec.shape, in: destRect)
        ctx.addPath(clipPath)
        ctx.clip()

        // Apply rotation and flips around center of output canvas
        ctx.saveGState()
        ctx.translateBy(x: destRect.midX, y: destRect.midY)
        if spec.flipH || spec.flipV {
            ctx.scaleBy(x: spec.flipH ? -1.0 : 1.0, y: spec.flipV ? -1.0 : 1.0)
        }
        if spec.rotationDegrees != 0 {
            let radians = CGFloat(spec.rotationDegrees) * .pi / 180.0
            ctx.rotate(by: radians)
        }
        ctx.translateBy(x: -destRect.midX, y: -destRect.midY)

        // Draw cropped region of source image.
        // Note: CGImage.cropping(to:) uses top-left pixel coordinates; convert or slice directly.
        let cropPixelRect = CGRect(
            x: constrained.minX.rounded(),
            y: constrained.minY.rounded(),
            width: CGFloat(outW),
            height: CGFloat(outH)
        )
        if let subImage = image.cropping(to: cropPixelRect) {
            ctx.draw(subImage, in: destRect)
        } else {
            ctx.draw(
                image,
                in: CGRect(
                    x: -constrained.minX,
                    y: -(CGFloat(image.height) - constrained.maxY),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
        }
        ctx.restoreGState()

        guard let result = ctx.makeImage() else {
            throw CropError.imageCreationFailed
        }
        return result
    }
}
