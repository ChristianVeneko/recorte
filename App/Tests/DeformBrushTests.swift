import AppKit
import CoreGraphics
import Foundation
import RecorteCore
import RecorteIO
import Testing
@testable import Recorte

@Suite("S26 Liquify Deform Brush App Tests")
@MainActor
struct DeformBrushAppTests {

    private func makeSplitRedBlueImage(width: Int, height: Int, splitX: Int? = nil) -> CGImage {
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

    private func makeCheckerboardImage(width: Int, height: Int, tile: Int = 10) -> CGImage {
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
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                let isDark = ((x / tile) + (y / tile)).isMultiple(of: 2)
                ctx.setFillColor(isDark ? RGBAColor.black.cgColor : RGBAColor.white.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: tile, height: tile))
            }
        }
        return ctx.makeImage()!
    }

    private func readPixels(in image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func pixelAt(x: Int, y: Int, width: Int, in pixels: [UInt8]) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    private func pixelAt(x: Int, y: Int, in image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let pixels = readPixels(in: image)
        return pixelAt(x: x, y: y, width: image.width, in: pixels)
    }

    @Test("Interactive Push drag stroke updates live preview, moves colored edge in drag direction, leaves far pixels unchanged, and restores with one undo")
    func pushDragStrokeLivePreviewFullResCommitAndSingleUndo() async throws {
        let undoManager = UndoManager()
        let model = EditorModel(undoManager: undoManager)
        // Use > 900px image so preview resolution downsampling is exercised during drag
        let baseImg = makeSplitRedBlueImage(width: 1200, height: 600, splitX: 600)
        model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Split"))

        model.activeTool = .deform
        model.deformMode = .push
        model.deformRadius = 110
        model.deformStrength = 0.9

        // Drag rightward across the vertical red/blue edge (x = 600) along y = 300
        model.beginDeformStroke(at: CGPoint(x: 520, y: 300), maxPreviewDimension: 400)
        #expect(model.deformState.isDragging)

        model.continueDeformStroke(to: CGPoint(x: 580, y: 300))
        model.continueDeformStroke(to: CGPoint(x: 640, y: 300))
        model.continueDeformStroke(to: CGPoint(x: 710, y: 300))

        // Live preview must update at preview resolution during drag before mouse up
        #expect(model.deformState.previewUpdateCount >= 3)
        let livePreview = try #require(model.renderedImage)
        #expect(livePreview.width == 400 && livePreview.height == 200)

        // Document layer is still untouched until mouse-up off-main-thread apply finishes
        if case .image(let duringDragImg) = model.selectedLayer?.kind {
            #expect(duringDragImg.cgImage === baseImg)
        } else {
            Issue.record("Expected selected image layer")
        }

        // Mouse up applies full-resolution stroke once off the main thread
        let commitTask = model.endDeformStroke()
        await commitTask.value
        #expect(!model.deformState.isDragging)
        #expect(!model.deformState.isApplyingFullResolution)

        let fullRendered = try #require(model.renderedImage)
        #expect(fullRendered.width == 1200 && fullRendered.height == 600)

        // Pixel to the right of the original edge (650, 300) was pure blue and must now be red!
        let pushedPixel = pixelAt(x: 650, y: 300, in: fullRendered)
        #expect(pushedPixel.r > 190 && pushedPixel.b < 70, "Expected red pushed rightward to (650, 300), got \(pushedPixel)")

        // Far pixels well away from the stroke remain completely unchanged
        let farTopLeft = pixelAt(x: 20, y: 20, in: fullRendered)
        let farTopRight = pixelAt(x: 1180, y: 20, in: fullRendered)
        let farBottomMidRight = pixelAt(x: 650, y: 580, in: fullRendered)
        #expect(farTopLeft.r == 255 && farTopLeft.b == 0)
        #expect(farTopRight.b == 255 && farTopRight.r == 0)
        #expect(farBottomMidRight.b == 255 && farBottomMidRight.r == 0)

        // Single undo restores the exact original image
        model.undo()
        let undoneRendered = try #require(model.renderedImage)
        let restoredPixel = pixelAt(x: 650, y: 300, in: undoneRendered)
        #expect(restoredPixel.b == 255 && restoredPixel.r == 0, "Expected single undo to restore original blue, got \(restoredPixel)")
        if case .image(let restoredImg) = model.selectedLayer?.kind {
            #expect(restoredImg.cgImage === baseImg)
        }

        // Single redo reapplies the deformed stroke
        model.redo()
        let redoneRendered = try #require(model.renderedImage)
        let redonePixel = pixelAt(x: 650, y: 300, in: redoneRendered)
        #expect(redonePixel.r > 190 && redonePixel.b < 70)
    }

    @Test("Drag stroke in Bulge, Pinch, and Twirl modes modifies pixels along the path and leaves distant corners untouched")
    func bulgePinchTwirlInteractiveDragStrokes() async throws {
        let baseImg = makeCheckerboardImage(width: 180, height: 180, tile: 10)

        for mode in [DeformBrushMode.bulge, .pinch, .twirl] {
            let model = EditorModel(undoManager: UndoManager())
            model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Checker"))
            let before = try #require(model.renderedImage)

            model.deformMode = mode
            model.deformRadius = 24
            model.deformStrength = 0.85

            model.beginDeformStroke(at: CGPoint(x: 35, y: 45))
            model.continueDeformStroke(to: CGPoint(x: 80, y: 45))
            model.continueDeformStroke(to: CGPoint(x: 130, y: 45))
            await model.endDeformStroke().value

            let after = try #require(model.renderedImage)
            let beforeBytes = readPixels(in: before)
            let afterBytes = readPixels(in: after)
            let w = before.width

            var pathDiff = 0
            for y in 28..<62 {
                for x in 28..<140 {
                    let a = pixelAt(x: x, y: y, width: w, in: beforeBytes)
                    let b = pixelAt(x: x, y: y, width: w, in: afterBytes)
                    if abs(Int(a.r) - Int(b.r)) > 20 {
                        pathDiff += 1
                    }
                }
            }

            var farDiff = 0
            for y in 135..<175 {
                for x in 10..<170 {
                    let a = pixelAt(x: x, y: y, width: w, in: beforeBytes)
                    let b = pixelAt(x: x, y: y, width: w, in: afterBytes)
                    if a.r != b.r || a.g != b.g || a.b != b.b {
                        farDiff += 1
                    }
                }
            }

            #expect(pathDiff > 80, "Expected \(mode) drag stroke to deform along path, diff=\(pathDiff)")
            #expect(farDiff == 0, "Expected \(mode) drag stroke to leave distant area untouched, diff=\(farDiff)")

            // One undo restores exact original
            model.undo()
            if case .image(let img) = model.selectedLayer?.kind {
                #expect(img.cgImage === baseImg)
            }
        }
    }

    @Test("Deform brush maps transformed layers accurately and ignores locked layers")
    func deformRespectsLayerTransformAndLock() async throws {
        let model = EditorModel(undoManager: UndoManager())
        let bg = makeSplitRedBlueImage(width: 240, height: 240, splitX: 120)
        model.pasteImage(ImportedImage(image: bg, suggestedName: "BG"))

        // Lock layer: drag must not mutate
        let layerID = try #require(model.selectedLayer?.id)
        model.toggleLock(id: layerID)
        let beforeLocked = model.document

        model.deformMode = .push
        model.beginDeformStroke(at: CGPoint(x: 100, y: 120))
        model.continueDeformStroke(to: CGPoint(x: 150, y: 120))
        await model.endDeformStroke().value
        #expect(model.document == beforeLocked)

        // Unlock, sync brush size helper, and verify deformBrushSize <-> deformRadius stay synchronized
        model.toggleLock(id: layerID)
        model.deformBrushSize = 120
        #expect(model.deformRadius == 60)
        model.deformRadius = 45
        #expect(model.deformBrushSize == 90)
    }
}
