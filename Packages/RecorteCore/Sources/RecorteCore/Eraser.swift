import Accelerate
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
        try applyStrokesToMask(mask, width: width, height: height, strokes: [stroke])
    }

    /// Replays a sequence of erase/restore strokes onto `mask` (`nil` = all opaque 255) in a single
    /// bitmap pass using tight per-stroke bounding-box rasterization.
    public static func applyStrokesToMask(
        _ mask: CGImage?,
        width: Int,
        height: Int,
        strokes: [EraserStroke]
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw ImageToolError.invalidDimensions
        }
        for stroke in strokes {
            guard stroke.brushSize > 0 else {
                throw ImageToolError.invalidParameters
            }
        }

        var maskData = try readGrayscaleMaskData(mask, width: width, height: height)
        for stroke in strokes where !stroke.points.isEmpty {
            applySingleStrokeInPlace(stroke, width: width, height: height, maskData: &maskData)
        }
        return try makeGrayscaleMaskImage(data: maskData, width: width, height: height)
    }

    /// Composites an 8-bit grayscale `alphaMask` onto `image` by multiplying premultiplied RGBA
    /// channels by `mask / 255.0`. Original transparency in `image` is always preserved.
    public static func applyAlphaMask(_ alphaMask: CGImage, to image: CGImage) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }

        return try autoreleasepool {
            let fullRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            guard let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: sRGBColorSpace(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ImageToolError.contextCreationFailed
            }
            ctx.clear(fullRect)
            ctx.clip(to: fullRect, mask: alphaMask)
            ctx.draw(image, in: fullRect)
            guard let output = ctx.makeImage() else {
                throw ImageToolError.renderFailed
            }
            return output
        }
    }

    // MARK: - Internal Rasterization Primitives

    internal struct BrushMetrics: Sendable {
        let radius: Float
        let radiusSq: Float
        let innerRadius: Float
        let innerRadiusSq: Float
        let invFalloffSpan: Float

        init(brushSize: CGFloat, hardness: CGFloat) {
            let r = Float(max(0.5, brushSize * 0.5))
            let clampedHardness = Float(min(max(hardness, 0.0), 1.0))
            // Keep a crisp ~0.75px anti-aliased fringe at hardness == 1.0, and a center core wide enough
            // to guarantee full 100% erasure along the centerline between adjacent brush dabs even at hardness == 0.
            let maxInner: Float = r > 1.0 ? max(0.0, r - 0.75) : 0.0
            let dabHalfSpacing = Float(max(1.0, min(brushSize * 0.12, 4.0)) * 0.5) + 0.75
            let minCenterCore: Float = r >= 2.0 ? min(dabHalfSpacing, r * 0.22) : 0.0
            let inner = min(max(r * clampedHardness, minCenterCore), maxInner)
            self.radius = r
            self.radiusSq = r * r
            self.innerRadius = inner
            self.innerRadiusSq = inner * inner
            self.invFalloffSpan = 1.0 / max(0.001, r - inner)
        }
    }

    private static func strokeBoundingBox(
        points: [CGPoint],
        radius: Float,
        width: Int,
        height: Int
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        guard let first = points.first else { return nil }
        var minPx = first.x
        var maxPx = first.x
        var minPy = first.y
        var maxPy = first.y
        for pt in points.dropFirst() {
            if pt.x < minPx { minPx = pt.x }
            if pt.x > maxPx { maxPx = pt.x }
            if pt.y < minPy { minPy = pt.y }
            if pt.y > maxPy { maxPy = pt.y }
        }
        let pad = CGFloat(radius) + 2.0
        let minX = max(0, Int(floor(minPx - pad)))
        let maxX = min(width - 1, Int(ceil(maxPx + pad)))
        let minY = max(0, Int(floor(minPy - pad)))
        let maxY = min(height - 1, Int(ceil(maxPy + pad)))
        guard minX <= maxX, minY <= maxY else { return nil }
        return (minX, maxX, minY, maxY)
    }

    internal static func makeBrushTipImage(brushSize: CGFloat, hardness: CGFloat) -> (image: CGImage, size: CGFloat)? {
        let metrics = BrushMetrics(brushSize: brushSize, hardness: hardness)
        let dim = max(2, Int(ceil(CGFloat(metrics.radius) * 2.0)) + 2)
        let center = Float(dim) * 0.5
        let rSq = metrics.radiusSq
        let innerR = metrics.innerRadius
        let innerRSq = metrics.innerRadiusSq
        let invSpan = metrics.invFalloffSpan

        var data = Data(count: dim * dim)
        data.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<dim {
                let dy = (Float(y) + 0.5) - center
                let dySq = dy * dy
                let row = y * dim
                for x in 0..<dim {
                    let dx = (Float(x) + 0.5) - center
                    let distSq = dx * dx + dySq
                    if distSq >= rSq {
                        ptr[row + x] = 0
                    } else if distSq <= innerRSq {
                        ptr[row + x] = 255
                    } else {
                        let dist = distSq.squareRoot()
                        let tFalloff = (dist - innerR) * invSpan
                        let u = max(0.0, min(1.0, 1.0 - tFalloff))
                        let strength = u * u * (3.0 - 2.0 * u)
                        ptr[row + x] = UInt8((strength * 255.0).rounded())
                    }
                }
            }
        }
        guard let img = try? makeGrayscaleMaskImage(data: data, width: dim, height: dim) else {
            return nil
        }
        return (img, CGFloat(dim))
    }

    internal static func combineMaskDirtyRectVImage(
        base: UnsafePointer<UInt8>,
        coverage: UnsafePointer<UInt8>,
        mode: EraserMode,
        width: Int,
        rect: (minX: Int, maxX: Int, minY: Int, maxY: Int),
        zeroScratch: inout [UInt8],
        into output: UnsafeMutablePointer<UInt8>
    ) {
        let dirtyW = rect.maxX - rect.minX + 1
        let dirtyH = rect.maxY - rect.minY + 1
        guard dirtyW > 0, dirtyH > 0 else { return }

        let startOffset = rect.minY * width + rect.minX
        var srcBottom = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: base + startOffset),
            height: vImagePixelCount(dirtyH),
            width: vImagePixelCount(dirtyW),
            rowBytes: width
        )
        var srcAlpha = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: coverage + startOffset),
            height: vImagePixelCount(dirtyH),
            width: vImagePixelCount(dirtyW),
            rowBytes: width
        )
        var dst = vImage_Buffer(
            data: UnsafeMutableRawPointer(output + startOffset),
            height: vImagePixelCount(dirtyH),
            width: vImagePixelCount(dirtyW),
            rowBytes: width
        )

        switch mode {
        case .erase:
            let needed = dirtyW * dirtyH
            if zeroScratch.count < needed {
                zeroScratch = [UInt8](repeating: 0, count: needed)
            }
            zeroScratch.withUnsafeMutableBufferPointer { zBuf in
                var srcTop = vImage_Buffer(
                    data: UnsafeMutableRawPointer(zBuf.baseAddress!),
                    height: vImagePixelCount(dirtyH),
                    width: vImagePixelCount(dirtyW),
                    rowBytes: dirtyW
                )
                _ = vImagePremultipliedAlphaBlend_Planar8(
                    &srcTop,
                    &srcAlpha,
                    &srcBottom,
                    &dst,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        case .restore:
            // Premultiplied white (255) with alpha = coverage equals coverage itself:
            // dst = coverage + ((255 - coverage) * base + 127) / 255
            var srcTop = srcAlpha
            _ = vImagePremultipliedAlphaBlend_Planar8(
                &srcTop,
                &srcAlpha,
                &srcBottom,
                &dst,
                vImage_Flags(kvImageNoFlags)
            )
        }
    }

    private static func applySingleStrokeInPlace(
        _ stroke: EraserStroke,
        width: Int,
        height: Int,
        maskData: inout Data
    ) {
        let metrics = BrushMetrics(brushSize: stroke.brushSize, hardness: stroke.hardness)
        guard let box = strokeBoundingBox(
            points: stroke.points,
            radius: metrics.radius,
            width: width,
            height: height
        ) else { return }

        let boxW = box.maxX - box.minX + 1
        let boxH = box.maxY - box.minY + 1
        let originX = CGFloat(box.minX)
        let originY = CGFloat(box.minY)

        var localCoverage = [UInt8](repeating: 0, count: boxW * boxH)
        let spacing = max(1.0, min(stroke.brushSize * 0.12, 4.0))
        let smoothed = interpolatePoints(stroke.points, spacing: spacing)

        let stampedViaCG: Bool = {
            guard let tip = makeBrushTipImage(brushSize: stroke.brushSize, hardness: stroke.hardness) else {
                return false
            }
            return localCoverage.withUnsafeMutableBytes { rawBuf -> Bool in
                guard let ctx = CGContext(
                    data: rawBuf.baseAddress,
                    width: boxW,
                    height: boxH,
                    bitsPerComponent: 8,
                    bytesPerRow: boxW,
                    space: linearGrayColorSpace(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                ctx.translateBy(x: 0, y: CGFloat(boxH))
                ctx.scaleBy(x: 1.0, y: -1.0)
                ctx.setBlendMode(.lighten)
                ctx.interpolationQuality = .low
                let half = tip.size * 0.5
                for pt in smoothed {
                    let rect = CGRect(x: pt.x - originX - half, y: pt.y - originY - half, width: tip.size, height: tip.size)
                    ctx.draw(tip.image, in: rect)
                }
                return true
            }
        }()

        if !stampedViaCG {
            if smoothed.count == 1 {
                let p = CGPoint(x: smoothed[0].x - originX, y: smoothed[0].y - originY)
                stampCapsule(from: p, to: p, metrics: metrics, width: boxW, height: boxH, coverage: &localCoverage)
            } else {
                var prev = CGPoint(x: smoothed[0].x - originX, y: smoothed[0].y - originY)
                for i in 1..<smoothed.count {
                    let curr = CGPoint(x: smoothed[i].x - originX, y: smoothed[i].y - originY)
                    stampCapsule(from: prev, to: curr, metrics: metrics, width: boxW, height: boxH, coverage: &localCoverage)
                    prev = curr
                }
            }
        }

        maskData.withUnsafeMutableBytes { rawDst in
            guard let dstPtr = rawDst.bindMemory(to: UInt8.self).baseAddress else { return }
            localCoverage.withUnsafeBufferPointer { covBuf in
                guard let covPtr = covBuf.baseAddress else { return }
                let startOffset = box.minY * width + box.minX
                var srcBottom = vImage_Buffer(
                    data: UnsafeMutableRawPointer(dstPtr + startOffset),
                    height: vImagePixelCount(boxH),
                    width: vImagePixelCount(boxW),
                    rowBytes: width
                )
                var srcAlpha = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: covPtr),
                    height: vImagePixelCount(boxH),
                    width: vImagePixelCount(boxW),
                    rowBytes: boxW
                )
                var dst = srcBottom

                switch stroke.mode {
                case .erase:
                    var zeros = [UInt8](repeating: 0, count: boxW * boxH)
                    zeros.withUnsafeMutableBufferPointer { zBuf in
                        var srcTop = vImage_Buffer(
                            data: UnsafeMutableRawPointer(zBuf.baseAddress!),
                            height: vImagePixelCount(boxH),
                            width: vImagePixelCount(boxW),
                            rowBytes: boxW
                        )
                        _ = vImagePremultipliedAlphaBlend_Planar8(
                            &srcTop,
                            &srcAlpha,
                            &srcBottom,
                            &dst,
                            vImage_Flags(kvImageNoFlags)
                        )
                    }
                case .restore:
                    var srcTop = srcAlpha
                    _ = vImagePremultipliedAlphaBlend_Planar8(
                        &srcTop,
                        &srcAlpha,
                        &srcBottom,
                        &dst,
                        vImage_Flags(kvImageNoFlags)
                    )
                }
            }
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
        let r = CGFloat(metrics.radius)
        let minX = max(0, Int(floor(min(a.x, b.x) - r - 1.0)))
        let maxX = min(width - 1, Int(ceil(max(a.x, b.x) + r + 1.0)))
        let minY = max(0, Int(floor(min(a.y, b.y) - r - 1.0)))
        let maxY = min(height - 1, Int(ceil(max(a.y, b.y) + r + 1.0)))
        guard minX <= maxX, minY <= maxY else { return nil }

        let ax = Float(a.x)
        let ay = Float(a.y)
        let vx = Float(b.x) - ax
        let vy = Float(b.y) - ay
        let lenSq = vx * vx + vy * vy
        let isPoint = lenSq < 1e-6
        let invLenSq: Float = isPoint ? 0.0 : (1.0 / lenSq)

        let rSq = metrics.radiusSq
        let innerR = metrics.innerRadius
        let innerRSq = metrics.innerRadiusSq
        let invSpan = metrics.invFalloffSpan

        coverage.withUnsafeMutableBufferPointer { covBuf in
            guard let cov = covBuf.baseAddress else { return }
            if isPoint {
                for y in minY...maxY {
                    let dy = (Float(y) + 0.5) - ay
                    let dySq = dy * dy
                    if dySq >= rSq { continue }
                    let rowOffset = y * width
                    for x in minX...maxX {
                        let dx = (Float(x) + 0.5) - ax
                        let distSq = dx * dx + dySq
                        if distSq >= rSq { continue }

                        let value: UInt8
                        if distSq <= innerRSq {
                            value = 255
                        } else {
                            let dist = distSq.squareRoot()
                            let tFalloff = (dist - innerR) * invSpan
                            let u = max(0.0, min(1.0, 1.0 - tFalloff))
                            let strength = u * u * (3.0 - 2.0 * u)
                            value = UInt8((strength * 255.0).rounded())
                        }

                        let idx = rowOffset + x
                        if value > cov[idx] {
                            cov[idx] = value
                        }
                    }
                }
            } else {
                for y in minY...maxY {
                    let py = Float(y) + 0.5
                    let pyMinusAy = py - ay
                    let pyVy = pyMinusAy * vy
                    let rowOffset = y * width
                    for x in minX...maxX {
                        let px = Float(x) + 0.5
                        let pxMinusAx = px - ax
                        let proj = (pxMinusAx * vx + pyVy) * invLenSq
                        let t: Float = proj < 0.0 ? 0.0 : (proj > 1.0 ? 1.0 : proj)
                        let dx = pxMinusAx - t * vx
                        let dy = pyMinusAy - t * vy
                        let distSq = dx * dx + dy * dy
                        if distSq >= rSq { continue }

                        let value: UInt8
                        if distSq <= innerRSq {
                            value = 255
                        } else {
                            let dist = distSq.squareRoot()
                            let tFalloff = (dist - innerR) * invSpan
                            let u = max(0.0, min(1.0, 1.0 - tFalloff))
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
        output.withUnsafeMutableBufferPointer { dstBuf in
            base.withUnsafeBufferPointer { srcBuf in
                coverage.withUnsafeBufferPointer { covBuf in
                    guard let dst = dstBuf.baseAddress,
                          let src = srcBuf.baseAddress,
                          let cov = covBuf.baseAddress else { return }
                    switch mode {
                    case .erase:
                        for idx in 0..<count {
                            let s = Int(cov[idx])
                            if s == 0 { continue }
                            dst[idx] = UInt8((Int(src[idx]) * (255 - s) + 127) / 255)
                        }
                    case .restore:
                        for idx in 0..<count {
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

    internal static func combineMaskDirtyRect(
        base: [UInt8],
        coverage: [UInt8],
        mode: EraserMode,
        width: Int,
        rect: (minX: Int, maxX: Int, minY: Int, maxY: Int),
        into output: inout [UInt8]
    ) {
        output.withUnsafeMutableBufferPointer { dstBuf in
            base.withUnsafeBufferPointer { srcBuf in
                coverage.withUnsafeBufferPointer { covBuf in
                    guard let dst = dstBuf.baseAddress,
                          let src = srcBuf.baseAddress,
                          let cov = covBuf.baseAddress else { return }
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

    internal static func readGrayscaleMaskData(_ mask: CGImage?, width: Int, height: Int) throws -> Data {
        let count = width * height
        guard let mask else {
            return Data(repeating: 255, count: count)
        }

        // Fast zero-CGContext path when mask is already an 8-bit grayscale bitmap of matching dimensions
        if mask.width == width,
           mask.height == height,
           mask.bitsPerComponent == 8,
           mask.bitsPerPixel == 8,
           mask.alphaInfo == .none,
           let cfData = mask.dataProvider?.data {
            let srcBytesPerRow = mask.bytesPerRow
            let srcLen = CFDataGetLength(cfData)
            if srcBytesPerRow == width && srcLen >= count {
                if let ptr = CFDataGetBytePtr(cfData) {
                    return Data(bytes: ptr, count: count)
                }
            } else if srcBytesPerRow > width && srcLen >= srcBytesPerRow * height {
                if let srcPtr = CFDataGetBytePtr(cfData) {
                    var data = Data(count: count)
                    data.withUnsafeMutableBytes { dstRaw in
                        guard let dstPtr = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        for row in 0..<height {
                            memcpy(dstPtr + row * width, srcPtr + row * srcBytesPerRow, width)
                        }
                    }
                    return data
                }
            }
        }

        var data = Data(repeating: 255, count: count)
        let graySpace = linearGrayColorSpace()
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
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
        return data
    }

    internal static func readGrayscaleMaskBytes(_ mask: CGImage?, width: Int, height: Int) throws -> [UInt8] {
        let data = try readGrayscaleMaskData(mask, width: width, height: height)
        return [UInt8](data)
    }

    internal static func makeGrayscaleMaskImage(data: Data, width: Int, height: Int) throws -> CGImage {
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

    internal static func makeGrayscaleMaskImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        try makeGrayscaleMaskImage(data: Data(bytes), width: width, height: height)
    }

    public static func readPremultipliedRGBABytes(
        _ image: CGImage,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil
    ) throws -> [UInt8] {
        let w = targetWidth ?? image.width
        let h = targetHeight ?? image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
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
            ctx.interpolationQuality = .medium
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

// MARK: - Persistent Dirty-Rect Alpha Mask Bitmap (S27 Fluid Eraser)

/// Integer pixel bounding rectangle (inclusive bounds) returned by incremental brush updates.
public struct PixelDirtyRect: Sendable, Equatable, Hashable {
    public var minX: Int
    public var maxX: Int
    public var minY: Int
    public var maxY: Int

    public init(minX: Int, maxX: Int, minY: Int, maxY: Int) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    public var width: Int { max(0, maxX - minX + 1) }
    public var height: Int { max(0, maxY - minY + 1) }

    public var cgRect: CGRect {
        CGRect(x: minX, y: minY, width: width, height: height)
    }

    public func union(_ other: PixelDirtyRect) -> PixelDirtyRect {
        PixelDirtyRect(
            minX: min(minX, other.minX),
            maxX: max(maxX, other.maxX),
            minY: min(minY, other.minY),
            maxY: max(maxY, other.maxY)
        )
    }
}

/// Persistent, reference-backed 8-bit grayscale alpha-mask bitmap for fluid interactive eraser strokes.
/// Paints strokes incrementally into ONLY the dirty bounding rectangle using CoreGraphics `.lighten`
/// brush stamping and Accelerate `vImage` SIMD compositing, with zero per-move array copies
/// and zero per-move `CGImage` allocations.
public final class PersistentAlphaMask: @unchecked Sendable {
    public let width: Int
    public let height: Int

    private var workingMaskBytes: [UInt8]
    private var strokeBaseBytes: [UInt8]
    private var coverageContext: CGContext
    private var coveragePointer: UnsafeMutablePointer<UInt8>
    private var zeroScratch: [UInt8] = []

    private var activeBrushSize: CGFloat = 32.0
    private var activeMode: EraserMode = .erase
    private var activeBrushTip: CGImage?
    private var activeBrushTipSize: CGFloat = 0.0
    private var rawPoints: [CGPoint] = []
    private var lastMidpoint: CGPoint?
    private var strokeUnionDirty: PixelDirtyRect?
    private var isStrokeActive: Bool = false

    public init(baseMask: CGImage?, width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw ImageToolError.invalidDimensions
        }
        self.width = width
        self.height = height
        let initial = try ImageEraser.readGrayscaleMaskBytes(baseMask, width: width, height: height)
        self.workingMaskBytes = initial
        self.strokeBaseBytes = initial

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: ImageEraser.linearGrayColorSpace(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ImageToolError.contextCreationFailed
        }
        memset(ptr, 0, width * height)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.setBlendMode(.lighten)
        ctx.interpolationQuality = .low
        self.coverageContext = ctx
        self.coveragePointer = ptr
    }

    /// Starts a new stroke, clearing only the previous stroke's dirty rect from the coverage buffer.
    public func beginStroke(brushSize: CGFloat, hardness: CGFloat, mode: EraserMode) {
        if let prevDirty = strokeUnionDirty {
            clearCoverageAndSyncBase(in: prevDirty)
            strokeUnionDirty = nil
        }
        activeBrushSize = max(1.0, brushSize)
        activeMode = mode
        if let tip = ImageEraser.makeBrushTipImage(brushSize: activeBrushSize, hardness: hardness) {
            activeBrushTip = tip.image
            activeBrushTipSize = tip.size
        } else {
            activeBrushTip = nil
            activeBrushTipSize = 0.0
        }
        rawPoints.removeAll(keepingCapacity: true)
        lastMidpoint = nil
        isStrokeActive = true
    }

    /// Appends a pointer position in mask pixel coordinates, updating ONLY the newly affected dirty rect.
    @discardableResult
    public func appendPoint(_ point: CGPoint) -> PixelDirtyRect? {
        guard isStrokeActive else { return nil }
        if let last = rawPoints.last, hypot(point.x - last.x, point.y - last.y) < 0.25 {
            return nil
        }
        rawPoints.append(point)
        let count = rawPoints.count

        let dirty: PixelDirtyRect?
        if count == 1 {
            dirty = stampSegmentCoverage(from: point, to: point)
        } else if count == 2 {
            let p0 = rawPoints[0]
            let p1 = rawPoints[1]
            let mid = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
            lastMidpoint = mid
            dirty = stampSegmentCoverage(from: p0, to: mid)
        } else {
            let ctrl = rawPoints[count - 2]
            let next = rawPoints[count - 1]
            let start = lastMidpoint ?? rawPoints[count - 3]
            let mid = CGPoint(x: (ctrl.x + next.x) * 0.5, y: (ctrl.y + next.y) * 0.5)
            lastMidpoint = mid
            dirty = stampQuadraticCurveCoverage(from: start, control: ctrl, to: mid)
        }

        if let dirty {
            combineDirtyRect(dirty)
        }
        return dirty
    }

    /// Finishes the trailing half-segment of the active stroke and returns its dirty rect.
    @discardableResult
    public func finishStroke() -> PixelDirtyRect? {
        guard isStrokeActive else { return nil }
        isStrokeActive = false
        var trailingDirty: PixelDirtyRect? = nil
        if let start = lastMidpoint, let last = rawPoints.last {
            trailingDirty = stampSegmentCoverage(from: start, to: last)
            if let trailingDirty {
                combineDirtyRect(trailingDirty)
            }
        }
        return trailingDirty
    }

    /// Composites ONLY `rect` by multiplying `baseRGBA` (premultiplied RGBA8) by this mask into `destRGBA`.
    public func compositeDirtyRect(
        _ rect: PixelDirtyRect,
        baseRGBA: [UInt8],
        into destRGBA: inout [UInt8]
    ) {
        let clampedMinX = max(0, rect.minX)
        let clampedMaxX = min(width - 1, rect.maxX)
        let clampedMinY = max(0, rect.minY)
        let clampedMaxY = min(height - 1, rect.maxY)
        guard clampedMinX <= clampedMaxX, clampedMinY <= clampedMaxY else { return }

        destRGBA.withUnsafeMutableBufferPointer { dstBuf in
            baseRGBA.withUnsafeBufferPointer { srcBuf in
                workingMaskBytes.withUnsafeBufferPointer { maskBuf in
                    guard let dst = dstBuf.baseAddress,
                          let src = srcBuf.baseAddress,
                          let mask = maskBuf.baseAddress else { return }
                    for y in clampedMinY...clampedMaxY {
                        let rowMask = y * width
                        for x in clampedMinX...clampedMaxX {
                            let idx = rowMask + x
                            let m = Int(mask[idx])
                            let px = idx * 4
                            if m == 255 {
                                dst[px]     = src[px]
                                dst[px + 1] = src[px + 1]
                                dst[px + 2] = src[px + 2]
                                dst[px + 3] = src[px + 3]
                            } else if m == 0 {
                                dst[px]     = 0
                                dst[px + 1] = 0
                                dst[px + 2] = 0
                                dst[px + 3] = 0
                            } else {
                                dst[px]     = UInt8((Int(src[px]) * m + 127) / 255)
                                dst[px + 1] = UInt8((Int(src[px + 1]) * m + 127) / 255)
                                dst[px + 2] = UInt8((Int(src[px + 2]) * m + 127) / 255)
                                dst[px + 3] = UInt8((Int(src[px + 3]) * m + 127) / 255)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Composites the entire mask against `baseRGBA` into `destRGBA` (used once at preview initialization).
    public func compositeAll(baseRGBA: [UInt8], into destRGBA: inout [UInt8]) {
        compositeDirtyRect(
            PixelDirtyRect(minX: 0, maxX: width - 1, minY: 0, maxY: height - 1),
            baseRGBA: baseRGBA,
            into: &destRGBA
        )
    }

    /// Builds an immutable 8-bit grayscale `CGImage` from the current working mask buffer.
    public func makeMaskImage() throws -> CGImage {
        try ImageEraser.makeGrayscaleMaskImage(bytes: workingMaskBytes, width: width, height: height)
    }

    private func clearCoverageAndSyncBase(in rect: PixelDirtyRect) {
        let minX = max(0, rect.minX)
        let maxX = min(width - 1, rect.maxX)
        let minY = max(0, rect.minY)
        let maxY = min(height - 1, rect.maxY)
        guard minX <= maxX, minY <= maxY else { return }
        let span = maxX - minX + 1
        let cov = coveragePointer

        strokeBaseBytes.withUnsafeMutableBufferPointer { baseBuf in
            workingMaskBytes.withUnsafeBufferPointer { workBuf in
                guard let base = baseBuf.baseAddress,
                      let work = workBuf.baseAddress else { return }
                for y in minY...maxY {
                    let offset = y * width + minX
                    memset(cov + offset, 0, span)
                    memcpy(base + offset, work + offset, span)
                }
            }
        }
    }

    private func stampSegmentCoverage(from a: CGPoint, to b: CGPoint) -> PixelDirtyRect? {
        guard let tip = activeBrushTip else { return nil }
        let half = activeBrushTipSize * 0.5
        let dist = hypot(b.x - a.x, b.y - a.y)
        let spacing = max(1.0, min(activeBrushSize * 0.12, 4.0))
        let steps = dist < 1e-4 ? 0 : max(1, Int(ceil(dist / spacing)))

        if steps == 0 {
            let rect = CGRect(x: a.x - half, y: a.y - half, width: activeBrushTipSize, height: activeBrushTipSize)
            coverageContext.draw(tip, in: rect)
        } else {
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let px = a.x + (b.x - a.x) * t
                let py = a.y + (b.y - a.y) * t
                let rect = CGRect(x: px - half, y: py - half, width: activeBrushTipSize, height: activeBrushTipSize)
                coverageContext.draw(tip, in: rect)
            }
        }

        let pad = half + 1.0
        let minX = max(0, Int(floor(min(a.x, b.x) - pad)))
        let maxX = min(width - 1, Int(ceil(max(a.x, b.x) + pad)))
        let minY = max(0, Int(floor(min(a.y, b.y) - pad)))
        let maxY = min(height - 1, Int(ceil(max(a.y, b.y) + pad)))
        guard minX <= maxX, minY <= maxY else { return nil }
        return PixelDirtyRect(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private func stampQuadraticCurveCoverage(from p0: CGPoint, control p1: CGPoint, to p2: CGPoint) -> PixelDirtyRect? {
        guard let tip = activeBrushTip else { return nil }
        let half = activeBrushTipSize * 0.5
        let approxLen = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y)
        let spacing = max(1.0, min(activeBrushSize * 0.12, 4.0))
        let steps = max(1, Int(ceil(approxLen / spacing)))

        var minPx = p0.x, maxPx = p0.x
        var minPy = p0.y, maxPy = p0.y
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let mt = 1.0 - t
            let px = mt * mt * p0.x + 2.0 * mt * t * p1.x + t * t * p2.x
            let py = mt * mt * p0.y + 2.0 * mt * t * p1.y + t * t * p2.y
            if px < minPx { minPx = px }
            if px > maxPx { maxPx = px }
            if py < minPy { minPy = py }
            if py > maxPy { maxPy = py }
            let rect = CGRect(x: px - half, y: py - half, width: activeBrushTipSize, height: activeBrushTipSize)
            coverageContext.draw(tip, in: rect)
        }

        let pad = half + 1.0
        let minX = max(0, Int(floor(minPx - pad)))
        let maxX = min(width - 1, Int(ceil(maxPx + pad)))
        let minY = max(0, Int(floor(minPy - pad)))
        let maxY = min(height - 1, Int(ceil(maxPy + pad)))
        guard minX <= maxX, minY <= maxY else { return nil }
        return PixelDirtyRect(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private func combineDirtyRect(_ rect: PixelDirtyRect) {
        let covPtr = coveragePointer
        strokeBaseBytes.withUnsafeBufferPointer { baseBuf in
            workingMaskBytes.withUnsafeMutableBufferPointer { workBuf in
                guard let basePtr = baseBuf.baseAddress,
                      let workPtr = workBuf.baseAddress else { return }
                ImageEraser.combineMaskDirtyRectVImage(
                    base: basePtr,
                    coverage: covPtr,
                    mode: activeMode,
                    width: width,
                    rect: (rect.minX, rect.maxX, rect.minY, rect.maxY),
                    zeroScratch: &zeroScratch,
                    into: workPtr
                )
            }
        }
        strokeUnionDirty = strokeUnionDirty?.union(rect) ?? rect
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

    private let mask: PersistentAlphaMask
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
        let persistent = try PersistentAlphaMask(baseMask: baseMask, width: width, height: height)
        persistent.beginStroke(brushSize: brushSize, hardness: hardness, mode: mode)
        self.mask = persistent
    }

    /// Appends a pointer position in top-left image pixel coordinates without allocating a `CGImage`,
    /// returning only the affected dirty pixel rect.
    @discardableResult
    public mutating func appendPointDirtyRect(_ point: CGPoint) -> PixelDirtyRect? {
        mask.appendPoint(point)
    }

    /// Completes the trailing half-segment of the stroke without allocating a `CGImage`,
    /// returning only the affected dirty pixel rect.
    @discardableResult
    public mutating func finishDirtyRect() -> PixelDirtyRect? {
        guard !didFinish else { return nil }
        didFinish = true
        return mask.finishStroke()
    }

    /// Appends a pointer position in top-left image pixel coordinates and returns the updated alpha mask `CGImage`.
    @discardableResult
    public mutating func appendPoint(_ point: CGPoint) throws -> CGImage {
        _ = mask.appendPoint(point)
        return try currentMaskImage()
    }

    /// Completes the trailing half-segment of the stroke and returns the final alpha mask `CGImage`.
    @discardableResult
    public mutating func finish() throws -> CGImage {
        _ = finishDirtyRect()
        return try currentMaskImage()
    }

    /// Builds an immutable grayscale mask `CGImage` from the current stroke buffer.
    public func currentMaskImage() throws -> CGImage {
        try mask.makeMaskImage()
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
        guard !strokes.isEmpty else { return self }
        let updatedMask = try ImageEraser.applyStrokesToMask(
            alphaMask,
            width: width,
            height: height,
            strokes: strokes
        )
        return SendableImage(
            cgImage,
            filterPreset: filterPreset,
            adjustments: adjustments,
            frame: frame,
            alphaMask: updatedMask
        )
    }

    /// Returns `cgImage` composited with `alphaMask`, or `cgImage` directly when `alphaMask == nil`.
    public func maskedCGImage() throws -> CGImage {
        guard let alphaMask else { return cgImage }
        return try ImageEraser.applyAlphaMask(alphaMask, to: cgImage)
    }
}
