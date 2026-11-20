import CoreGraphics
import Foundation

/// Brush warp mode for the interactive liquify-style deform tool (S26).
public enum DeformBrushMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Smudges pixels smoothly along the drag direction.
    case push
    /// Expands (bloats) pixels outward from the brush path.
    case bulge
    /// Pulls (puckers) pixels inward toward the brush path.
    case pinch
    /// Swirls pixels rotationally around the brush path.
    case twirl

    public var displayName: String {
        switch self {
        case .push: "Push"
        case .bulge: "Bulge"
        case .pinch: "Pinch"
        case .twirl: "Twirl"
        }
    }

    public var systemImage: String {
        switch self {
        case .push: "hand.draw"
        case .bulge: "arrow.up.left.and.arrow.down.right"
        case .pinch: "arrow.down.right.and.arrow.up.left"
        case .twirl: "hurricane"
        }
    }

    public init(preset: DeformPreset) {
        switch preset {
        case .bump: self = .bulge
        case .pinch: self = .pinch
        case .twirl: self = .twirl
        }
    }

    public var legacyPreset: DeformPreset? {
        switch self {
        case .push: nil
        case .bulge: .bump
        case .pinch: .pinch
        case .twirl: .twirl
        }
    }
}

/// Specification of a single deform brush stroke in top-left image pixel coordinates (y down).
public struct DeformStroke: Sendable, Equatable, Hashable, Codable {
    public var mode: DeformBrushMode
    /// Raw or sampled pointer points in top-left image pixel coordinates (y down).
    public var points: [CGPoint]
    /// Brush radius in image pixels (`> 0`).
    public var radius: CGFloat
    /// Brush strength in `0.0...1.0`.
    public var strength: CGFloat

    public init(
        mode: DeformBrushMode = .push,
        points: [CGPoint],
        radius: CGFloat = 60.0,
        strength: CGFloat = 0.5
    ) {
        self.mode = mode
        self.points = points
        self.radius = radius
        self.strength = strength
    }
}

/// Pure functions for liquify-style deform brush warping on `CGImage`.
/// All coordinates use top-left origin, y down, in image pixel coordinates.
/// Uses a backward-mapping displacement field composed incrementally along interpolated stroke points
/// so pixels are resampled only once from the crisp original image (no accumulated blur).
public enum DeformBrush {

    /// Maximum sub-step length as a fraction of brush radius for `.push` strokes.
    /// Kept <= 0.25 so every incremental inverse warp is mathematically guaranteed fold-free.
    internal static let pushMaxStepFraction: CGFloat = 0.20

    /// Arc-length dab spacing as a fraction of brush radius for `.bulge`, `.pinch`, and `.twirl`.
    internal static let radialDabSpacingFraction: CGFloat = 0.25

    /// Per-dab radial scale factor (multiplied by strength) for `.bulge` and `.pinch`.
    internal static let radialDabStrengthFactor: Float = 0.24

    /// Per-dab swirl angle in radians (multiplied by strength) for `.twirl`.
    internal static let twirlDabAngleFactor: Float = 0.45

    /// Applies a single `DeformStroke` to `image` at full resolution, leaving all pixels outside
    /// the stroke's brush radius bit-exact untouched.
    public static func applyStroke(
        _ image: CGImage,
        stroke: DeformStroke
    ) throws -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard stroke.radius > 0 else {
            throw ImageToolError.invalidParameters
        }

        let strength = min(max(stroke.strength, 0.0), 1.0)
        guard strength > 0.0, !stroke.points.isEmpty else {
            return image
        }
        if stroke.mode == .push && stroke.points.count < 2 {
            return image
        }

        // Compute tight ROI bounding box around all stroke points padded by radius.
        guard let roi = computeStrokeROI(
            points: stroke.points,
            radius: stroke.radius,
            width: w,
            height: h
        ) else {
            return image
        }

        var field = DisplacementField(
            imageWidth: w,
            imageHeight: h,
            roi: roi
        )
        var stepper = StrokeDabStepper(
            mode: stroke.mode,
            radius: stroke.radius,
            strength: Float(strength)
        )

