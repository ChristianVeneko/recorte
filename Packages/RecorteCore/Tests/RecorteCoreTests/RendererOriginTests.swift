import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("Renderer Top-Left Coordinate System Tests")
struct RendererOriginTests {

    static func makeSplitImage(width: Int, height: Int) -> CGImage {
        // Top half red, bottom half blue in standard image coordinates (row 0 = top)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        // In an unflipped CGContext: y in [height/2, height] is the TOP half of the output image
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        // y in [0, height/2] is the BOTTOM half of the output image
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return ctx.makeImage()!
    }

    @Test("10x10 red image layer at top-left (center 5,5) draws at output rows 0-9 cols 0-9 and bottom-left is transparent")
    func topLeftOriginImagePlacement() throws {
        let red10 = RecorteCoreTests.makeSolidImage(width: 10, height: 10, r: 255, g: 0, b: 0, a: 255)
        let layer = Layer(
            name: "TopLeftRed",
            kind: .image(SendableImage(red10)),
            transform: LayerTransform(position: CGPoint(x: 5, y: 5))
        )
        let doc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 100),
            background: .transparent,
            layers: [layer]
        )

        let output = try Renderer.render(doc, scale: 1.0)
        #expect(output.width == 100 && output.height == 100)

        // Every pixel in rows 0-9, cols 0-9 should be opaque red
        for row in 0..<10 {
            for col in 0..<10 {
                let p = RecorteCoreTests.pixelRGBA(in: output, x: col, y: row)
                #expect(p.r > 240 && p.g < 15 && p.b < 15 && p.a == 255, "Expected red at (\(col), \(row)), got \(p)")
            }
        }

        // Bottom-left region (rows 90-99, cols 0-9) must be transparent
        for row in 90..<100 {
            for col in 0..<10 {
                let p = RecorteCoreTests.pixelRGBA(in: output, x: col, y: row)
                #expect(p.a == 0, "Expected transparent at bottom-left (\(col), \(row)), got \(p)")
            }
        }
    }

    @Test("Image layer is drawn upright (not vertically mirrored) in top-left context")
    func imageLayerDrawnUpright() throws {
        let split = Self.makeSplitImage(width: 20, height: 20)
        // Sanity check source image: top row red, bottom row blue
        let srcTop = RecorteCoreTests.pixelRGBA(in: split, x: 10, y: 2)
        let srcBottom = RecorteCoreTests.pixelRGBA(in: split, x: 10, y: 17)
        #expect(srcTop.r > 240 && srcTop.b < 15)
        #expect(srcBottom.b > 240 && srcBottom.r < 15)

        let layer = Layer(
            name: "Split",
            kind: .image(SendableImage(split)),
            transform: LayerTransform(position: CGPoint(x: 10, y: 10))
        )
        let doc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 100),
            background: .transparent,
            layers: [layer]
        )

        let output = try Renderer.render(doc, scale: 1.0)
        let outTop = RecorteCoreTests.pixelRGBA(in: output, x: 10, y: 2)
        let outBottom = RecorteCoreTests.pixelRGBA(in: output, x: 10, y: 17)
        #expect(outTop.r > 240 && outTop.b < 15, "Top of rendered image should stay red, got \(outTop)")
        #expect(outBottom.b > 240 && outBottom.r < 15, "Bottom of rendered image should stay blue, got \(outBottom)")
    }

    @Test("Text 'T' renders upright (not vertically mirrored)")
    func textTRendersUpright() throws {
        let textLayer = Layer(
            name: "LetterT",
            kind: .text(TextSpec(
                string: "T",
                fontName: "HelveticaNeue-Bold",
                size: 80,
                color: .white
            )),
            transform: LayerTransform(position: CGPoint(x: 60, y: 60))
        )
        let doc = EditorDocument(
            canvasSize: CGSize(width: 120, height: 120),
            background: .transparent,
            layers: [textLayer]
        )

        let output = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(output)

        // Find vertical extent of inked pixels
        var minRow = output.height
        var maxRow = -1
        var rowCounts = [Int](repeating: 0, count: output.height)
        for y in 0..<output.height {
            for x in 0..<output.width {
                let p = grid.pixel(x: x, y: y)
                if p.a > 128 {
                    rowCounts[y] += 1
                    minRow = min(minRow, y)
                    maxRow = max(maxRow, y)
                }
            }
        }

        #expect(maxRow > minRow + 10, "Letter 'T' should render with meaningful height")
        let glyphHeight = maxRow - minRow + 1
        let band = max(2, glyphHeight / 4)
        let topBandInk = rowCounts[minRow..<(minRow + band)].reduce(0, +)
        let bottomBandInk = rowCounts[(maxRow - band + 1)...maxRow].reduce(0, +)

        // Upright 'T' has its wide horizontal crossbar in the top band and only the narrow stem in the bottom band
        #expect(topBandInk > bottomBandInk * 2, "Expected top crossbar ink (\(topBandInk)) > 2x bottom stem ink (\(bottomBandInk)) for upright 'T'")
    }
}
