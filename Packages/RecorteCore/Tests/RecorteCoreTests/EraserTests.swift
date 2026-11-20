import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("S23 Manual Brush Eraser Core Tests")
struct EraserCoreTests {

    @Test("Erase stroke makes pixels transparent along the stroke while leaving outside opaque")
    func eraseMakesPixelsTransparentAlongStroke() throws {
        let src = ImageToolsTests.makeFourQuadrantImage(width: 100, height: 100)
        // Top-left quadrant is Red, top-right is Green, bottom-left is Blue, bottom-right is Yellow.
        let stroke = EraserStroke(
            points: [CGPoint(x: 20, y: 25), CGPoint(x: 80, y: 25)],
            brushSize: 16,
            hardness: 1.0,
            mode: .erase
        )
        let erased = try ImageEraser.applyStroke(src, stroke: stroke)
        #expect(erased.width == 100 && erased.height == 100)

        let grid = PixelGrid(erased)
        // Along the horizontal stroke at y = 25 (top half): pixels become transparent
        for x in [20, 35, 50, 65, 80] {
            let p = grid.pixel(x: x, y: 25)
            #expect(p.a == 0, "Expected transparent along stroke at (\(x), 25), got \(p)")
        }

        // Unstroked regions keep original colors and full opacity
        let topCorner = grid.pixel(x: 5, y: 5)
        #expect(topCorner.r > 230 && topCorner.g < 20 && topCorner.a == 255)

        let bottomLeft = grid.pixel(x: 25, y: 75)
        #expect(bottomLeft.b > 230 && bottomLeft.r < 20 && bottomLeft.a == 255)

        let bottomRight = grid.pixel(x: 75, y: 75)
        #expect(bottomRight.r > 230 && bottomRight.g > 230 && bottomRight.b < 20 && bottomRight.a == 255)

        // Single-point tap erases a circular spot
        let tap = try ImageEraser.erase(
            src,
            points: [CGPoint(x: 25, y: 75)],
            brushSize: 14,
            hardness: 1.0
        )
        let tapGrid = PixelGrid(tap)
        #expect(tapGrid.pixel(x: 25, y: 75).a == 0)
        #expect(tapGrid.pixel(x: 25, y: 55).a == 255)
    }

    @Test("Hardness 0 produces a smooth soft feathered edge compared to hardness 1")
    func hardnessZeroGivesSoftEdge() throws {
        let src = RecorteCoreTests.makeSolidImage(width: 120, height: 120, r: 220, g: 60, b: 40, a: 255)
        let strokePoints = [CGPoint(x: 30, y: 60), CGPoint(x: 90, y: 60)]

        // Brush diameter 40 -> radius 20
        let soft = try ImageEraser.erase(src, points: strokePoints, brushSize: 40, hardness: 0.0)
        let hard = try ImageEraser.erase(src, points: strokePoints, brushSize: 40, hardness: 1.0)

        let softGrid = PixelGrid(soft)
        let hardGrid = PixelGrid(hard)

        // Centerline (d = 0): fully erased for both
        #expect(softGrid.pixel(x: 60, y: 60).a == 0)
        #expect(hardGrid.pixel(x: 60, y: 60).a == 0)

        // Mid-radius (d = 10 = 0.5 * R): soft has intermediate partial alpha; hard is still fully erased
        let softMid = softGrid.pixel(x: 60, y: 70)
        let hardMid = hardGrid.pixel(x: 60, y: 70)
        #expect(softMid.a > 40 && softMid.a < 215, "Expected soft mid-radius alpha in (40, 215), got \(softMid.a)")
        #expect(hardMid.a == 0, "Expected hard mid-radius alpha to be 0, got \(hardMid.a)")

        // Outer-mid (d = 15 = 0.75 * R): strictly more opaque than d = 10, still feathered (< 255)
        let softOuter = softGrid.pixel(x: 60, y: 75)
        #expect(softOuter.a > softMid.a && softOuter.a < 255, "Expected monotonic soft falloff, mid=\(softMid.a), outer=\(softOuter.a)")

        // Outside brush radius (d = 24 > 20): untouched opaque
        #expect(softGrid.pixel(x: 60, y: 84).a == 255)
        #expect(hardGrid.pixel(x: 60, y: 84).a == 255)
    }

    @Test("Restore mode brings original pixels back from source image")
    func restoreBringsOriginalPixelsBack() throws {
        let original = ImageToolsTests.makeFourQuadrantImage(width: 100, height: 100)

        // Erase a wide horizontal band covering parts of all 4 quadrants
        let erased = try ImageEraser.erase(
            original,
            points: [CGPoint(x: 20, y: 50), CGPoint(x: 80, y: 50)],
            brushSize: 44,
            hardness: 1.0
        )
        let erasedGrid = PixelGrid(erased)
        #expect(erasedGrid.pixel(x: 40, y: 40).a == 0)
        #expect(erasedGrid.pixel(x: 65, y: 60).a == 0)

        // Restore only over the top-left red region (40, 40)
        let restored = try ImageEraser.restore(
            erased,
            from: original,
            points: [CGPoint(x: 40, y: 40)],
            brushSize: 18,
            hardness: 1.0
        )
        let restoredGrid = PixelGrid(restored)

        // (40, 40) should be back to opaque red
        let recovered = restoredGrid.pixel(x: 40, y: 40)
        #expect(recovered.r > 230 && recovered.g < 20 && recovered.b < 20 && recovered.a == 255,
                "Expected restored opaque red at (40, 40), got \(recovered)")

