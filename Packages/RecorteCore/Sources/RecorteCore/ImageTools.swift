import Foundation
import CoreGraphics
import CoreImage

public enum ImageToolError: Error, Sendable, Equatable {
    case invalidDimensions
    case invalidParameters
    case contextCreationFailed
    case filterUnavailable(String)
    case renderFailed
}

/// Four corner points of a quadrilateral in top-left image coordinates (y down).
public struct PerspectiveQuad: Sendable, Equatable, Hashable, Codable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

/// Supported distortion deform presets.
public enum DeformPreset: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case bump
    case pinch
    case twirl
}

/// Five-point tone curve specification (`0.0...1.0` normalized coordinates) for `CIToneCurve`.
public struct ToneCurveSpec: Sendable, Equatable, Hashable, Codable {
    public var point0: CGPoint
    public var point1: CGPoint
    public var point2: CGPoint
    public var point3: CGPoint
    public var point4: CGPoint

    public init(
        point0: CGPoint = CGPoint(x: 0.0, y: 0.0),
        point1: CGPoint = CGPoint(x: 0.25, y: 0.25),
        point2: CGPoint = CGPoint(x: 0.5, y: 0.5),
        point3: CGPoint = CGPoint(x: 0.75, y: 0.75),
        point4: CGPoint = CGPoint(x: 1.0, y: 1.0)
    ) {
        self.point0 = point0
        self.point1 = point1
        self.point2 = point2
        self.point3 = point3
        self.point4 = point4
    }

    public init?(points: [CGPoint]) {
        guard points.count == 5 else { return nil }
        self.init(
            point0: points[0],
            point1: points[1],
            point2: points[2],
            point3: points[3],
            point4: points[4]
        )
    }

    public var points: [CGPoint] {
        [point0, point1, point2, point3, point4]
    }

    public var isIdentity: Bool {
        point0 == CGPoint(x: 0.0, y: 0.0) &&
        point1 == CGPoint(x: 0.25, y: 0.25) &&
        point2 == CGPoint(x: 0.5, y: 0.5) &&
        point3 == CGPoint(x: 0.75, y: 0.75) &&
        point4 == CGPoint(x: 1.0, y: 1.0)
    }
}

public enum RotationDirection: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case left90
    case right90
}

public enum FlipAxis: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case horizontal
    case vertical
}

/// Pure image editing functions operating on `CGImage`.
/// All geometric parameters use top-left origin, y down, in image pixel coordinates.
public enum ImageTools {

    // MARK: - 1. Lasso Cutout

