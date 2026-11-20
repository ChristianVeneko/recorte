import CoreGraphics
import Foundation
import Testing
@testable import RecorteCore

@Suite("S26 Liquify Deform Brush Core Tests")
struct DeformBrushTests {

    /// Creates an image split vertically at `splitX`: left side red, right side blue.
    private static func makeSplitRedBlueImage(width: Int, height: Int, splitX: Int? = nil) -> CGImage {
        let split = splitX ?? (width / 2)
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
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(RGBAColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: split, height: height))
        ctx.setFillColor(RGBAColor.blue.cgColor)
        ctx.fill(CGRect(x: split, y: 0, width: width - split, height: height))
        return ctx.makeImage()!
    }

    /// Creates an image split horizontally at `splitY`: top half green, bottom half blue.
    private static func makeHorizontalSplitImage(width: Int, height: Int) -> CGImage {
        let split = height / 2
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
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(RGBAColor.green.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: split))
        ctx.setFillColor(RGBAColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: split, width: width, height: height - split))
        return ctx.makeImage()!
    }

    @Test("Push brush moves a colored edge in the drag direction and leaves far pixels untouched")
    func pushMovesColoredEdgeInDragDirection() throws {
        // 160x160 image: left half (x < 80) red, right half (x >= 80) blue
        let src = Self.makeSplitRedBlueImage(width: 160, height: 160, splitX: 80)
        let srcGrid = PixelGrid(src)

        // Drag rightward across the vertical red/blue boundary along y = 80
        let stroke = DeformStroke(
            mode: .push,
            points: [
                CGPoint(x: 60, y: 80),
                CGPoint(x: 80, y: 80),
                CGPoint(x: 105, y: 80)
            ],
            radius: 26,
            strength: 0.9
        )
        let out = try ImageTools.deformBrush(src, stroke: stroke)
        #expect(out.width == 160 && out.height == 160)
        let outGrid = PixelGrid(out)

        // Pixel at (92, 80) was originally pure blue (x = 92 > 80); after pushing red rightward it must now be red!
        let beforeRight = srcGrid.pixel(x: 92, y: 80)
        let afterRight = outGrid.pixel(x: 92, y: 80)
        #expect(beforeRight.b > 230 && beforeRight.r < 20)
        #expect(afterRight.r > 200 && afterRight.b < 60, "Expected red pushed rightward to (92, 80), got \(afterRight)")

        // Far pixels above and below the stroke path must be bit-exact unchanged
        for y in [10, 20, 140, 150] {
            for x in [10, 75, 85, 150] {
                let a = srcGrid.pixel(x: x, y: y)
                let b = outGrid.pixel(x: x, y: y)
                #expect(a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a,
                        "Expected far pixel (\(x), \(y)) unchanged, before=\(a) after=\(b)")
            }
        }

        // Also test vertical downward drag (top-left origin y down!) across a horizontal green/blue edge
        let hSrc = Self.makeHorizontalSplitImage(width: 140, height: 140)
        let downStroke = DeformStroke(
            mode: .push,
            points: [CGPoint(x: 70, y: 50), CGPoint(x: 70, y: 95)],
            radius: 24,
            strength: 0.9
        )
        let hOut = try DeformBrush.applyStroke(hSrc, stroke: downStroke)
        let hGrid = PixelGrid(hOut)
        // (70, 82) was blue (below y=70); dragging downward must push green down into (70, 82)
        let pushedDown = hGrid.pixel(x: 70, y: 82)
        #expect(pushedDown.g > 200 && pushedDown.b < 60, "Expected green pushed downward to (70, 82), got \(pushedDown)")
        // Far corner (10, 130) remains pure blue
        let farCorner = hGrid.pixel(x: 10, y: 130)
        #expect(farCorner.b > 230 && farCorner.g < 20)
    }

    @Test("Drag strokes for Bulge, Pinch, and Twirl deform along the entire path and leave distant regions untouched")
    func bulgePinchTwirlDragAlongPath() throws {
        let src = ImageToolsTests.makeCheckerboard(width: 160, height: 160, tile: 8)
        let srcGrid = PixelGrid(src)
        var outputs: [DeformBrushMode: [UInt8]] = [:]

        for mode in [DeformBrushMode.bulge, .pinch, .twirl] {
            let stroke = DeformStroke(
                mode: mode,
                points: [
                    CGPoint(x: 32, y: 40),
                    CGPoint(x: 70, y: 40),
                    CGPoint(x: 112, y: 40)
                ],
                radius: 22,
                strength: 0.85
            )
            let out = try DeformBrush.applyStroke(src, stroke: stroke)
            #expect(out.width == 160 && out.height == 160)
            let outGrid = PixelGrid(out)
            outputs[mode] = outGrid.bytes

            // Verify deformation happens at start, middle, and end of the dragged path (not just click point!)
            func diffCount(xRange: Range<Int>, yRange: Range<Int>) -> Int {
                var count = 0
                for y in yRange {
                    for x in xRange {
                        let a = srcGrid.pixel(x: x, y: y)
                        let b = outGrid.pixel(x: x, y: y)
                        if abs(Int(a.r) - Int(b.r)) > 20 {
                            count += 1
                        }
                    }
                }
                return count
            }

            let startDiff = diffCount(xRange: 20..<48, yRange: 24..<56)
            let midDiff = diffCount(xRange: 56..<84, yRange: 24..<56)
            let endDiff = diffCount(xRange: 96..<126, yRange: 24..<56)
            let farDiff = diffCount(xRange: 10..<150, yRange: 110..<155)

            #expect(startDiff > 20, "Expected \(mode) deformation near start, diff=\(startDiff)")
            #expect(midDiff > 20, "Expected \(mode) deformation along middle of drag, diff=\(midDiff)")
            #expect(endDiff > 20, "Expected \(mode) deformation near end of drag, diff=\(endDiff)")
            #expect(farDiff == 0, "Expected \(mode) to leave distant region bit-exact, diff=\(farDiff)")
        }

        // Bulge, Pinch, and Twirl must produce distinct results
        #expect(outputs[.bulge] != outputs[.pinch])
        #expect(outputs[.bulge] != outputs[.twirl])
        #expect(outputs[.pinch] != outputs[.twirl])
    }

    @Test("Interactive DeformBrushSession updates live at preview resolution and records full-res stroke")
    func interactiveSessionUpdatesPreviewAndRecordsFullResStroke() throws {
        // Large image (> 900px) so preview downsampling activates
        let src = Self.makeSplitRedBlueImage(width: 1200, height: 600, splitX: 600)
        var session = try DeformBrushSession(
            sourceImage: src,
            mode: .push,
            radius: 120,
            strength: 0.9,
            maxPreviewDimension: 400
        )

        #expect(session.previewSize.width == 400)
        #expect(session.previewSize.height == 200)
        #expect(abs(session.previewScale - (400.0 / 1200.0)) < 0.01)

        // Touch down in Push mode records point without moving pixels yet
        let firstPreview = session.begin(at: CGPoint(x: 520, y: 300))
        #expect(firstPreview == nil)
        #expect(!session.hasEffectiveMutation)

        // Dragging rightward across x=600 produces live preview updates
        let midPreview = session.append(point: CGPoint(x: 620, y: 300))
        let endPreview = session.append(point: CGPoint(x: 720, y: 300))
        #expect(midPreview != nil)
        let previewCG = try #require(endPreview)
        #expect(previewCG.width == 400 && previewCG.height == 200)
        #expect(session.hasEffectiveMutation)

        // Preview pixel just right of center (x=215, y=100 in 400x200 preview space) should now be red
        let previewGrid = PixelGrid(previewCG)
        let previewRight = previewGrid.pixel(x: 215, y: 100)
        #expect(previewRight.r > 180 && previewRight.b < 80, "Expected live preview push, got \(previewRight)")

        // Recorded full-resolution stroke replays accurately on full 1200x600 image
        let stroke = session.stroke
        #expect(stroke.points.count == 3)
        let fullOut = try DeformBrush.applyStroke(src, stroke: stroke)
        #expect(fullOut.width == 1200 && fullOut.height == 600)
        let fullGrid = PixelGrid(fullOut)
        let fullRight = fullGrid.pixel(x: 645, y: 300)
        #expect(fullRight.r > 180 && fullRight.b < 80, "Expected full-res push at (645, 300), got \(fullRight)")
        // Far corner (10, 10) unchanged red, (1190, 590) unchanged blue
        #expect(fullGrid.pixel(x: 10, y: 10).r == 255)
        #expect(fullGrid.pixel(x: 1190, y: 590).b == 255)
    }

    @Test("Invalid dimensions and non-positive radius throw ImageToolError")
    func invalidParametersThrow() throws {
        let src = Self.makeSplitRedBlueImage(width: 64, height: 64)
        #expect(throws: ImageToolError.invalidParameters) {
            _ = try DeformBrush.applyStroke(
                src,
                stroke: DeformStroke(mode: .push, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)], radius: 0, strength: 0.5)
            )
        }
        // Zero strength is a clean no-op
        let noOp = try DeformBrush.applyStroke(
            src,
            stroke: DeformStroke(mode: .push, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)], radius: 12, strength: 0.0)
        )
        #expect(noOp === src)
    }
}
