import Foundation
import CoreGraphics

/// Mode for manual brush erasing on image layers.
public enum EraserMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Reduces pixel alpha along the stroke, making regions transparent.
    case erase
    /// Brings back original pixels along the stroke from the underlying source image / mask.
    case restore
}

/// Specification of a single brush eraser or restore stroke in top-left image pixel coordinates.
public struct EraserStroke: Sendable, Equatable, Hashable, Codable {
    /// Points in top-left image pixel coordinates (y down).
    public var points: [CGPoint]
    /// Brush diameter in image pixels (`> 0`).
    public var brushSize: CGFloat
    /// Brush edge hardness in `0.0...1.0` (`0` = fully soft feathered edge, `1` = crisp hard edge).
    public var hardness: CGFloat
    /// Whether this stroke erases pixels or restores original pixels.
    public var mode: EraserMode

    public init(
        points: [CGPoint],
        brushSize: CGFloat = 32.0,
        hardness: CGFloat = 0.75,
        mode: EraserMode = .erase
    ) {
        self.points = points
        self.brushSize = brushSize
        self.hardness = hardness
        self.mode = mode
    }
}

/// Pure functions for manual brush erasing and restoring on `CGImage` and per-layer alpha masks.
/// All coordinates use top-left origin, y down, in image pixel coordinates.
public enum ImageEraser {

    // MARK: - Smooth Point Interpolation

    /// Smooths and interpolates raw pointer points (top-left pixel coordinates) using quadratic midpoint curves
    /// sampled at `spacing` pixels for fluid brush strokes.
    public static func interpolatePoints(_ points: [CGPoint], spacing: CGFloat = 2.0) -> [CGPoint] {
        guard points.count > 1 else { return points }
        let step = max(0.5, spacing)

        var result: [CGPoint] = [points[0]]

        func appendSegment(from a: CGPoint, to b: CGPoint) {
            let dist = hypot(b.x - a.x, b.y - a.y)
            guard dist > 1e-4 else { return }
            let steps = max(1, Int(ceil(dist / step)))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }

        func appendQuadCurve(from p0: CGPoint, control p1: CGPoint, to p2: CGPoint) {
            let approxLen = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = max(1, Int(ceil(approxLen / step)))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let mt = 1.0 - t
                let x = mt * mt * p0.x + 2.0 * mt * t * p1.x + t * t * p2.x
                let y = mt * mt * p0.y + 2.0 * mt * t * p1.y + t * t * p2.y
                result.append(CGPoint(x: x, y: y))
            }
        }

        if points.count == 2 {
            appendSegment(from: points[0], to: points[1])
            return result
        }

        // First half-segment: points[0] -> midpoint(points[0], points[1])
        var prevMid = CGPoint(
            x: (points[0].x + points[1].x) * 0.5,
            y: (points[0].y + points[1].y) * 0.5
        )
        appendSegment(from: points[0], to: prevMid)

        // Smooth quadratic spans through interior control points
        for i in 1..<(points.count - 1) {
            let ctrl = points[i]
            let next = points[i + 1]
            let mid = CGPoint(x: (ctrl.x + next.x) * 0.5, y: (ctrl.y + next.y) * 0.5)
            appendQuadCurve(from: prevMid, control: ctrl, to: mid)
            prevMid = mid
        }