        var didApplyAnyDab = false
        for (index, pt) in stroke.points.enumerated() {
            let applied: Bool
            if index == 0 {
                applied = stepper.begin(at: pt, into: &field) != nil
            } else {
                applied = stepper.append(pt, into: &field) != nil
            }
            if applied {
                didApplyAnyDab = true
            }
        }

        guard didApplyAnyDab else {
            return image
        }

        let sourceBytes = try readPremultipliedRGBABytes(image)
        var outputBytes = sourceBytes
        field.resampleROI(
            dirtyRect: roi,
            from: sourceBytes,
            into: &outputBytes
        )
        return try makePremultipliedRGBAImage(bytes: outputBytes, width: w, height: h)
    }

    /// Applies multiple `DeformStroke`s sequentially to `image`.
    public static func applyStrokes(
        _ image: CGImage,
        strokes: [DeformStroke]
    ) throws -> CGImage {
        var current = image
        for stroke in strokes {
            current = try applyStroke(current, stroke: stroke)
        }
        return current
    }

    /// Produces a preview-resolution copy of `image` bounded to `maxDimension` on its longest side,
    /// returning both the preview image and the uniform coordinate scale (`previewWidth / fullWidth`).
    public static func downsampleForPreview(
        _ image: CGImage,
        maxDimension: Int = 900
    ) throws -> (image: CGImage, scale: CGFloat) {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        let clampedMax = max(64, maxDimension)
        let longest = max(w, h)
        if longest <= clampedMax {
            return (image, 1.0)
        }

        let scale = CGFloat(clampedMax) / CGFloat(longest)
        let targetW = max(1, Int((CGFloat(w) * scale).rounded()))
        let targetH = max(1, Int((CGFloat(h) * scale).rounded()))
        let actualScale = CGFloat(targetW) / CGFloat(w)

        let colorSpace = sRGBColorSpace()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageToolError.contextCreationFailed
        }
        ctx.interpolationQuality = .medium
        ctx.clear(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaled = ctx.makeImage() else {
            throw ImageToolError.renderFailed
        }
        return (scaled, actualScale)
    }

    /// Splits a movement segment `(from -> to)` into sub-segments whose length never exceeds `maxStep`.
    public static func interpolatePushSegments(
        from a: CGPoint,
        to b: CGPoint,
        maxStep: CGFloat
    ) -> [(from: CGPoint, to: CGPoint)] {
        let dist = hypot(b.x - a.x, b.y - a.y)
        guard dist > 1e-4 else { return [] }
        let step = max(0.5, maxStep)
        let count = max(1, Int(ceil(dist / step)))
        var result: [(from: CGPoint, to: CGPoint)] = []
        result.reserveCapacity(count)
        var prev = a
        for i in 1...count {
            let t = CGFloat(i) / CGFloat(count)
            let next = CGPoint(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t
            )
            result.append((from: prev, to: next))
            prev = next
        }
        return result
    }

    // MARK: - Internal ROI & Bitmap Helpers

    internal struct PixelRect: Sendable, Equatable {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }

        mutating func formUnion(_ other: PixelRect) {
            minX = min(minX, other.minX)
            maxX = max(maxX, other.maxX)
            minY = min(minY, other.minY)
            maxY = max(maxY, other.maxY)
        }
    }

    internal static func computeStrokeROI(
        points: [CGPoint],
        radius: CGFloat,
        width: Int,
        height: Int
    ) -> PixelRect? {
        guard let first = points.first else { return nil }
        var pMinX = first.x
        var pMaxX = first.x
        var pMinY = first.y
        var pMaxY = first.y
        for pt in points.dropFirst() {
            if pt.x < pMinX { pMinX = pt.x }
            if pt.x > pMaxX { pMaxX = pt.x }
            if pt.y < pMinY { pMinY = pt.y }
            if pt.y > pMaxY { pMaxY = pt.y }
        }
        let pad = ceil(radius) + 4.0
        let minX = max(0, Int(floor(pMinX - pad)))
        let maxX = min(width - 1, Int(ceil(pMaxX + pad)))
        let minY = max(0, Int(floor(pMinY - pad)))
        let maxY = min(height - 1, Int(ceil(pMaxY + pad)))
        guard minX <= maxX, minY <= maxY else { return nil }
        return PixelRect(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    internal static func sRGBColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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

// MARK: - Interactive Preview-Resolution Session

/// Stateful incremental deform session operating on a preview-resolution working copy during
/// live drags, while recording full-resolution stroke points for a single final off-main-thread apply.
public struct DeformBrushSession: Sendable {
    public let mode: DeformBrushMode
    public let fullResRadius: CGFloat
    public let strength: CGFloat
    public let fullResSize: CGSize
    public let previewSize: CGSize
    public let previewScale: CGFloat

    public private(set) var recordedPoints: [CGPoint] = []
    public private(set) var hasEffectiveMutation: Bool = false

    private let previewWidth: Int
    private let previewHeight: Int
    private let sourcePreviewBytes: [UInt8]
    private var workingPreviewBytes: [UInt8]
    private var field: DisplacementField
    private var stepper: StrokeDabStepper

    public init(
        sourceImage: CGImage,
        mode: DeformBrushMode,
        radius: CGFloat,
        strength: CGFloat,
        maxPreviewDimension: Int = 900
    ) throws {
        let w = sourceImage.width
        let h = sourceImage.height
        guard w > 0, h > 0 else {
            throw ImageToolError.invalidDimensions
        }
        guard radius > 0 else {
            throw ImageToolError.invalidParameters
        }

        let (previewCG, scale) = try DeformBrush.downsampleForPreview(
            sourceImage,
            maxDimension: maxPreviewDimension
        )
        let pw = previewCG.width
        let ph = previewCG.height
        let bytes = try DeformBrush.readPremultipliedRGBABytes(previewCG)
        let clampedStrength = min(max(strength, 0.0), 1.0)
        let previewRadius = max(1.0, radius * scale)

        self.mode = mode
        self.fullResRadius = radius
        self.strength = clampedStrength
        self.fullResSize = CGSize(width: w, height: h)
        self.previewSize = CGSize(width: pw, height: ph)
        self.previewScale = scale
        self.previewWidth = pw
        self.previewHeight = ph
        self.sourcePreviewBytes = bytes
        self.workingPreviewBytes = bytes
        self.field = DisplacementField(
            imageWidth: pw,
            imageHeight: ph,
            roi: DeformBrush.PixelRect(minX: 0, maxX: pw - 1, minY: 0, maxY: ph - 1)
        )
        self.stepper = StrokeDabStepper(
            mode: mode,
            radius: previewRadius,
            strength: Float(clampedStrength)
        )
    }

    /// Starts the stroke at `fullResPoint` (top-left full-resolution image coordinates).
    /// Returns an updated preview `CGImage` if any pixels changed on touch-down.
    public mutating func begin(at fullResPoint: CGPoint) -> CGImage? {
        recordedPoints = [fullResPoint]
        let previewPt = CGPoint(
            x: fullResPoint.x * previewScale,
            y: fullResPoint.y * previewScale
        )
        guard let dirty = stepper.begin(at: previewPt, into: &field) else {
            return nil
        }
        hasEffectiveMutation = true
        field.resampleROI(dirtyRect: dirty, from: sourcePreviewBytes, into: &workingPreviewBytes)
        return try? DeformBrush.makePremultipliedRGBAImage(
            bytes: workingPreviewBytes,
            width: previewWidth,
            height: previewHeight
        )
    }

    /// Extends the stroke to `fullResPoint` (top-left full-resolution image coordinates),
    /// incrementally updating only the dirty preview bounding box.
    /// Returns an updated preview `CGImage`, or `nil` if no new dab was emitted.
    public mutating func append(point fullResPoint: CGPoint) -> CGImage? {
        if let last = recordedPoints.last {
            let dist = hypot(fullResPoint.x - last.x, fullResPoint.y - last.y)
            guard dist >= 0.25 else { return nil }
        }
        recordedPoints.append(fullResPoint)

        let previewPt = CGPoint(
            x: fullResPoint.x * previewScale,
            y: fullResPoint.y * previewScale
        )
        guard let dirty = stepper.append(previewPt, into: &field) else {
            return nil
        }
        hasEffectiveMutation = true
        field.resampleROI(dirtyRect: dirty, from: sourcePreviewBytes, into: &workingPreviewBytes)
        return try? DeformBrush.makePremultipliedRGBAImage(
            bytes: workingPreviewBytes,
            width: previewWidth,
            height: previewHeight
        )
    }

    /// The full-resolution `DeformStroke` recorded during this interactive session.
    public var stroke: DeformStroke {
        DeformStroke(
            mode: mode,
            points: recordedPoints,
            radius: fullResRadius,
            strength: strength
        )
    }

    /// Returns the current preview `CGImage` reflecting all warps applied so far.
    public func currentPreviewImage() -> CGImage? {
        try? DeformBrush.makePremultipliedRGBAImage(
            bytes: workingPreviewBytes,
            width: previewWidth,
            height: previewHeight
        )
    }
}

// MARK: - Internal Displacement Field & Dab Stepper

internal struct DisplacementField: Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let roi: DeformBrush.PixelRect
    let roiWidth: Int
    let roiHeight: Int

    /// Absolute source X coordinate for each pixel inside `roi`.
    var mapX: [Float]
    /// Absolute source Y coordinate for each pixel inside `roi`.
    var mapY: [Float]

    /// Reusable per-dab scratch buffers to avoid repeated heap allocations while dragging.
    private var scratchX: [Float] = []
    private var scratchY: [Float] = []

    init(imageWidth: Int, imageHeight: Int, roi: DeformBrush.PixelRect) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.roi = roi
        let rw = roi.width
        let rh = roi.height
        self.roiWidth = rw
        self.roiHeight = rh

        var mx = [Float](repeating: 0, count: rw * rh)
        var my = [Float](repeating: 0, count: rw * rh)
        mx.withUnsafeMutableBufferPointer { xBuf in
            my.withUnsafeMutableBufferPointer { yBuf in
                for ly in 0..<rh {
                    let gy = Float(roi.minY + ly)
                    let row = ly * rw
                    for lx in 0..<rw {
                        xBuf[row + lx] = Float(roi.minX + lx)
                        yBuf[row + lx] = gy
                    }
                }
            }
        }
        self.mapX = mx
        self.mapY = my
    }

    /// Composes a single local inverse warp dab into `(mapX, mapY)` and returns the affected pixel rect.
    @discardableResult
    mutating func applyDab(
        mode: DeformBrushMode,
        center: CGPoint,
        delta: CGVector,
        radius: CGFloat,
        strength: Float
    ) -> DeformBrush.PixelRect? {
        guard strength > 0, radius > 0 else { return nil }

        let cx = Float(center.x)
        let cy = Float(center.y)
        let r = Float(radius)
        let rSq = r * r
        let invRSq = 1.0 / rSq

        let minX = max(roi.minX, Int(floor(center.x - radius - 1.0)))
        let maxX = min(roi.maxX, Int(ceil(center.x + radius + 1.0)))
        let minY = max(roi.minY, Int(floor(center.y - radius - 1.0)))
        let maxY = min(roi.maxY, Int(ceil(center.y + radius + 1.0)))
        guard minX <= maxX, minY <= maxY else { return nil }

        let dabW = maxX - minX + 1
        let dabH = maxY - minY + 1
        let needed = dabW * dabH
        if scratchX.count < needed {
            scratchX = [Float](repeating: 0, count: needed)
            scratchY = [Float](repeating: 0, count: needed)
        }

        let maxCoordX = Float(imageWidth - 1)
        let maxCoordY = Float(imageHeight - 1)
        let roiMinX = roi.minX
        let roiMaxX = roi.maxX
        let roiMinY = roi.minY
        let roiMaxY = roi.maxY
        let rw = roiWidth

        let vx = Float(delta.dx)
        let vy = Float(delta.dy)
        let radialAmount = DeformBrush.radialDabStrengthFactor * strength
        let twirlAngle = DeformBrush.twirlDabAngleFactor * strength

        mapX.withUnsafeBufferPointer { xSrc in
            mapY.withUnsafeBufferPointer { ySrc in
                scratchX.withUnsafeMutableBufferPointer { sxDst in
                    scratchY.withUnsafeMutableBufferPointer { syDst in
                        @inline(__always)
                        func lookupMap(_ gx: Int, _ gy: Int) -> (Float, Float) {
                            if gx >= roiMinX && gx <= roiMaxX && gy >= roiMinY && gy <= roiMaxY {
                                let idx = (gy - roiMinY) * rw + (gx - roiMinX)
                                return (xSrc[idx], ySrc[idx])
                            }
                            return (Float(gx), Float(gy))
                        }

                        @inline(__always)
                        func sampleMap(_ px: Float, _ py: Float) -> (Float, Float) {
                            let clampedX = min(max(px, 0.0), maxCoordX)
                            let clampedY = min(max(py, 0.0), maxCoordY)
                            let x0 = Int(clampedX)
                            let y0 = Int(clampedY)
                            let x1 = min(x0 + 1, imageWidth - 1)
                            let y1 = min(y0 + 1, imageHeight - 1)
                            let fx = clampedX - Float(x0)
                            let fy = clampedY - Float(y0)
                            let omx = 1.0 - fx
                            let omy = 1.0 - fy

                            let (x00, y00) = lookupMap(x0, y0)
                            let (x10, y10) = lookupMap(x1, y0)
                            let (x01, y01) = lookupMap(x0, y1)
                            let (x11, y11) = lookupMap(x1, y1)

                            let w00 = omx * omy
                            let w10 = fx * omy
                            let w01 = omx * fy
                            let w11 = fx * fy

                            let outX = x00 * w00 + x10 * w10 + x01 * w01 + x11 * w11
                            let outY = y00 * w00 + y10 * w10 + y01 * w01 + y11 * w11
                            return (outX, outY)
                        }

                        for dyIdx in 0..<dabH {
                            let y = minY + dyIdx
                            let py = Float(y) + 0.5
                            let dy = py - cy
                            let dySq = dy * dy
                            let scratchRow = dyIdx * dabW
                            let roiRow = (y - roiMinY) * rw

                            for dxIdx in 0..<dabW {
                                let x = minX + dxIdx
                                let px = Float(x) + 0.5
                                let dx = px - cx
                                let distSq = dx * dx + dySq
                                let scratchIdx = scratchRow + dxIdx

                                if distSq >= rSq {
                                    let roiIdx = roiRow + (x - roiMinX)
                                    sxDst[scratchIdx] = xSrc[roiIdx]
                                    syDst[scratchIdx] = ySrc[roiIdx]
                                    continue
                                }

                                let t = 1.0 - distSq * invRSq
                                let w = t * t

                                let ix: Float
                                let iy: Float
                                switch mode {
                                case .push:
                                    ix = Float(x) - vx * strength * w
                                    iy = Float(y) - vy * strength * w
                                case .bulge:
                                    let factor = radialAmount * w
                                    ix = Float(x) - dx * factor
                                    iy = Float(y) - dy * factor
                                case .pinch:
                                    let factor = radialAmount * w
                                    ix = Float(x) + dx * factor
                                    iy = Float(y) + dy * factor
                                case .twirl:
                                    let theta = twirlAngle * w
                                    let cosT = cos(theta)
                                    let sinT = sin(theta)
                                    let rotDx = dx * cosT - dy * sinT
                                    let rotDy = dx * sinT + dy * cosT
                                    ix = Float(x) + (rotDx - dx)
                                    iy = Float(y) + (rotDy - dy)
                                }

                                let (mappedX, mappedY) = sampleMap(ix, iy)
                                sxDst[scratchIdx] = mappedX
                                syDst[scratchIdx] = mappedY
                            }
                        }
                    }
                }
            }
        }

        // Write composed scratch tile back into (mapX, mapY)
        mapX.withUnsafeMutableBufferPointer { xDst in
            mapY.withUnsafeMutableBufferPointer { yDst in
                scratchX.withUnsafeBufferPointer { sxSrc in
                    scratchY.withUnsafeBufferPointer { sySrc in
                        for dyIdx in 0..<dabH {
                            let y = minY + dyIdx
                            let roiRow = (y - roiMinY) * rw + (minX - roiMinX)
                            let scratchRow = dyIdx * dabW
                            for dxIdx in 0..<dabW {
                                xDst[roiRow + dxIdx] = sxSrc[scratchRow + dxIdx]
                                yDst[roiRow + dxIdx] = sySrc[scratchRow + dxIdx]
                            }
                        }
                    }
                }
            }
        }

        return DeformBrush.PixelRect(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// Resamples pixels inside `dirtyRect` from `sourceBytes` (premultiplied RGBA8) into `outputBytes`
    /// using bilinear interpolation at the composed `(mapX, mapY)` coordinates.
    func resampleROI(
        dirtyRect: DeformBrush.PixelRect,
        from sourceBytes: [UInt8],
        into outputBytes: inout [UInt8]
    ) {
        let minX = max(roi.minX, dirtyRect.minX)
        let maxX = min(roi.maxX, dirtyRect.maxX)
        let minY = max(roi.minY, dirtyRect.minY)
        let maxY = min(roi.maxY, dirtyRect.maxY)
        guard minX <= maxX, minY <= maxY else { return }

        let imgW = imageWidth
        let imgH = imageHeight
        let maxCoordX = Float(imgW - 1)
        let maxCoordY = Float(imgH - 1)
        let roiMinX = roi.minX
        let roiMinY = roi.minY
        let rw = roiWidth

        sourceBytes.withUnsafeBufferPointer { src in
            outputBytes.withUnsafeMutableBufferPointer { dst in
                mapX.withUnsafeBufferPointer { mx in
                    mapY.withUnsafeBufferPointer { my in
                        for y in minY...maxY {
                            let roiRow = (y - roiMinY) * rw
                            let imgRow = y * imgW
                            let fyIdentity = Float(y)

                            for x in minX...maxX {
                                let roiIdx = roiRow + (x - roiMinX)
                                let sxRaw = mx[roiIdx]
                                let syRaw = my[roiIdx]
                                let dstBase = (imgRow + x) * 4

                                // Exact fast-path for untouched pixels
                                if sxRaw == Float(x) && syRaw == fyIdentity {
                                    dst[dstBase]     = src[dstBase]
                                    dst[dstBase + 1] = src[dstBase + 1]
                                    dst[dstBase + 2] = src[dstBase + 2]
                                    dst[dstBase + 3] = src[dstBase + 3]
                                    continue
                                }

                                let sx = min(max(sxRaw, 0.0), maxCoordX)
                                let sy = min(max(syRaw, 0.0), maxCoordY)
                                let x0 = Int(sx)
                                let y0 = Int(sy)
                                let x1 = min(x0 + 1, imgW - 1)
                                let y1 = min(y0 + 1, imgH - 1)
                                let fx = sx - Float(x0)
                                let fy = sy - Float(y0)
                                let omx = 1.0 - fx
                                let omy = 1.0 - fy

                                let w00 = omx * omy
                                let w10 = fx * omy
                                let w01 = omx * fy
                                let w11 = fx * fy

                                let i00 = (y0 * imgW + x0) * 4
                                let i10 = (y0 * imgW + x1) * 4
                                let i01 = (y1 * imgW + x0) * 4
                                let i11 = (y1 * imgW + x1) * 4

                                let r = Float(src[i00]) * w00 + Float(src[i10]) * w10 + Float(src[i01]) * w01 + Float(src[i11]) * w11
                                let g = Float(src[i00 + 1]) * w00 + Float(src[i10 + 1]) * w10 + Float(src[i01 + 1]) * w01 + Float(src[i11 + 1]) * w11
                                let b = Float(src[i00 + 2]) * w00 + Float(src[i10 + 2]) * w10 + Float(src[i01 + 2]) * w01 + Float(src[i11 + 2]) * w11
                                let a = Float(src[i00 + 3]) * w00 + Float(src[i10 + 3]) * w10 + Float(src[i01 + 3]) * w01 + Float(src[i11 + 3]) * w11

                                dst[dstBase]     = UInt8(min(max(Int(r + 0.5), 0), 255))
                                dst[dstBase + 1] = UInt8(min(max(Int(g + 0.5), 0), 255))
                                dst[dstBase + 2] = UInt8(min(max(Int(b + 0.5), 0), 255))
                                dst[dstBase + 3] = UInt8(min(max(Int(a + 0.5), 0), 255))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Emits rate-independent interpolated brush dabs along a pointer path into a `DisplacementField`.
internal struct StrokeDabStepper: Sendable {
    let mode: DeformBrushMode
    let radius: CGFloat
    let strength: Float

    private var lastPoint: CGPoint?
    private var distanceCarry: CGFloat = 0

    init(mode: DeformBrushMode, radius: CGFloat, strength: Float) {
        self.mode = mode
        self.radius = radius
        self.strength = strength
    }

    mutating func begin(
        at point: CGPoint,
        into field: inout DisplacementField
    ) -> DeformBrush.PixelRect? {
        lastPoint = point
        distanceCarry = 0

        switch mode {
        case .push:
            return nil
        case .bulge, .pinch, .twirl:
            return field.applyDab(
                mode: mode,
                center: point,
                delta: .zero,
                radius: radius,
                strength: strength
            )
        }
    }

    mutating func append(
        _ point: CGPoint,
        into field: inout DisplacementField
    ) -> DeformBrush.PixelRect? {
        guard let prev = lastPoint else {
            return begin(at: point, into: &field)
        }

        let segDx = point.x - prev.x
        let segDy = point.y - prev.y
        let segDist = hypot(segDx, segDy)
        guard segDist > 1e-4 else { return nil }

        var unionDirty: DeformBrush.PixelRect?

        switch mode {
        case .push:
            let maxStep = max(1.0, radius * DeformBrush.pushMaxStepFraction)
            let segments = DeformBrush.interpolatePushSegments(from: prev, to: point, maxStep: maxStep)
            for seg in segments {
                let delta = CGVector(dx: seg.to.x - seg.from.x, dy: seg.to.y - seg.from.y)
                if let rect = field.applyDab(
                    mode: .push,
                    center: seg.to,
                    delta: delta,
                    radius: radius,
                    strength: strength
                ) {
                    if unionDirty == nil {
                        unionDirty = rect
                    } else {
                        unionDirty?.formUnion(rect)
                    }
                }
            }
            lastPoint = point

        case .bulge, .pinch, .twirl:
            let spacing = max(1.0, radius * DeformBrush.radialDabSpacingFraction)
            let ux = segDx / segDist
            let uy = segDy / segDist
            var cursor = prev
            var remaining = segDist
            var needed = spacing - distanceCarry

            while remaining >= needed {
                let nextDab = CGPoint(
                    x: cursor.x + ux * needed,
                    y: cursor.y + uy * needed
                )
                if let rect = field.applyDab(
                    mode: mode,
                    center: nextDab,
                    delta: .zero,
                    radius: radius,
                    strength: strength
                ) {
                    if unionDirty == nil {
                        unionDirty = rect
                    } else {
                        unionDirty?.formUnion(rect)
                    }
                }
                cursor = nextDab
                remaining -= needed
                needed = spacing
                distanceCarry = 0
            }
            distanceCarry += remaining
            lastPoint = point
        }

        return unionDirty
    }
}
