import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("S15 ImageTools Pure Function Tests")
struct ImageToolsTests {

    /// Creates a 4-quadrant image (top-left origin):
    /// TL = Red, TR = Green, BL = Blue, BR = Yellow.
    static func makeFourQuadrantImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Flip to top-left origin so drawing matches visual quadrants directly
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let hw = CGFloat(width) / 2.0
        let hh = CGFloat(height) / 2.0
        // TL Red
        ctx.setFillColor(RGBAColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        // TR Green
        ctx.setFillColor(RGBAColor.green.cgColor)
        ctx.fill(CGRect(x: hw, y: 0, width: hw, height: hh))
        // BL Blue
        ctx.setFillColor(RGBAColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: hh, width: hw, height: hh))
        // BR Yellow
        ctx.setFillColor(RGBAColor.yellow.cgColor)
        ctx.fill(CGRect(x: hw, y: hh, width: hw, height: hh))
        return ctx.makeImage()!
    }

    static func makeCheckerboard(width: Int, height: Int, tile: Int = 8) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for row in stride(from: 0, to: height, by: tile) {
            for col in stride(from: 0, to: width, by: tile) {
                let dark = ((row / tile) + (col / tile)) % 2 == 0
                ctx.setFillColor(dark ? RGBAColor.black.cgColor : RGBAColor.white.cgColor)
                ctx.fill(CGRect(x: col, y: row, width: tile, height: tile))
            }
        }
        return ctx.makeImage()!
    }

    // MARK: - 1. Lasso Cutout

    @Test("Lasso cutout keeps pixels inside CGPath (top-left coords) and makes outside transparent")
    func lassoCutoutMasksPath() throws {
        let src = Self.makeFourQuadrantImage(width: 100, height: 100)
        // Polygon in top-left quadrant (rows 5..45, cols 5..45 -> pure red region)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 5))
        path.addLine(to: CGPoint(x: 45, y: 5))
        path.addLine(to: CGPoint(x: 45, y: 45))
        path.addLine(to: CGPoint(x: 5, y: 45))
        path.closeSubpath()

        let cut = try ImageTools.lassoCutout(src, path: path)
        #expect(cut.width == 100 && cut.height == 100)
        let grid = PixelGrid(cut)

        // Inside path at top-left (25, 25) is opaque red
        let inside = grid.pixel(x: 25, y: 25)
        #expect(inside.r > 230 && inside.g < 20 && inside.b < 20 && inside.a == 255)

        // Outside path (bottom-left blue quadrant and bottom-right yellow quadrant) is transparent
        #expect(grid.pixel(x: 25, y: 75).a == 0)
        #expect(grid.pixel(x: 75, y: 75).a == 0)
        #expect(grid.pixel(x: 75, y: 25).a == 0)

        // cropToPathBounds returns tight bounds
        let tight = try ImageTools.lassoCutout(src, path: path, cropToPathBounds: true)
        #expect(tight.width == 40 && tight.height == 40)
        let tightCenter = PixelGrid(tight).pixel(x: 20, y: 20)
        #expect(tightCenter.r > 230 && tightCenter.a == 255)
    }

    // MARK: - 2. Clone Stamp

    @Test("Clone stamp copies circular region from source to destination with soft edge")
    func cloneStampSoftEdge() throws {
        let src = Self.makeFourQuadrantImage(width: 100, height: 100)
        // Copy top-left red (20, 20) onto bottom-left blue (25, 75) with radius 15 and softness 0.5
        let cloned = try ImageTools.cloneStamp(
            src,
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 25, y: 75),
            radius: 15,
            softness: 0.5
        )
        #expect(cloned.width == 100 && cloned.height == 100)
        let grid = PixelGrid(cloned)

        // Center of destination (25, 75) should now be red
        let dstCenter = grid.pixel(x: 25, y: 75)
        #expect(dstCenter.r > 230 && dstCenter.b < 20 && dstCenter.a == 255)

        // Soft edge band ~12px away from center (25 + 12 = 37, 75) should blend red and blue
        let edgePx = grid.pixel(x: 37, y: 75)
        #expect(edgePx.r > 20 && edgePx.b > 20, "Expected blended soft edge pixel, got \(edgePx)")

        // Well outside radius at (45, 75) remains pure blue
        let outside = grid.pixel(x: 45, y: 75)
        #expect(outside.b > 230 && outside.r < 20)

        // Original source at (20, 20) stays pure red
        let srcPx = grid.pixel(x: 20, y: 20)
        #expect(srcPx.r > 230 && srcPx.b < 20)
    }

    // MARK: - 3. Perspective Correction

    @Test("Perspective correction rectifies 4 top-left quad points via CIPerspectiveCorrection")
    func perspectiveCorrectionRectifiesQuad() throws {
        // 100x100 image: black border, inner (20..80, 20..50) red, inner (20..80, 50..80) green
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 400,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.translateBy(x: 0, y: 100)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(RGBAColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(RGBAColor.red.cgColor)
        ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 30))
        ctx.setFillColor(RGBAColor.green.cgColor)
        ctx.fill(CGRect(x: 20, y: 50, width: 60, height: 30))
        let src = ctx.makeImage()!

        let quad = PerspectiveQuad(
            topLeft: CGPoint(x: 20, y: 20),
            topRight: CGPoint(x: 80, y: 20),
            bottomRight: CGPoint(x: 80, y: 80),
            bottomLeft: CGPoint(x: 20, y: 80)
        )
        let corrected = try ImageTools.perspectiveCorrect(src, quad: quad)
        #expect(corrected.width >= 55 && corrected.width <= 65)
        #expect(corrected.height >= 55 && corrected.height <= 65)

        let grid = PixelGrid(corrected)
        // Top half should be red, bottom half should be green (confirms top-left y conversion!)
        let topPx = grid.pixel(x: corrected.width / 2, y: corrected.height / 4)
        let botPx = grid.pixel(x: corrected.width / 2, y: (corrected.height * 3) / 4)
        #expect(topPx.r > 200 && topPx.g < 40)
        #expect(botPx.g > 200 && botPx.r < 40)

        // Skewed trapezoid also succeeds cleanly
        let trapezoid = PerspectiveQuad(
            topLeft: CGPoint(x: 25, y: 20),
            topRight: CGPoint(x: 75, y: 20),
            bottomRight: CGPoint(x: 85, y: 80),
            bottomLeft: CGPoint(x: 15, y: 80)
        )
        let warped = try ImageTools.perspectiveCorrect(src, quad: trapezoid)
        #expect(warped.width > 10 && warped.height > 10)
    }

    // MARK: - 4. Deform Presets

    @Test("Deform presets (bump, pinch, twirl) distort pixels inside radius while preserving distant corners")
    func deformPresetsDistortLocally() throws {
        let src = Self.makeCheckerboard(width: 120, height: 120, tile: 8)
        let srcGrid = PixelGrid(src)
        var outputs: [DeformPreset: [UInt8]] = [:]

        for preset in DeformPreset.allCases {
            let out = try ImageTools.deform(
                src,
                preset: preset,
                center: CGPoint(x: 36, y: 36),
                radius: 28,
                strength: 0.75
            )
            #expect(out.width == 120 && out.height == 120)
            let outGrid = PixelGrid(out)
            outputs[preset] = outGrid.bytes

            // Count changed pixels inside the top-left distortion disk vs far bottom-right corner
            var localDiff = 0
            for y in 12..<60 {
                for x in 12..<60 {
                    let a = srcGrid.pixel(x: x, y: y)
                    let b = outGrid.pixel(x: x, y: y)
                    if abs(Int(a.r) - Int(b.r)) > 20 {
                        localDiff += 1
                    }
                }
            }
            var farDiff = 0
            for y in 90..<115 {
                for x in 90..<115 {
                    let a = srcGrid.pixel(x: x, y: y)
                    let b = outGrid.pixel(x: x, y: y)
                    if abs(Int(a.r) - Int(b.r)) > 20 {
                        farDiff += 1
                    }
                }
            }
            #expect(localDiff > 50, "Expected \(preset) to visibly deform pixels near center, diff=\(localDiff)")
            #expect(farDiff == 0, "Expected \(preset) to leave far corner untouched, diff=\(farDiff)")
        }

        // All three presets must produce distinct results from one another
        #expect(outputs[.bump] != outputs[.pinch])
        #expect(outputs[.bump] != outputs[.twirl])
        #expect(outputs[.pinch] != outputs[.twirl])
    }

    // MARK: - 5. Curves (CIToneCurve 5 points)

    @Test("Tone curve brightens or darkens midtones and preserves pixels on identity curve")
    func toneCurveAdjustsLuminance() throws {
        let gray = RecorteCoreTests.makeSolidImage(width: 32, height: 32, r: 128, g: 128, b: 128, a: 255)

        let idOut = try ImageTools.applyCurves(gray, curve: ToneCurveSpec())
        let idPx = PixelGrid(idOut).pixel(x: 16, y: 16)
        #expect(abs(Int(idPx.r) - 128) <= 2)

        let brightCurve = ToneCurveSpec(
            point0: CGPoint(x: 0.0, y: 0.0),
            point1: CGPoint(x: 0.25, y: 0.42),
            point2: CGPoint(x: 0.5, y: 0.78),
            point3: CGPoint(x: 0.75, y: 0.92),
            point4: CGPoint(x: 1.0, y: 1.0)
        )
        let brightOut = try ImageTools.applyCurves(gray, curve: brightCurve)
        let brightPx = PixelGrid(brightOut).pixel(x: 16, y: 16)
        #expect(brightPx.r > 170, "Expected brighter midtone, got \(brightPx.r)")

        let darkCurve = ToneCurveSpec(
            point0: CGPoint(x: 0.0, y: 0.0),
            point1: CGPoint(x: 0.25, y: 0.10),
            point2: CGPoint(x: 0.5, y: 0.22),
            point3: CGPoint(x: 0.75, y: 0.58),
            point4: CGPoint(x: 1.0, y: 1.0)
        )
        let darkOut = try ImageTools.applyCurves(gray, curve: darkCurve)
        let darkPx = PixelGrid(darkOut).pixel(x: 16, y: 16)
        #expect(darkPx.r < 90, "Expected darker midtone, got \(darkPx.r)")
    }

    // MARK: - 6. Resize (Lanczos)

    @Test("Lanczos resize respects keepAspect option and rejects non-positive sizes")
    func lanczosResizeAspectAndExact() throws {
        let src = Self.makeFourQuadrantImage(width: 200, height: 100)

        let kept = try ImageTools.resize(src, to: CGSize(width: 100, height: 100), keepAspect: true)
        #expect(kept.width == 100 && kept.height == 50)
        // Top-left quadrant remains red, bottom-right remains yellow
        let keptGrid = PixelGrid(kept)
        #expect(keptGrid.pixel(x: 10, y: 10).r > 220 && keptGrid.pixel(x: 10, y: 10).g < 30)
        #expect(keptGrid.pixel(x: 90, y: 40).r > 220 && keptGrid.pixel(x: 90, y: 40).g > 220)

        let stretched = try ImageTools.resize(src, to: CGSize(width: 100, height: 100), keepAspect: false)
        #expect(stretched.width == 100 && stretched.height == 100)

        #expect(throws: ImageToolError.invalidDimensions) {
            _ = try ImageTools.resize(src, to: CGSize(width: 0, height: 50), keepAspect: true)
        }
    }

    // MARK: - 7. Rotate 90 Left/Right & Flip

    @Test("Rotate 90 left/right and flip horizontal/vertical transform all 4 quadrants accurately")
    func rotate90AndFlipQuadrants() throws {
        // 40x20: TL=Red, TR=Green, BL=Blue, BR=Yellow
        let src = Self.makeFourQuadrantImage(width: 40, height: 20)

        func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 220 && p.g < 30 && p.b < 30 }
        func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.g > 220 && p.r < 30 && p.b < 30 }
        func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 220 && p.r < 30 && p.g < 30 }
        func isYellow(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 220 && p.g > 220 && p.b < 30 }

        // Rotate 90 right (CW): 20x40; TL=Blue, TR=Red, BL=Yellow, BR=Green
        let rotR = try ImageTools.rotate90(src, direction: .right90)
        #expect(rotR.width == 20 && rotR.height == 40)
        let gR = PixelGrid(rotR)
        #expect(isBlue(gR.pixel(x: 5, y: 5)))
        #expect(isRed(gR.pixel(x: 15, y: 5)))
        #expect(isYellow(gR.pixel(x: 5, y: 35)))
        #expect(isGreen(gR.pixel(x: 15, y: 35)))

        // Rotate 90 left (CCW): 20x40; TL=Green, TR=Yellow, BL=Red, BR=Blue
        let rotL = try ImageTools.rotate90(src, direction: .left90)
        #expect(rotL.width == 20 && rotL.height == 40)
        let gL = PixelGrid(rotL)
        #expect(isGreen(gL.pixel(x: 5, y: 5)))
        #expect(isYellow(gL.pixel(x: 15, y: 5)))
        #expect(isRed(gL.pixel(x: 5, y: 35)))
        #expect(isBlue(gL.pixel(x: 15, y: 35)))

        // Flip horizontal: 40x20; TL=Green, TR=Red, BL=Yellow, BR=Blue
        let flipH = try ImageTools.flip(src, axis: .horizontal)
        #expect(flipH.width == 40 && flipH.height == 20)
        let gH = PixelGrid(flipH)
        #expect(isGreen(gH.pixel(x: 5, y: 5)))
        #expect(isRed(gH.pixel(x: 35, y: 5)))
        #expect(isYellow(gH.pixel(x: 5, y: 15)))
        #expect(isBlue(gH.pixel(x: 35, y: 15)))

        // Flip vertical: 40x20; TL=Blue, TR=Yellow, BL=Red, BR=Green
        let flipV = try ImageTools.flip(src, axis: .vertical)
        #expect(flipV.width == 40 && flipV.height == 20)
        let gV = PixelGrid(flipV)
        #expect(isBlue(gV.pixel(x: 5, y: 5)))
        #expect(isYellow(gV.pixel(x: 35, y: 5)))
        #expect(isRed(gV.pixel(x: 5, y: 15)))
        #expect(isGreen(gV.pixel(x: 35, y: 15)))
    }
}
