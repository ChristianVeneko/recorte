import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("S13 RecorteProject & PDF Export Tests")
struct ProjectAndPDFTests {

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorte-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("RecorteProject saves .recorte package with document.json and PNG asset per image layer and round-trips losslessly")
    func projectSaveLoadRoundTrip() throws {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let packageURL = tempDir.appendingPathComponent("TestEdit.recorte", isDirectory: true)

        let splitImg = RendererOriginTests.makeSplitImage(width: 24, height: 24)
        let greenImg = RecorteCoreTests.makeSolidImage(width: 16, height: 16, r: 20, g: 200, b: 80, a: 255)

        let imgLayer1 = Layer(
            name: "Background Photo",
            kind: .image(SendableImage(
                splitImg,
                filterPreset: .vivid,
                adjustments: Adjustments(brightness: 0.1, contrast: 1.15, saturation: 1.2, exposure: 0.25, warmth: -0.1, sharpness: 0.5, vignette: 0.3),
                frame: .polaroid(caption: "Vacation", borderColor: .white)
            )),
            transform: LayerTransform(position: CGPoint(x: 100, y: 80), scale: CGSize(width: 1.5, height: 1.25), rotationDegrees: 15),
            opacity: 0.85,
            isHidden: false,
            isLocked: true
        )
        let imgLayer2 = Layer(
            name: "Overlay",
            kind: .image(SendableImage(greenImg, frame: .roundedCorners(radius: 6))),
            transform: LayerTransform(position: CGPoint(x: 40, y: 40)),
            opacity: 0.7,
            isHidden: true,
            isLocked: false
        )
        let textLayer = Layer(
            name: "Headline",
            kind: .text(TextSpec(
                string: "Hello\nWorld",
                fontName: "HelveticaNeue-Bold",
                size: 36,
                color: .black,
                alignment: .left,
                stroke: TextStrokeSpec(color: .white, width: 2),
                background: nil,
                gradient: TextGradientSpec(colors: [.red, .blue], angleDegrees: 45),
                bubble: .speech,
                bubbleColor: .yellow,
                bubbleStrokeColor: .black,
                bubbleStrokeWidth: 2.5
            )),
            transform: LayerTransform(position: CGPoint(x: 150, y: 120))
        )
        let shapeLayer = Layer(
            name: "StarBadge",
            kind: .shape(ShapeSpec(kind: .star, size: CGSize(width: 60, height: 60), strokeColor: .black, fillColor: .yellow, lineWidth: 3)),
            transform: LayerTransform(position: CGPoint(x: 200, y: 60))
        )
        let stickerLayer = Layer(
            name: "HeartSticker",
            kind: .sticker(.sfSymbol("heart.fill", pointSize: 48, tintColor: .red)),
            transform: LayerTransform(position: CGPoint(x: 220, y: 150))
        )
        let drawingLayer = Layer(
            name: "Ink",
            kind: .drawing(DrawingSpec(strokes: [
                DrawingStroke(points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)], color: .red, width: 4, tool: .brush),
                DrawingStroke(points: [CGPoint(x: 20, y: 60), CGPoint(x: 80, y: 60)], color: .yellow, width: 14, tool: .highlighter)
            ]))
        )

        let original = EditorDocument(
            canvasSize: CGSize(width: 320, height: 240),
            background: .solid(RGBAColor(r: 0.2, g: 0.3, b: 0.4, a: 1.0)),
            layers: [imgLayer1, imgLayer2, textLayer, shapeLayer, stickerLayer, drawingLayer],
            selection: textLayer.id
        )

        try RecorteProject.save(original, to: packageURL)

        // Verify package directory layout: document.json + 2 PNG assets
        let manifestURL = packageURL.appendingPathComponent("document.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        let assetFiles = try FileManager.default.contentsOfDirectory(atPath: assetsDir.path)
            .filter { $0.hasSuffix(".png") }
        #expect(assetFiles.count == 2)

        // Verify manifest is valid Codable JSON
        let jsonData = try Data(contentsOf: manifestURL)
        let decodedManifest = try JSONDecoder().decode(RecorteProjectManifest.self, from: jsonData)
        #expect(decodedManifest.version == RecorteProject.currentFormatVersion)
        #expect(decodedManifest.layers.count == 6)

        // Load back and verify full fidelity
        let loaded = try RecorteProject.load(from: packageURL)
        #expect(loaded.canvasSize == original.canvasSize)
        #expect(loaded.background == original.background)
        #expect(loaded.selection == original.selection)
        #expect(loaded.layers.count == original.layers.count)

        for (lhs, rhs) in zip(original.layers, loaded.layers) {
            #expect(lhs.id == rhs.id)
            #expect(lhs.name == rhs.name)
            #expect(lhs.transform == rhs.transform)
            #expect(abs(lhs.opacity - rhs.opacity) < 1e-6)
            #expect(lhs.isHidden == rhs.isHidden)
            #expect(lhs.isLocked == rhs.isLocked)

            switch (lhs.kind, rhs.kind) {
            case (.image(let a), .image(let b)):
                #expect(a.width == b.width && a.height == b.height)
                #expect(a.filterPreset == b.filterPreset)
                #expect(a.adjustments == b.adjustments)
                #expect(a.frame == b.frame)
                // Pixel-level lossless verification
                let gA = PixelGrid(a.cgImage)
                let gB = PixelGrid(b.cgImage)
                #expect(gA.bytes == gB.bytes)
            default:
                #expect(lhs.kind == rhs.kind)
            }
        }

        // Re-save after removing one image layer cleans up stale PNG asset
        var trimmed = original
        trimmed.remove(id: imgLayer2.id)
        try RecorteProject.save(trimmed, to: packageURL)
        let updatedAssets = try FileManager.default.contentsOfDirectory(atPath: assetsDir.path)
            .filter { $0.hasSuffix(".png") }
        #expect(updatedAssets.count == 1)
    }

    @Test("RecorteProject reports clear errors for missing manifest or missing asset")
    func projectErrorHandling() throws {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyPkg = tempDir.appendingPathComponent("Empty.recorte", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPkg, withIntermediateDirectories: true)
        #expect(throws: RecorteProjectError.missingManifest) {
            _ = try RecorteProject.load(from: emptyPkg)
        }

        // Save valid project then delete its image asset
        let brokenPkg = tempDir.appendingPathComponent("Broken.recorte", isDirectory: true)
        let img = RecorteCoreTests.makeSolidImage(width: 8, height: 8, r: 255, g: 0, b: 0)
        let doc = EditorDocument(
            canvasSize: CGSize(width: 20, height: 20),
            layers: [Layer(name: "Img", kind: .image(SendableImage(img)))]
        )
        try RecorteProject.save(doc, to: brokenPkg)
        let assetsDir = brokenPkg.appendingPathComponent("assets", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        #expect(throws: RecorteProjectError.self) {
            _ = try RecorteProject.load(from: brokenPkg)
        }
    }

    @Test("PDF export produces valid single-page PDF matching canvas dimensions and upright pixels")
    func pdfExportValidAndUpright() throws {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pdfURL = tempDir.appendingPathComponent("Export.pdf")

        let red20 = RecorteCoreTests.makeSolidImage(width: 20, height: 20, r: 255, g: 0, b: 0, a: 255)
        let doc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 80),
            background: .solid(.white),
            layers: [
                // Placed at top-left (center 10, 10 -> covers rows 0..19, cols 0..19)
                Layer(name: "TopLeftRed", kind: .image(SendableImage(red20)), transform: LayerTransform(position: CGPoint(x: 10, y: 10)))
            ]
        )

        try RecorteProject.exportPDF(doc, to: pdfURL, scale: 1.0)
        let pdfData = try Data(contentsOf: pdfURL)

        // Starts with "%PDF-"
        let header = String(decoding: pdfData.prefix(5), as: UTF8.self)
        #expect(header == "%PDF-")

        // Parse via CGPDFDocument and inspect page count + mediaBox
        let provider = try #require(CGDataProvider(data: pdfData as CFData))
        let pdfDoc = try #require(CGPDFDocument(provider))
        #expect(pdfDoc.numberOfPages == 1)
        let page = try #require(pdfDoc.page(at: 1))
        let mediaBox = page.getBoxRect(.mediaBox)
        #expect(mediaBox.width == 100 && mediaBox.height == 80)

        // Rasterize page 1 into a bitmap and confirm top-left is red & bottom-left is white
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: 100,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.drawPDFPage(page)
        let raster = try #require(ctx.makeImage())
        let grid = PixelGrid(raster)

        let topLeft = grid.pixel(x: 10, y: 10)
        let bottomLeft = grid.pixel(x: 10, y: 70)
        #expect(topLeft.r > 230 && topLeft.g < 20 && topLeft.b < 20)
        #expect(bottomLeft.r > 230 && bottomLeft.g > 230 && bottomLeft.b > 230)
    }
}