        // (65, 60) was not restored so it stays transparent
        #expect(restoredGrid.pixel(x: 65, y: 60).a == 0)
    }

    @Test("SendableImage alphaMask keeps original pixels intact for restore, rendering, and undo")
    func sendableImageAlphaMaskPreservesOriginalAndUndoes() throws {
        let originalCG = ImageToolsTests.makeFourQuadrantImage(width: 100, height: 100)
        let initialImage = SendableImage(originalCG)
        let layerID = UUID()
        let initialDoc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 100),
            background: .transparent,
            layers: [
                Layer(
                    id: layerID,
                    name: "Photo",
                    kind: .image(initialImage),
                    transform: LayerTransform(position: CGPoint(x: 50, y: 50))
                )
            ],
            selection: layerID
        )

        var history = UndoStack<EditorDocument>(initial: initialDoc)

        // Erase across top-left red quadrant
        let eraseStroke = EraserStroke(
            points: [CGPoint(x: 15, y: 25), CGPoint(x: 40, y: 25)],
            brushSize: 20,
            hardness: 1.0,
            mode: .erase
        )
        let erasedImage = try initialImage.applyingEraserStroke(eraseStroke)
        #expect(erasedImage.cgImage === originalCG)
        #expect(erasedImage.alphaMask != nil)
        #expect(erasedImage != initialImage)

        var docAfterErase = initialDoc
        docAfterErase.layers[0].kind = .image(erasedImage)
        history.push(docAfterErase)

        let renderedErased = PixelGrid(try Renderer.render(history.current, scale: 1.0))
        #expect(renderedErased.pixel(x: 25, y: 25).a == 0)
        #expect(renderedErased.pixel(x: 75, y: 75).a == 255)

        // Restore over (25, 25) using the stored original pixels + alphaMask
        let restoreStroke = EraserStroke(
            points: [CGPoint(x: 25, y: 25)],
            brushSize: 16,
            hardness: 1.0,
            mode: .restore
        )
        let restoredImage = try erasedImage.applyingEraserStroke(restoreStroke)
        #expect(restoredImage.cgImage === originalCG)

        var docAfterRestore = docAfterErase
        docAfterRestore.layers[0].kind = .image(restoredImage)
        history.push(docAfterRestore)

        let renderedRestored = PixelGrid(try Renderer.render(history.current, scale: 1.0))
        let pxRestored = renderedRestored.pixel(x: 25, y: 25)
        #expect(pxRestored.r > 230 && pxRestored.g < 20 && pxRestored.a == 255)

        // Undo restore -> back to erased
        _ = history.undo()
        let renderedUndo1 = PixelGrid(try Renderer.render(history.current, scale: 1.0))
        #expect(renderedUndo1.pixel(x: 25, y: 25).a == 0)

        // Undo erase -> back to original untouched image
        _ = history.undo()
        let renderedUndo2 = PixelGrid(try Renderer.render(history.current, scale: 1.0))
        let pxOriginal = renderedUndo2.pixel(x: 25, y: 25)
        #expect(pxOriginal.r > 230 && pxOriginal.g < 20 && pxOriginal.a == 255)
    }

    @Test("Restore does not make originally transparent pixels opaque")
    func restoreRespectsOriginalTransparency() throws {
        // Left half opaque red, right half already transparent
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 60,
            height: 60,
            bitsPerComponent: 8,
            bytesPerRow: 240,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: 60, height: 60))
        ctx.setFillColor(RGBAColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 60))
        let halfTransparent = ctx.makeImage()!

        let img = SendableImage(halfTransparent)
        let erased = try img.applyingEraserStroke(
            EraserStroke(points: [CGPoint(x: 15, y: 30), CGPoint(x: 45, y: 30)], brushSize: 20, hardness: 1.0, mode: .erase)
        )
        let restored = try erased.applyingEraserStroke(
            EraserStroke(points: [CGPoint(x: 15, y: 30), CGPoint(x: 45, y: 30)], brushSize: 24, hardness: 1.0, mode: .restore)
        )
        let composited = PixelGrid(try restored.maskedCGImage())

        // Left half restored to opaque red; right half remains transparent
        #expect(composited.pixel(x: 15, y: 30).a == 255 && composited.pixel(x: 15, y: 30).r > 230)
        #expect(composited.pixel(x: 45, y: 30).a == 0)
    }

    @Test("Incremental EraserStrokeSession keeps soft edge consistent and RecorteProject round-trips alphaMask")
    func sessionSoftEdgeAndProjectPersistence() throws {
        let src = RecorteCoreTests.makeSolidImage(width: 100, height: 100, r: 40, g: 140, b: 240, a: 255)
        var session = try EraserStrokeSession(
            baseMask: nil,
            width: 100,
            height: 100,
            brushSize: 36,
            hardness: 0.0,
            mode: .erase
        )
        // Simulate rapid incremental drag updates every 3px horizontally
        var lastMask: CGImage?
        for x in stride(from: CGFloat(20), through: CGFloat(80), by: 3) {
            lastMask = try session.appendPoint(CGPoint(x: x, y: 50))
        }
        lastMask = try session.finish()
        let mask = try #require(lastMask)
        let composited = PixelGrid(try ImageEraser.applyAlphaMask(mask, to: src))

        // Centerline erased, mid-radius (d = 9 = 0.5*R) remains genuinely soft (not hardened by overlapping segments)
        #expect(composited.pixel(x: 50, y: 50).a == 0)
        let midAlpha = composited.pixel(x: 50, y: 59).a
        #expect(midAlpha > 40 && midAlpha < 215, "Incremental soft stroke hardened unexpectedly: midAlpha=\(midAlpha)")
        #expect(composited.pixel(x: 50, y: 74).a == 255)

        // Project save/load round-trips alphaMask losslessly
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorte-eraser-proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pkgURL = tempDir.appendingPathComponent("Erased.recorte", isDirectory: true)
        let doc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 100),
            background: .transparent,
            layers: [
                Layer(
                    name: "Masked",
                    kind: .image(SendableImage(src, alphaMask: mask)),
                    transform: LayerTransform(position: CGPoint(x: 50, y: 50))
                )
            ]
        )
        try RecorteProject.save(doc, to: pkgURL)
        let reloaded = try RecorteProject.load(from: pkgURL)
        if case .image(let loadedImg) = reloaded.layers.first?.kind {
            #expect(loadedImg.alphaMask != nil)
            let renderedReloaded = PixelGrid(try Renderer.render(reloaded, scale: 1.0))
            #expect(renderedReloaded.pixel(x: 50, y: 50).a == 0)
            #expect(renderedReloaded.pixel(x: 50, y: 74).a == 255)

            // Restore still works after reload because original pixels were preserved!
            let restoredAfterReload = try loadedImg.applyingEraserStroke(
                EraserStroke(points: [CGPoint(x: 50, y: 50)], brushSize: 16, hardness: 1.0, mode: .restore)
            )
            let restoredGrid = PixelGrid(try restoredAfterReload.maskedCGImage())
            #expect(restoredGrid.pixel(x: 50, y: 50).a == 255 && restoredGrid.pixel(x: 50, y: 50).b > 220)
        } else {
            Issue.record("Expected image layer after project reload")
        }
    }

    @Test("S27: 200 synthetic eraser drag points on a 2000x2000 persistent mask complete well under 0.5 s")
    func persistentMask200DragPointsUnderHalfSecond() throws {
        let width = 2000
        let height = 2000
        let persistent = try PersistentAlphaMask(baseMask: nil, width: width, height: height)

        let points: [CGPoint] = (0..<200).map { i in
            let t = CGFloat(i) / 199.0
            let x = 200.0 + t * 1600.0
            let y = 1000.0 + sin(t * .pi * 4.0) * 240.0
            return CGPoint(x: x, y: y)
        }

        let start = CFAbsoluteTimeGetCurrent()
        persistent.beginStroke(brushSize: 40, hardness: 0.5, mode: .erase)
        var dirtyUpdates = 0
        for pt in points {
            if let dirty = persistent.appendPoint(pt) {
                dirtyUpdates += 1
                #expect(dirty.width < width && dirty.height < height)
            }
        }
        _ = persistent.finishStroke()
        let finalMask = try persistent.makeMaskImage()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(dirtyUpdates >= 150)
        #expect(finalMask.width == width && finalMask.height == height)
        #expect(elapsed < 0.5, "Expected 200 drag points on 2000x2000 mask in <0.5s, took \(elapsed)s")

        // Also verify full-res bounding-box replay via ImageEraser.applyStrokeToMask completes fast
        let replayStart = CFAbsoluteTimeGetCurrent()
        let replayedMask = try ImageEraser.applyStrokeToMask(
            nil,
            width: width,
            height: height,
            stroke: EraserStroke(points: points, brushSize: 40, hardness: 0.5, mode: .erase)
        )
        let replayElapsed = CFAbsoluteTimeGetCurrent() - replayStart
        #expect(replayedMask.width == width && replayedMask.height == height)
        #expect(replayElapsed < 0.5, "Expected applyStrokeToMask replay on 2000x2000 in <0.5s, took \(replayElapsed)s")
    }
}