        // Final half-segment: last midpoint -> points.last
        if let last = points.last {
            appendSegment(from: prevMid, to: last)
        }
        return result
    }

    // MARK: - Direct CGImage Pure Functions

    /// Convenience pure function to erase along `points` (in image pixels) producing transparency.
    public static func erase(
        _ image: CGImage,
        points: [CGPoint],
        brushSize: CGFloat,
        hardness: CGFloat = 0.75
    ) throws -> CGImage {
        try applyStroke(
            image,
            stroke: EraserStroke(points: points, brushSize: brushSize, hardness: hardness, mode: .erase),
            sourceImage: nil
        )
    }

    /// Convenience pure function to restore pixels along `points` (in image pixels) from `sourceImage`.
    public static func restore(
        _ image: CGImage,
        from sourceImage: CGImage,
        points: [CGPoint],
        brushSize: CGFloat,
        hardness: CGFloat = 0.75
    ) throws -> CGImage {
        try applyStroke(
            image,
            stroke: EraserStroke(points: points, brushSize: brushSize, hardness: hardness, mode: .restore),
            sourceImage: sourceImage
        )
    }

    /// Pure function that applies a single `EraserStroke` to `image`.
    /// - In `.erase` mode, lowers pixel alpha along the stroke (producing transparency).
    /// - In `.restore` mode, restores original pixels from `sourceImage` along the stroke.
    public static func applyStroke(
        _ image: CGImage,
        stroke: EraserStroke,
        sourceImage: CGImage? = nil
    ) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard stroke.brushSize > 0 else {
            throw ImageToolError.invalidParameters
        }
        if stroke.points.isEmpty {
            return image
        }

        let coverage = rasterizeStrokeCoverage(
            points: stroke.points,
            width: w,
            height: h,
            brushSize: stroke.brushSize,
            hardness: stroke.hardness
        )

        var currentBytes = try readPremultipliedRGBABytes(image)

        switch stroke.mode {
        case .erase:
            currentBytes.withUnsafeMutableBufferPointer { dst in
                coverage.withUnsafeBufferPointer { cov in
                    for idx in 0..<(w * h) {
                        let s = Int(cov[idx])
                        guard s > 0 else { continue }
                        let inv = 255 - s
                        let base = idx * 4
                        dst[base]     = UInt8((Int(dst[base]) * inv + 127) / 255)
                        dst[base + 1] = UInt8((Int(dst[base + 1]) * inv + 127) / 255)
                        dst[base + 2] = UInt8((Int(dst[base + 2]) * inv + 127) / 255)
                        dst[base + 3] = UInt8((Int(dst[base + 3]) * inv + 127) / 255)
                    }
                }
            }
            return try makePremultipliedRGBAImage(bytes: currentBytes, width: w, height: h)

        case .restore:
            guard let sourceImage, sourceImage.width == w, sourceImage.height == h else {
                throw ImageToolError.invalidParameters
            }
            let sourceBytes = try readPremultipliedRGBABytes(sourceImage)
            currentBytes.withUnsafeMutableBufferPointer { dst in
                sourceBytes.withUnsafeBufferPointer { src in
                    coverage.withUnsafeBufferPointer { cov in
                        for idx in 0..<(w * h) {
                            let s = Int(cov[idx])
                            guard s > 0 else { continue }
                            let inv = 255 - s
                            let base = idx * 4
                            dst[base]     = UInt8((Int(dst[base]) * inv + Int(src[base]) * s + 127) / 255)
                            dst[base + 1] = UInt8((Int(dst[base + 1]) * inv + Int(src[base + 1]) * s + 127) / 255)
                            dst[base + 2] = UInt8((Int(dst[base + 2]) * inv + Int(src[base + 2]) * s + 127) / 255)
                            dst[base + 3] = UInt8((Int(dst[base + 3]) * inv + Int(src[base + 3]) * s + 127) / 255)
                        }
                    }
                }
            }
            return try makePremultipliedRGBAImage(bytes: currentBytes, width: w, height: h)
        }
    }

    /// Applies a sequence of eraser/restore strokes to `image`.
    /// When `sourceImage` is `nil`, `image` itself serves as the original source for any `.restore` strokes.
    public static func applyStrokes(
        _ image: CGImage,
        strokes: [EraserStroke],
        sourceImage: CGImage? = nil
    ) throws -> CGImage {
        guard !strokes.isEmpty else { return image }
        let original = sourceImage ?? image
        var current = image
        for stroke in strokes {
            current = try applyStroke(current, stroke: stroke, sourceImage: original)
        }
        return current
    }

    // MARK: - Non-Destructive Alpha Mask Functions

    /// Creates a fully opaque (all 255) 8-bit linear grayscale alpha mask of size `width × height`.
    public static func makeOpaqueMask(width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw ImageToolError.invalidDimensions
        }
        let bytes = [UInt8](repeating: 255, count: width * height)
        return try makeGrayscaleMaskImage(bytes: bytes, width: width, height: height)
    }

    /// Applies an erase or restore `stroke` to an optional 8-bit grayscale alpha mask
    /// (`nil` is treated as fully opaque all-255), returning the updated alpha mask `CGImage`.
    public static func applyStrokeToMask(
        _ mask: CGImage?,
        width: Int,
        height: Int,
        stroke: EraserStroke
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard stroke.brushSize > 0 else {
            throw ImageToolError.invalidParameters
        }

        var maskBytes = try readGrayscaleMaskBytes(mask, width: width, height: height)
        guard !stroke.points.isEmpty else {
            return try makeGrayscaleMaskImage(bytes: maskBytes, width: width, height: height)
        }

        let coverage = rasterizeStrokeCoverage(
            points: stroke.points,
            width: width,
            height: height,
            brushSize: stroke.brushSize,
            hardness: stroke.hardness
        )

        combineMask(base: maskBytes, coverage: coverage, mode: stroke.mode, into: &maskBytes)
        return try makeGrayscaleMaskImage(bytes: maskBytes, width: width, height: height)
    }

    /// Composites an 8-bit grayscale `alphaMask` onto `image` by multiplying premultiplied RGBA
    /// channels by `mask / 255.0`. Original transparency in `image` is always preserved.
    public static func applyAlphaMask(_ alphaMask: CGImage, to image: CGImage) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }

        var rgba = try readPremultipliedRGBABytes(image)
        let maskBytes = try readGrayscaleMaskBytes(alphaMask, width: w, height: h)

        rgba.withUnsafeMutableBufferPointer { dst in
            maskBytes.withUnsafeBufferPointer { mask in
                for idx in 0..<(w * h) {
                    let m = Int(mask[idx])
                    if m == 255 { continue }
                    let base = idx * 4
                    if m == 0 {
                        dst[base] = 0
                        dst[base + 1] = 0
                        dst[base + 2] = 0
                        dst[base + 3] = 0
                    } else {
                        dst[base]     = UInt8((Int(dst[base]) * m + 127) / 255)
                        dst[base + 1] = UInt8((Int(dst[base + 1]) * m + 127) / 255)
                        dst[base + 2] = UInt8((Int(dst[base + 2]) * m + 127) / 255)
                        dst[base + 3] = UInt8((Int(dst[base + 3]) * m + 127) / 255)
                    }
                }
            }
        }

        return try makePremultipliedRGBAImage(bytes: rgba, width: w, height: h)
    }

    // MARK: - Internal Rasterization Primitives

    internal struct BrushMetrics {
        let radius: CGFloat
        let radiusSq: CGFloat
        let innerRadius: CGFloat
        let innerRadiusSq: CGFloat
        let falloffSpan: CGFloat

        init(brushSize: CGFloat, hardness: CGFloat) {
            let r = max(0.5, brushSize * 0.5)
            let clampedHardness = min(max(hardness, 0.0), 1.0)
            // Keep a crisp ~0.75px anti-aliased fringe at hardness == 1.0, and a tiny subpixel center core
            // (~0.6px) so the pixel directly on the stroke centerline reaches full 100% erasure even at hardness == 0.
            let maxInner = r > 1.0 ? max(0.0, r - 0.75) : 0.0
            let minCenterCore = r >= 2.0 ? min(0.6, r * 0.15) : 0.0
            let inner = min(max(r * clampedHardness, minCenterCore), maxInner)
            self.radius = r
            self.radiusSq = r * r
            self.innerRadius = inner
            self.innerRadiusSq = inner * inner
            self.falloffSpan = max(0.001, r - inner)
        }
    }

    internal static func rasterizeStrokeCoverage(
        points: [CGPoint],
        width: Int,
        height: Int,
        brushSize: CGFloat,
        hardness: CGFloat
    ) -> [UInt8] {
        var coverage = [UInt8](repeating: 0, count: width * height)
        guard !points.isEmpty else { return coverage }

        let metrics = BrushMetrics(brushSize: brushSize, hardness: hardness)
        let smoothed = interpolatePoints(points, spacing: max(1.0, min(brushSize * 0.25, 4.0)))

        if smoothed.count == 1 {
            stampCapsule(
                from: smoothed[0],
                to: smoothed[0],
                metrics: metrics,
                width: width,
                height: height,
                coverage: &coverage
            )
        } else {
            for i in 0..<(smoothed.count - 1) {
                stampCapsule(
                    from: smoothed[i],
                    to: smoothed[i + 1],
                    metrics: metrics,
                    width: width,
                    height: height,
                    coverage: &coverage
                )
            }
        }
        return coverage
    }

    /// Stamps a continuous radial-falloff capsule from `a` to `b` into `coverage` using `max` blending,
    /// returning the dirty integer pixel rect `(minX...maxX, minY...maxY)` or `nil` if completely out of bounds.
    @discardableResult
    internal static func stampCapsule(
        from a: CGPoint,
        to b: CGPoint,
        metrics: BrushMetrics,
        width: Int,
        height: Int,
        coverage: inout [UInt8]
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let r = metrics.radius
        let minX = max(0, Int(floor(min(a.x, b.x) - r - 1.0)))
        let maxX = min(width - 1, Int(ceil(max(a.x, b.x) + r + 1.0)))
        let minY = max(0, Int(floor(min(a.y, b.y) - r - 1.0)))
        let maxY = min(height - 1, Int(ceil(max(a.y, b.y) + r + 1.0)))
        guard minX <= maxX, minY <= maxY else { return nil }

        let ax = a.x
        let ay = a.y
        let vx = b.x - ax
        let vy = b.y - ay
        let lenSq = vx * vx + vy * vy
        let isPoint = lenSq < 1e-6

        let rSq = metrics.radiusSq
        let innerR = metrics.innerRadius
        let innerRSq = metrics.innerRadiusSq
        let invSpan = 1.0 / metrics.falloffSpan

        coverage.withUnsafeMutableBufferPointer { cov in
            for y in minY...maxY {
                let py = CGFloat(y) + 0.5
                let rowOffset = y * width
                for x in minX...maxX {
                    let px = CGFloat(x) + 0.5
                    let distSq: CGFloat
                    if isPoint {
                        let dx = px - ax
                        let dy = py - ay
                        distSq = dx * dx + dy * dy
                    } else {
                        let proj = ((px - ax) * vx + (py - ay) * vy) / lenSq
                        let t = proj < 0.0 ? 0.0 : (proj > 1.0 ? 1.0 : proj)
                        let dx = px - (ax + t * vx)
                        let dy = py - (ay + t * vy)
                        distSq = dx * dx + dy * dy
                    }

                    if distSq >= rSq { continue }

                    let value: UInt8
                    if distSq <= innerRSq {
                        value = 255
                    } else {
                        let dist = sqrt(distSq)
                        let tFalloff = (dist - innerR) * invSpan
                        let u = max(0.0, min(1.0, 1.0 - tFalloff))
                        // Cubic smoothstep for natural feathered falloff
                        let strength = u * u * (3.0 - 2.0 * u)
                        value = UInt8((strength * 255.0).rounded())
                    }

                    let idx = rowOffset + x
                    if value > cov[idx] {
                        cov[idx] = value
                    }
                }
            }
        }
        return (minX, maxX, minY, maxY)
    }

    internal static func combineMask(
        base: [UInt8],
        coverage: [UInt8],
        mode: EraserMode,
        into output: inout [UInt8]
    ) {
        let count = base.count
        output.withUnsafeMutableBufferPointer { dst in
            base.withUnsafeBufferPointer { src in
                coverage.withUnsafeBufferPointer { cov in
                    switch mode {
                    case .erase:
                        for idx in 0..<count {
                            let s = Int(cov[idx])
                            guard s > 0 else { continue }
                            dst[idx] = UInt8((Int(src[idx]) * (255 - s) + 127) / 255)
                        }
                    case .restore:
                        for idx in 0..<count {
                            let s = Int(cov[idx])
                            guard s > 0 else { continue }
                            let b = Int(src[idx])
                            dst[idx] = UInt8(b + ((255 - b) * s + 127) / 255)
                        }
                    }
                }
            }
        }
    }

    internal static func combineMaskDirtyRect(
        base: [UInt8],
        coverage: [UInt8],
        mode: EraserMode,
        width: Int,
        rect: (minX: Int, maxX: Int, minY: Int, maxY: Int),
        into output: inout [UInt8]
    ) {
        output.withUnsafeMutableBufferPointer { dst in
            base.withUnsafeBufferPointer { src in
                coverage.withUnsafeBufferPointer { cov in
                    switch mode {
                    case .erase:
                        for y in rect.minY...rect.maxY {
                            let row = y * width
                            for x in rect.minX...rect.maxX {
                                let idx = row + x
                                let s = Int(cov[idx])
                                if s == 0 { continue }
                                dst[idx] = UInt8((Int(src[idx]) * (255 - s) + 127) / 255)
                            }
                        }
                    case .restore:
                        for y in rect.minY...rect.maxY {
                            let row = y * width
                            for x in rect.minX...rect.maxX {
                                let idx = row + x
                                let s = Int(cov[idx])
                                if s == 0 { continue }
                                let b = Int(src[idx])
                                dst[idx] = UInt8(b + ((255 - b) * s + 127) / 255)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bitmap Byte Helpers

    internal static func linearGrayColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
    }

    internal static func sRGBColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    internal static func readGrayscaleMaskBytes(_ mask: CGImage?, width: Int, height: Int) throws -> [UInt8] {
        guard let mask else {
            return [UInt8](repeating: 255, count: width * height)
        }
        var bytes = [UInt8](repeating: 255, count: width * height)
        let graySpace = linearGrayColorSpace()
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: graySpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else {
            throw ImageToolError.contextCreationFailed
        }
        return bytes
    }

    internal static func makeGrayscaleMaskImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  space: linearGrayColorSpace(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw ImageToolError.renderFailed
        }
        return image
    }

    internal static func readPremultipliedRGBABytes(_ image: CGImage) throws -> [UInt8] {
        let w = image.width
        let h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = sRGBColorSpace()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else {
            throw ImageToolError.contextCreationFailed
        }
        return bytes
    }

    internal static func makePremultipliedRGBAImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: sRGBColorSpace(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw ImageToolError.renderFailed
        }
        return image
    }
}

// MARK: - Incremental Interactive Stroke Session

/// Incremental rasterizer for a single live drag stroke on an image layer's alpha mask.
/// Accumulates maximum per-pixel brush coverage across segments so soft edges never harden
/// within a single stroke, while only updating dirty segment bounding boxes on each pointer move.
public struct EraserStrokeSession: Sendable {
    public let width: Int
    public let height: Int
    public let brushSize: CGFloat
    public let hardness: CGFloat
    public let mode: EraserMode

    private let metrics: ImageEraser.BrushMetrics
    private let baseMaskBytes: [UInt8]
    private var coverageBytes: [UInt8]
    private var workingMaskBytes: [UInt8]
    private var rawPoints: [CGPoint] = []
    private var lastMidpoint: CGPoint?
    private var didFinish: Bool = false

    public init(
        baseMask: CGImage?,
        width: Int,
        height: Int,
        brushSize: CGFloat,
        hardness: CGFloat,
        mode: EraserMode
    ) throws {
        guard width > 0, height > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard brushSize > 0 else {
            throw ImageToolError.invalidParameters
        }
        self.width = width
        self.height = height
        self.brushSize = brushSize
        self.hardness = hardness
        self.mode = mode
        self.metrics = ImageEraser.BrushMetrics(brushSize: brushSize, hardness: hardness)

        let base = try ImageEraser.readGrayscaleMaskBytes(baseMask, width: width, height: height)
        self.baseMaskBytes = base
        self.coverageBytes = [UInt8](repeating: 0, count: width * height)
        self.workingMaskBytes = base
    }

    /// Appends a pointer position in top-left image pixel coordinates and returns the updated alpha mask `CGImage`.
    @discardableResult
    public mutating func appendPoint(_ point: CGPoint) throws -> CGImage {
        if let last = rawPoints.last, hypot(point.x - last.x, point.y - last.y) < 0.25 {
            return try currentMaskImage()
        }
        rawPoints.append(point)
        let count = rawPoints.count

        if count == 1 {
            stampAndUpdate(from: point, to: point)
        } else if count == 2 {
            let p0 = rawPoints[0]
            let p1 = rawPoints[1]
            let mid = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
            stampAndUpdate(from: p0, to: mid)
            lastMidpoint = mid
        } else {
            let ctrl = rawPoints[count - 2]
            let next = rawPoints[count - 1]
            let start = lastMidpoint ?? rawPoints[count - 3]
            let mid = CGPoint(x: (ctrl.x + next.x) * 0.5, y: (ctrl.y + next.y) * 0.5)
            stampQuadraticCurve(from: start, control: ctrl, to: mid)
            lastMidpoint = mid
        }

        return try currentMaskImage()
    }

    /// Completes the trailing half-segment of the stroke and returns the final alpha mask `CGImage`.
    @discardableResult
    public mutating func finish() throws -> CGImage {
        guard !didFinish else { return try currentMaskImage() }
        didFinish = true
        if let start = lastMidpoint, let last = rawPoints.last {
            stampAndUpdate(from: start, to: last)
        }
        return try currentMaskImage()
    }

    /// Builds an immutable grayscale mask `CGImage` from the current stroke buffer.
    public func currentMaskImage() throws -> CGImage {
        try ImageEraser.makeGrayscaleMaskImage(bytes: workingMaskBytes, width: width, height: height)
    }

    private mutating func stampQuadraticCurve(from p0: CGPoint, control p1: CGPoint, to p2: CGPoint) {
        let approxLen = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y)
        let step = max(1.0, min(brushSize * 0.25, 4.0))
        let steps = max(1, Int(ceil(approxLen / step)))
        var prev = p0
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let mt = 1.0 - t
            let curr = CGPoint(
                x: mt * mt * p0.x + 2.0 * mt * t * p1.x + t * t * p2.x,
                y: mt * mt * p0.y + 2.0 * mt * t * p1.y + t * t * p2.y
            )
            stampAndUpdate(from: prev, to: curr)
            prev = curr
        }
    }

    private mutating func stampAndUpdate(from a: CGPoint, to b: CGPoint) {
        guard let dirty = ImageEraser.stampCapsule(
            from: a,
            to: b,
            metrics: metrics,
            width: width,
            height: height,
            coverage: &coverageBytes
        ) else { return }

        ImageEraser.combineMaskDirtyRect(
            base: baseMaskBytes,
            coverage: coverageBytes,
            mode: mode,
            width: width,
            rect: dirty,
            into: &workingMaskBytes
        )
    }
}

// MARK: - SendableImage Additive Eraser Helpers

extension SendableImage {
    /// Returns a new `SendableImage` with `stroke` applied to its `alphaMask`,
    /// preserving the original `cgImage` pixels so `.restore` always works.
    public func applyingEraserStroke(_ stroke: EraserStroke) throws -> SendableImage {
        let updatedMask = try ImageEraser.applyStrokeToMask(
            alphaMask,
            width: width,
            height: height,
            stroke: stroke
        )
        return SendableImage(
            cgImage,
            filterPreset: filterPreset,
            adjustments: adjustments,
            frame: frame,
            alphaMask: updatedMask
        )
    }

    /// Returns a new `SendableImage` with a sequence of eraser/restore strokes applied to its `alphaMask`.
    public func applyingEraserStrokes(_ strokes: [EraserStroke]) throws -> SendableImage {
        var current = self
        for stroke in strokes {
            current = try current.applyingEraserStroke(stroke)
        }
        return current
    }

    /// Returns `cgImage` composited with `alphaMask`, or `cgImage` directly when `alphaMask == nil`.
    public func maskedCGImage() throws -> CGImage {
        guard let alphaMask else { return cgImage }
        return try ImageEraser.applyAlphaMask(alphaMask, to: cgImage)
    }
}