    /// Cuts out the interior of `path` (top-left coordinates) with transparent pixels outside.
    /// When `cropToPathBounds` is `true`, crops the output to the path's bounding box clipped to the image.
    public static func lassoCutout(
        _ image: CGImage,
        path: CGPath,
        cropToPathBounds: Bool = false
    ) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }

        let ctx = try makeRGBAContext(width: w, height: h)
        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.clear(fullRect)

        // Flip to top-left origin to clip against top-left CGPath
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.addPath(path)
        ctx.clip()

        // Unflip back to identity so CGContext.draw renders image upright
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(image, in: fullRect)
        ctx.restoreGState()

        guard let masked = ctx.makeImage() else {
            throw ImageToolError.renderFailed
        }

        guard cropToPathBounds else {
            return masked
        }

        let clippedBounds = path.boundingBoxOfPath.intersection(fullRect).integral
        guard !clippedBounds.isNull, clippedBounds.width >= 1, clippedBounds.height >= 1 else {
            throw ImageToolError.invalidParameters
        }
        guard let cropped = masked.cropping(to: clippedBounds) else {
            throw ImageToolError.renderFailed
        }
        return cropped
    }

    // MARK: - 2. Clone Stamp

    /// Copies a circular region of radius `radius` from `source` to `destination` (top-left coordinates)
    /// with radial soft-edge feathering (`softness` in `0...1`) and `opacity` (`0...1`).
    public static func cloneStamp(
        _ image: CGImage,
        from source: CGPoint,
        to destination: CGPoint,
        radius: CGFloat,
        softness: CGFloat = 0.5,
        opacity: CGFloat = 1.0
    ) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard radius > 0 else {
            throw ImageToolError.invalidParameters
        }

        let clampedSoftness = min(max(softness, 0.0), 1.0)
        let clampedOpacity = min(max(opacity, 0.0), 1.0)
        if clampedOpacity <= 0.0 {
            return image
        }

        let ctx = try makeRGBAContext(width: w, height: h)
        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.clear(fullRect)

        // 1. Draw base image upright
        ctx.draw(image, in: fullRect)

        // 2. Render feathered circular clone stamp in a transparency layer using top-left coordinates
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let stampRect = CGRect(
            x: destination.x - radius,
            y: destination.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addEllipse(in: stampRect)
        ctx.clip()

        // Draw shifted source image upright inside the destination circle
        ctx.saveGState()
        ctx.translateBy(x: destination.x - source.x, y: destination.y - source.y)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(image, in: fullRect)
        ctx.restoreGState()

        // Feather the circular edge using destinationIn radial alpha gradient
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let innerStop = max(0.0, min(1.0, 1.0 - clampedSoftness))
        let solidWhite = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: clampedOpacity)
        let clearWhite = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
        let colors: [CGColor] = [solidWhite, solidWhite, clearWhite]
        let locations: [CGFloat] = [0.0, innerStop, 1.0]

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawRadialGradient(
                gradient,
                startCenter: destination,
                startRadius: 0,
                endCenter: destination,
                endRadius: radius,
                options: []
            )
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        guard let output = ctx.makeImage() else {
            throw ImageToolError.renderFailed
        }
        return output
    }

    // MARK: - 3. Perspective Correction

    /// Rectifies the 4-corner quadrilateral `quad` (top-left image coordinates) via `CIPerspectiveCorrection`.
    public static func perspectiveCorrect(_ image: CGImage, quad: PerspectiveQuad) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw ImageToolError.filterUnavailable("CIPerspectiveCorrection")
        }

        let imgH = CGFloat(h)
        let input = CIImage(cgImage: image)
        filter.setValue(input, forKey: kCIInputImageKey)
        // Convert top-left y-down points to Core Image bottom-left y-up coordinates
        filter.setValue(CIVector(x: quad.topLeft.x, y: imgH - quad.topLeft.y), forKey: "inputTopLeft")
        filter.setValue(CIVector(x: quad.topRight.x, y: imgH - quad.topRight.y), forKey: "inputTopRight")
        filter.setValue(CIVector(x: quad.bottomRight.x, y: imgH - quad.bottomRight.y), forKey: "inputBottomRight")
        filter.setValue(CIVector(x: quad.bottomLeft.x, y: imgH - quad.bottomLeft.y), forKey: "inputBottomLeft")

        guard let outputCI = filter.outputImage,
              !outputCI.extent.isEmpty,
              !outputCI.extent.isInfinite,
              let cgOut = ImageFilters.sharedContext.createCGImage(outputCI, from: outputCI.extent) else {
            throw ImageToolError.renderFailed
        }
        return cgOut
    }

    /// Convenience overload taking 4 explicit corner points in top-left image coordinates.
    public static func perspectiveCorrect(
        _ image: CGImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) throws -> CGImage {
        try perspectiveCorrect(
            image,
            quad: PerspectiveQuad(
                topLeft: topLeft,
                topRight: topRight,
                bottomRight: bottomRight,
                bottomLeft: bottomLeft
            )
        )
    }

    // MARK: - 4. Deform Presets

    /// Applies a local distortion preset (`.bump`, `.pinch`, or `.twirl`) around `center` (top-left coordinates)
    /// with `radius` and `strength`.
    public static func deform(
        _ image: CGImage,
        preset: DeformPreset,
        center: CGPoint,
        radius: CGFloat,
        strength: CGFloat = 0.5
    ) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard radius > 0 else {
            throw ImageToolError.invalidParameters
        }

        let extent = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let ciInput = CIImage(cgImage: image).clampedToExtent()
        let ciCenter = CIVector(x: center.x, y: CGFloat(h) - center.y)

        let filterName: String
        switch preset {
        case .bump, .pinch:
            // CIBumpDistortion with positive scale bulges outward; negative scale pinches inward,
            // strictly bounded within `radius` with C1 continuity at the boundary.
            filterName = "CIBumpDistortion"
        case .twirl:
            filterName = "CITwirlDistortion"
        }

        guard let filter = CIFilter(name: filterName) else {
            throw ImageToolError.filterUnavailable(filterName)
        }

        filter.setValue(ciInput, forKey: kCIInputImageKey)
        filter.setValue(ciCenter, forKey: kCIInputCenterKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)

        switch preset {
        case .bump:
            filter.setValue(min(max(strength, -1.0), 1.0), forKey: kCIInputScaleKey)
        case .pinch:
            filter.setValue(-min(max(strength, -1.0), 1.0), forKey: kCIInputScaleKey)
        case .twirl:
            filter.setValue(strength * .pi, forKey: kCIInputAngleKey)
        }

        guard let outputCI = filter.outputImage?.cropped(to: extent),
              let cgOut = ImageFilters.sharedContext.createCGImage(outputCI, from: extent) else {
            throw ImageToolError.renderFailed
        }
        return cgOut
    }

    /// Applies a liquify-style deform brush stroke (`DeformStroke`) in top-left image coordinates.
    public static func deformBrush(_ image: CGImage, stroke: DeformStroke) throws -> CGImage {
        try DeformBrush.applyStroke(image, stroke: stroke)
    }

    // MARK: - 5. Curves (CIToneCurve)

    /// Applies a 5-point tone curve via `CIToneCurve`.
    public static func applyCurves(_ image: CGImage, curve: ToneCurveSpec) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        if curve.isIdentity {
            return image
        }

        guard let filter = CIFilter(name: "CIToneCurve") else {
            throw ImageToolError.filterUnavailable("CIToneCurve")
        }

        let extent = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let ciInput = CIImage(cgImage: image)
        filter.setValue(ciInput, forKey: kCIInputImageKey)

        let keys = ["inputPoint0", "inputPoint1", "inputPoint2", "inputPoint3", "inputPoint4"]
        for (key, pt) in zip(keys, curve.points) {
            let x = min(max(pt.x, 0.0), 1.0)
            let y = min(max(pt.y, 0.0), 1.0)
            filter.setValue(CIVector(x: x, y: y), forKey: key)
        }

        guard let outputCI = filter.outputImage?.cropped(to: extent),
              let cgOut = ImageFilters.sharedContext.createCGImage(outputCI, from: extent) else {
            throw ImageToolError.renderFailed
        }
        return cgOut
    }

    /// Convenience overload taking an array of 5 normalized curve points.
    public static func applyCurves(_ image: CGImage, points: [CGPoint]) throws -> CGImage {
        guard let curve = ToneCurveSpec(points: points) else {
            throw ImageToolError.invalidParameters
        }
        return try applyCurves(image, curve: curve)
    }

    // MARK: - 6. Resize (Lanczos)

    /// Resizes `image` to `targetSize` using high-quality `CILanczosScaleTransform`.
    /// When `keepAspect` is `true`, fits within `targetSize` while preserving the original aspect ratio.
    public static func resize(
        _ image: CGImage,
        to targetSize: CGSize,
        keepAspect: Bool = true
    ) throws -> CGImage {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0, targetSize.width >= 1.0, targetSize.height >= 1.0 else {
            throw ImageToolError.invalidDimensions
        }

        let outW: Int
        let outH: Int
        if keepAspect {
            let uniformScale = min(targetSize.width / srcW, targetSize.height / srcH)
            outW = max(1, Int((srcW * uniformScale).rounded()))
            outH = max(1, Int((srcH * uniformScale).rounded()))
        } else {
            outW = max(1, Int(targetSize.width.rounded()))
            outH = max(1, Int(targetSize.height.rounded()))
        }

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            throw ImageToolError.filterUnavailable("CILanczosScaleTransform")
        }

        let scaleY = CGFloat(outH) / srcH
        let scaleX = CGFloat(outW) / srcW
        let aspectRatio = scaleX / scaleY

        let ciInput = CIImage(cgImage: image)
        filter.setValue(ciInput, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(aspectRatio, forKey: kCIInputAspectRatioKey)

        let outRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
        guard let outputCI = filter.outputImage?.cropped(to: outRect),
              let cgOut = ImageFilters.sharedContext.createCGImage(outputCI, from: outRect) else {
            throw ImageToolError.renderFailed
        }
        return cgOut
    }

    // MARK: - 7. Rotate 90 Left/Right & Flip

    /// Rotates the whole image 90 degrees left (counter-clockwise) or right (clockwise).
    public static func rotate90(_ image: CGImage, direction: RotationDirection) throws -> CGImage {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else {
            throw ImageToolError.invalidDimensions
        }

        let outW = srcH
        let outH = srcW
        let ctx = try makeRGBAContext(width: outW, height: outH)
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)))

        // In unflipped CGContext (+y up): +pi/2 rotates CCW (left90), -pi/2 rotates CW (right90)
        ctx.translateBy(x: CGFloat(outW) / 2.0, y: CGFloat(outH) / 2.0)
        switch direction {
        case .left90:
            ctx.rotate(by: .pi / 2.0)
        case .right90:
            ctx.rotate(by: -.pi / 2.0)
        }
        ctx.draw(
            image,
            in: CGRect(
                x: -CGFloat(srcW) / 2.0,
                y: -CGFloat(srcH) / 2.0,
                width: CGFloat(srcW),
                height: CGFloat(srcH)
            )
        )

        guard let output = ctx.makeImage() else {
            throw ImageToolError.renderFailed
        }
        return output
    }

    /// Flips the whole image horizontally or vertically.
    public static func flip(_ image: CGImage, axis: FlipAxis) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }

        let ctx = try makeRGBAContext(width: w, height: h)
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.clear(rect)

        switch axis {
        case .horizontal:
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1.0, y: 1.0)
        case .vertical:
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
        }
        ctx.draw(image, in: rect)

        guard let output = ctx.makeImage() else {
            throw ImageToolError.renderFailed
        }
        return output
    }

    // MARK: - Private Context Helper

    private static func makeRGBAContext(width: Int, height: Int) throws -> CGContext {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageToolError.contextCreationFailed
        }
        return ctx
    }
}
