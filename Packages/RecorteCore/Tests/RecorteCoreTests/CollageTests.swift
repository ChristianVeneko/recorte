import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("S18 CollageLayout & CollageBuilder Tests")
struct CollageTests {

    @Test("CollageLayout covers 2 to 6 cells (grid and mosaic) with valid non-overlapping spaced rects")
    func layoutPresetsGeometry() {
        let structuredLayouts = CollageLayout.allCases.filter { $0 != .freeStyle }
        let coveredCounts = Set(structuredLayouts.map(\.cellCount))
        #expect(coveredCounts == Set([2, 3, 4, 5, 6]))

        let canvas = CGSize(width: 600, height: 600)
        let spacing: CGFloat = 12.0

        for layout in structuredLayouts {
            let rects = layout.cellRects(in: canvas, spacing: spacing)
            #expect(rects.count == layout.cellCount)
            #expect(layout.normalizedCells.count == layout.cellCount)

            let innerBounds = CGRect(origin: .zero, size: canvas).insetBy(dx: spacing - 0.5, dy: spacing - 0.5)
            for (i, r) in rects.enumerated() {
                #expect(r.width > 10 && r.height > 10, "Cell \(i) in \(layout) must have positive area")
                #expect(innerBounds.contains(r), "Cell \(i) in \(layout) must respect outer spacing: \(r)")
                for j in (i + 1)..<rects.count {
                    #expect(!r.intersects(rects[j]), "Cells \(i) and \(j) in \(layout) overlap")
                }
            }
        }
    }

    @Test("CollageBuilder fits images with aspect-fill, spacing, and corner radius")
    func collageBuilderAspectFillSpacingAndCorners() throws {
        // Wide landscape image: left/right 25% green, middle 50% red (200x50)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 200, height: 50,
            bitsPerComponent: 8, bytesPerRow: 800,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(RGBAColor.green.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        ctx.setFillColor(RGBAColor.red.cgColor)
        ctx.fill(CGRect(x: 50, y: 0, width: 100, height: 50))
        let wideImg = ctx.makeImage()!

        let blueImg = RecorteCoreTests.makeSolidImage(width: 80, height: 160, r: 0, g: 0, b: 255, a: 255)

        let doc = try CollageBuilder.makeDocument(
            layout: .twoHorizontal,
            images: [wideImg, blueImg],
            canvasSize: CGSize(width: 200, height: 120),
            background: .solid(.black),
            spacing: 10,
            cornerRadius: 14
        )

        #expect(doc.canvasSize == CGSize(width: 200, height: 120))
        #expect(doc.layers.count == 2)

        let rendered = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(rendered)

        // Outer margin & center gap are black background
        let leftMargin = grid.pixel(x: 4, y: 60)
        let centerGap = grid.pixel(x: 100, y: 60)
        let rightMargin = grid.pixel(x: 196, y: 60)
        #expect(leftMargin.r < 15 && leftMargin.g < 15 && leftMargin.b < 15)
        #expect(centerGap.r < 15 && centerGap.g < 15 && centerGap.b < 15)
        #expect(rightMargin.r < 15 && rightMargin.g < 15 && rightMargin.b < 15)

        // Left cell [10..95, 10..110] aspect-fills 200x50 (4:1) into 85x100 (0.85:1),
        // so the center 50% red band fills the entire left cell (green edges cropped off)!
        let leftCellCenter = grid.pixel(x: 52, y: 60)
        let leftCellTop = grid.pixel(x: 52, y: 15)
        let leftCellBottom = grid.pixel(x: 52, y: 105)
        #expect(leftCellCenter.r > 230 && leftCellCenter.g < 20)
        #expect(leftCellTop.r > 230 && leftCellTop.g < 20)
        #expect(leftCellBottom.r > 230 && leftCellBottom.g < 20)

        // Rounded corner of left cell at (11, 11) shows black background due to cornerRadius 14
        let leftCellCorner = grid.pixel(x: 11, y: 11)
        #expect(leftCellCorner.r < 20 && leftCellCorner.g < 20 && leftCellCorner.b < 20)

        // Right cell [105..190, 10..110] is filled blue
        let rightCellCenter = grid.pixel(x: 147, y: 60)
        #expect(rightCellCenter.b > 230 && rightCellCenter.r < 20)
    }

    @Test("Six-cell mosaic collage produces 6 distinct layers that render cleanly")
    func sixCellMosaicCollage() throws {
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (255, 255, 0), (255, 0, 255), (0, 255, 255)
        ]
        let images = colors.map { RecorteCoreTests.makeSolidImage(width: 60, height: 60, r: $0.0, g: $0.1, b: $0.2) }
        let doc = try CollageLayout.sixMosaic.makeDocument(
            images: images,
            canvasSize: CGSize(width: 300, height: 300),
            background: .solid(.white),
            spacing: 6,
            cornerRadius: 4
        )
        #expect(doc.layers.count == 6)
        let rendered = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(rendered)
        // First large cell occupies top-left 2/3 -> (80, 80) is red
        let big = grid.pixel(x: 80, y: 80)
        #expect(big.r > 230 && big.g < 20 && big.b < 20)
    }

    @Test("Free style collage produces a plain canvas without grid cropping")
    func freeStylePlainCanvas() throws {
        #expect(CollageLayout.freeStyle.cellCount == 0)
        #expect(CollageLayout.freeStyle.normalizedCells.isEmpty)

        let emptyDoc = try CollageBuilder.makeDocument(
            layout: .freeStyle,
            images: [],
            canvasSize: CGSize(width: 500, height: 400),
            background: .transparent
        )
        #expect(emptyDoc.canvasSize == CGSize(width: 500, height: 400))
        #expect(emptyDoc.background == .transparent)
        #expect(emptyDoc.layers.isEmpty)

        let img = RecorteCoreTests.makeSolidImage(width: 90, height: 50, r: 255, g: 120, b: 0)
        let withImg = try CollageBuilder.makeDocument(
            layout: .freeStyle,
            images: [img],
            canvasSize: CGSize(width: 500, height: 400),
            background: .solid(.white)
        )
        #expect(withImg.layers.count == 1)
        if case .image(let sendable) = withImg.layers[0].kind {
            // Uncropped original dimensions preserved in free style
            #expect(sendable.width == 90 && sendable.height == 50)
        } else {
            Issue.record("Expected image layer in freeStyle document")
        }
    }
}
