import AppKit
import CoreGraphics
import Foundation
import RecorteCore
import RecorteIO
import Testing
@testable import Recorte

@Suite("S23 Manual Brush Eraser App Tests")
@MainActor
struct EraserAppTests {

    private func makeSolidImage(
        width: Int,
        height: Int,
        r: UInt8 = 255,
        g: UInt8 = 0,
        b: UInt8 = 0,
        a: UInt8 = 255
    ) -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = r
            data[i + 1] = g
            data[i + 2] = b
            data[i + 3] = a
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        return ctx.makeImage()!
    }

    private func pixelAt(x: Int, y: Int, in image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = y * bytesPerRow + x * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    @Test("Eraser tool is registered in EditorTool with shortcut E")
    func eraserToolMetadataAndShortcut() {
        #expect(EditorTool.allCases.contains(.eraser))
        #expect(EditorTool.eraser.label == "Eraser")
        #expect(EditorTool.eraser.shortcutDisplay == "E")
        #expect(EditorTool.eraser.systemImage == "eraser")
    }

    @Test("Erase stroke makes pixels transparent along the stroke while preserving original CGImage")
    func eraseStrokeMakesPixelsTransparentAlongStroke() throws {
        let model = EditorModel()
        let baseImg = makeSolidImage(width: 120, height: 100, r: 230, g: 50, b: 40, a: 255)
        model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Photo"))

        model.activeTool = .eraser
        model.eraserMode = .erase
        model.eraserBrushSize = 20
        model.eraserHardness = 1.0

        model.beginEraserStroke(at: CGPoint(x: 25, y: 50))
        model.continueEraserStroke(to: CGPoint(x: 60, y: 50))
        model.continueEraserStroke(to: CGPoint(x: 95, y: 50))
        model.endEraserStroke()

        let rendered = try #require(model.renderedImage)
        #expect(pixelAt(x: 25, y: 50, in: rendered).a == 0)
        #expect(pixelAt(x: 60, y: 50, in: rendered).a == 0)
        #expect(pixelAt(x: 95, y: 50, in: rendered).a == 0)
        #expect(pixelAt(x: 60, y: 15, in: rendered).a == 255)
        #expect(pixelAt(x: 60, y: 85, in: rendered).a == 255)

        if case .image(let img) = model.selectedLayer?.kind {
            #expect(img.cgImage === baseImg)
            #expect(img.alphaMask != nil)
        } else {
            Issue.record("Expected selected image layer")
        }
    }

    @Test("Hardness 0 produces a soft feathered edge on the rendered canvas")
    func hardnessZeroProducesSoftEdgeOnCanvas() throws {
        let model = EditorModel()
        let baseImg = makeSolidImage(width: 120, height: 120, r: 40, g: 120, b: 230, a: 255)
        model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Sky"))

        model.eraserMode = .erase
        model.eraserBrushSize = 40
        model.eraserHardness = 0.0

        try model.applyEraserStroke(
            canvasPoints: [CGPoint(x: 30, y: 60), CGPoint(x: 90, y: 60)]
        )

        let rendered = try #require(model.renderedImage)
        #expect(pixelAt(x: 60, y: 60, in: rendered).a == 0)
        let midAlpha = pixelAt(x: 60, y: 70, in: rendered).a
        #expect(midAlpha > 40 && midAlpha < 215, "Expected soft feathered edge, got alpha=\(midAlpha)")
        #expect(pixelAt(x: 60, y: 86, in: rendered).a == 255)
    }

    @Test("Restore mode brings erased pixels back with original RGB colors")
    func restoreModeBringsOriginalPixelsBack() throws {
        let model = EditorModel()
        let baseImg = makeSolidImage(width: 100, height: 100, r: 30, g: 210, b: 80, a: 255)
        model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Leaf"))

        model.eraserMode = .erase
        model.eraserBrushSize = 30
        model.eraserHardness = 1.0
        try model.applyEraserStroke(canvasPoints: [CGPoint(x: 20, y: 50), CGPoint(x: 80, y: 50)])

        let afterErase = try #require(model.renderedImage)
        #expect(pixelAt(x: 50, y: 50, in: afterErase).a == 0)

        model.eraserMode = .restore
        model.eraserBrushSize = 18
        model.eraserHardness = 1.0
        try model.applyEraserStroke(canvasPoints: [CGPoint(x: 50, y: 50)])

        let afterRestore = try #require(model.renderedImage)
        let restoredPx = pixelAt(x: 50, y: 50, in: afterRestore)
        #expect(restoredPx.g > 190 && restoredPx.r < 40 && restoredPx.a == 255)
        // Still erased outside restore brush
        #expect(pixelAt(x: 25, y: 50, in: afterRestore).a == 0)
    }

    @Test("Each interactive multi-point stroke is a single undo step and undo restores erased pixels")
    func eachStrokeIsOneUndoStepAndUndoRestores() throws {
        let undoManager = UndoManager()
        let model = EditorModel(undoManager: undoManager)
        let baseImg = makeSolidImage(width: 100, height: 100, r: 220, g: 40, b: 40, a: 255)
        model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Card"))

        // Stroke 1: multi-point erase drag
        model.eraserMode = .erase
        model.eraserBrushSize = 20
        model.eraserHardness = 1.0
        model.beginEraserStroke(at: CGPoint(x: 20, y: 30))
        for x in stride(from: CGFloat(26), through: CGFloat(80), by: 6) {
            model.continueEraserStroke(to: CGPoint(x: x, y: 30))
        }
        model.endEraserStroke()

        let erasedRender = try #require(model.renderedImage)
        #expect(pixelAt(x: 50, y: 30, in: erasedRender).a == 0)

        // Stroke 2: multi-point restore drag
        model.eraserMode = .restore
        model.eraserBrushSize = 20
        model.beginEraserStroke(at: CGPoint(x: 42, y: 30))
        model.continueEraserStroke(to: CGPoint(x: 50, y: 30))
        model.continueEraserStroke(to: CGPoint(x: 58, y: 30))
        model.endEraserStroke()

        let restoredRender = try #require(model.renderedImage)
        #expect(pixelAt(x: 50, y: 30, in: restoredRender).a == 255)

        // Single undo reverts entire restore stroke -> back to erased
        model.undo()
        let undo1Render = try #require(model.renderedImage)
        #expect(pixelAt(x: 50, y: 30, in: undo1Render).a == 0)

        // Second undo reverts entire multi-point erase stroke -> back to original opaque
        model.undo()
        let undo2Render = try #require(model.renderedImage)
        #expect(pixelAt(x: 50, y: 30, in: undo2Render).a == 255)
        if case .image(let img) = model.selectedLayer?.kind {
            #expect(img.alphaMask == nil)
        }

        // Redo reapplies erase stroke
        model.redo()
        let redoRender = try #require(model.renderedImage)
        #expect(pixelAt(x: 50, y: 30, in: redoRender).a == 0)
    }

    @Test("Eraser maps transformed image layer coordinates accurately and ignores locked layers")
    func eraserRespectsTransformAndLock() throws {
        let model = EditorModel()
        let bg = makeSolidImage(width: 200, height: 200, r: 0, g: 0, b: 0, a: 0)
        model.pasteImage(ImportedImage(image: bg, suggestedName: "Canvas"))
        let layerImg = makeSolidImage(width: 60, height: 60, r: 255, g: 0, b: 0, a: 255)
        model.importDroppedImage(ImportedImage(image: layerImg, suggestedName: "StickerImg"), at: CGPoint(x: 120, y: 110))
        let topID = try #require(model.selectedLayer?.id)
        model.setLayerTransform(
            id: topID,
            transform: LayerTransform(position: CGPoint(x: 120, y: 110), scale: 2.0, rotationDegrees: 0)
        )

        // Erase at layer's visual center in canvas coordinates (120, 110) with 24pt canvas brush
        model.eraserMode = .erase
        model.eraserBrushSize = 24
        model.eraserHardness = 1.0
        try model.applyEraserStroke(canvasPoints: [CGPoint(x: 120, y: 110)])

        let rendered = try #require(model.renderedImage)
        #expect(pixelAt(x: 120, y: 110, in: rendered).a == 0)
        // 35pt away is still inside the 120x120 scaled layer (half-width 60) and outside 12pt brush radius
        #expect(pixelAt(x: 85, y: 110, in: rendered).a == 255)

        // Lock both layers and ensure eraser does not mutate
        for layer in model.document.layers {
            model.toggleLock(id: layer.id)
        }
        let snapshotBeforeLocked = model.document
        model.beginEraserStroke(at: CGPoint(x: 85, y: 110))
        model.endEraserStroke()
        #expect(model.document == snapshotBeforeLocked)
    }
}
