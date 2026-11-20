import AppKit
import CoreGraphics
import Darwin
import Foundation
import RecorteCore
import RecorteIO
import Testing
@testable import Recorte

@Suite("S23 Manual Brush Eraser App Tests", .serialized)
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

    @Test("S27: 200 synthetic eraser drag points on a 2000x2000 image complete under 0.5 s with zero per-drag document rerenders")
    func eraser200DragPointsOn2000x2000UnderHalfSecond() async throws {
        let model = EditorModel()
        let largeImg = makeSolidImage(width: 2000, height: 2000, r: 40, g: 130, b: 220, a: 255)
        model.pasteImage(ImportedImage(image: largeImg, suggestedName: "LargePhoto"))

        model.activeTool = .eraser
        model.eraserMode = .erase
        model.eraserBrushSize = 44
        model.eraserHardness = 0.6

        let points: [CGPoint] = (0..<200).map { i in
            let t = CGFloat(i) / 199.0
            let x = 200.0 + t * 1600.0
            let y = 1000.0 + sin(t * .pi * 4.0) * 260.0
            return CGPoint(x: x, y: y)
        }

        let rendersBeforeDrag = model.renderCount
        let start = CFAbsoluteTimeGetCurrent()

        model.beginEraserStroke(at: points[0])
        #expect(model.liveEraserPreview != nil)
        for pt in points.dropFirst() {
            model.continueEraserStroke(to: pt)
        }
        let dragElapsed = CFAbsoluteTimeGetCurrent() - start

        // Never re-render the whole document per drag event on the main thread
        #expect(model.renderCount == rendersBeforeDrag, "Expected 0 full-doc rerenders during drag, got \(model.renderCount - rendersBeforeDrag)")

        // Off-main-thread full-res apply on stroke end
        await model.endEraserStrokeAsync()
        let totalElapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(model.liveEraserPreview == nil, "Expected live preview / split cache to be dropped after stroke end")
        #expect(model.renderCount == rendersBeforeDrag + 1)
        print(String(format: "S27_APP_ERASER_TIMING: drag=%.4fs total=%.4fs", dragElapsed, totalElapsed))
        #expect(totalElapsed < 0.5, "Expected 200 eraser drag points + full-res apply on 2000x2000 in < 0.5 s (drag=\(dragElapsed)s, total=\(totalElapsed)s)")

        let rendered = try #require(model.renderComposite())
        #expect(rendered.width == 2000 && rendered.height == 2000)
        // Start and end points of the sine wave are erased at full resolution; far corner untouched
        #expect(pixelAt(x: 200, y: 1000, in: rendered).a == 0)
        #expect(pixelAt(x: 1800, y: 1000, in: rendered).a == 0)
        #expect(pixelAt(x: 50, y: 50, in: rendered).a == 255)

        // Single-step stroke-record undo restores original untouched mask
        model.undo()
        if case .image(let restoredImg) = model.selectedLayer?.kind {
            #expect(restoredImg.alphaMask == nil)
        } else {
            Issue.record("Expected image layer after undo")
        }
        model.redo()
        if case .image(let redoneImg) = model.selectedLayer?.kind {
            #expect(redoneImg.alphaMask != nil)
        }
    }

    @Test("S28: Preview downsampling, 160 px filter/tray thumbnails, capped undo, and split cache cleanup")
    func memoryOptimizationsPreviewThumbnailsUndoCapAndSplitDrop() throws {
        let model = EditorModel()
        let largeImg = makeSolidImage(width: 1400, height: 1400, r: 200, g: 80, b: 40, a: 255)
        model.pasteImage(ImportedImage(image: largeImg, suggestedName: "Big1400"))

        // Capped undo history
        #expect(model.undoManager.levelsOfUndo > 0 && model.undoManager.levelsOfUndo <= EditorModel.maxUndoLevels)

        // Filter thumbnails computed once from a 160 px downsample
        let thumbs1 = ImageThumbnailCache.filterThumbnails(for: largeImg, maxDimension: 160)
        let thumbs2 = ImageThumbnailCache.filterThumbnails(for: largeImg, maxDimension: 160)
        #expect(thumbs1.count == FilterPreset.allCases.count)
        for (_, thumb) in thumbs1 {
            #expect(max(thumb.width, thumb.height) <= 160)
        }
        #expect(thumbs1[.noir] === thumbs2[.noir])

        // Tray thumbnail is bounded to <= 160 px
        let tray = try #require(model.trayThumbnail)
        #expect(max(tray.width, tray.height) <= 160)

        // On-screen preview downsamples to view pixel size while renderComposite stays full-res 1400x1400
        model.updatePreviewTargetPixelSize(CGSize(width: 700, height: 700))
        let preview = try #require(model.renderedImage)
        #expect(preview.width <= 710 && preview.height <= 710)
        let fullExport = try #require(model.renderComposite())
        #expect(fullExport.width == 1400 && fullExport.height == 1400)

        // Live transform split is created during drag and dropped immediately on end or tool switch
        let layerID = try #require(model.selectedLayer?.id)
        model.beginLiveTransform(for: layerID)
        #expect(model.liveTransformPreview != nil)
        #expect((model.liveTransformPreview?.split.activeLayerImage.width ?? 9999) <= 710)
        model.endLiveTransform(actionName: "Move")
        #expect(model.liveTransformPreview == nil)

        model.beginLiveTransform(for: layerID)
        #expect(model.liveTransformPreview != nil)
        model.activeTool = .eraser
        #expect(model.liveTransformPreview == nil)
    }

    @Test("S28: Heavy editing session on a 1400x1400 image keeps phys_footprint delta bounded (< 120 MB)")
    func heavyEditing1400x1400MemoryDeltaIsBounded() throws {
        func currentFootprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
            let _ = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
                }
            }
            return Double(info.phys_footprint) / (1024.0 * 1024.0)
        }

        ImageFilters.clearCaches()
        let beforeMB = currentFootprintMB()

        let model = EditorModel()
        model.updatePreviewTargetPixelSize(CGSize(width: 900, height: 900))
        let img1400 = makeSolidImage(width: 1400, height: 1400, r: 90, g: 140, b: 210, a: 255)
        model.pasteImage(ImportedImage(image: img1400, suggestedName: "Photo1400"))
        let layerID = try #require(model.selectedLayer?.id)

        // 1. Compute inspector filter thumbnails (160px) and cycle all filter presets
        _ = ImageThumbnailCache.filterThumbnails(for: img1400, maxDimension: 160)
        for preset in FilterPreset.allCases {
            autoreleasepool {
                model.setFilterPreset(preset, for: layerID)
            }
        }
        model.setFilterPreset(.vivid, for: layerID)

        // 2. Simulate 20 continuous adjustment drags
        for step in 0..<20 {
            autoreleasepool {
                let v = Double(step) * 0.02
                model.setAdjustments(Adjustments(brightness: v * 0.5, contrast: 1.0 + v, saturation: 1.0 + v), for: layerID, continuous: true)
            }
        }
        model.endContinuousEdit(actionName: "Adjust Image")

        // 3. Perform 12 interactive eraser/restore strokes (40 drag points each) without yielding MainActor
        model.activeTool = .eraser
        model.eraserBrushSize = 48
        model.eraserHardness = 0.5
        for s in 0..<12 {
            autoreleasepool {
                model.eraserMode = s.isMultiple(of: 3) ? .restore : .erase
                let y = CGFloat(150 + s * 90)
                model.beginEraserStroke(at: CGPoint(x: 150, y: y))
                for i in 1..<40 {
                    let x = 150.0 + CGFloat(i) * 28.0
                    model.continueEraserStroke(to: CGPoint(x: x, y: y + sin(CGFloat(i) * 0.3) * 18.0))
                }
                model.endEraserStroke()
            }
        }

        // 4. Perform 8 live transform drags (split cache created & dropped)
        model.activeTool = .move
        for step in 0..<8 {
            autoreleasepool {
                model.beginLiveTransform(for: layerID, isRotating: true)
                var t = model.document.layer(id: layerID)!.transform
                t.rotationDegrees = Double(step * 5)
                model.updateLiveTransform(t, isRotating: true)
                model.endLiveTransform(actionName: "Rotate")
            }
        }

        // 5. Perform 15 destructive bitmap edits (clone stamps) to exercise undo cap & LZFSE compaction
        for step in 0..<15 {
            try autoreleasepool {
                let dst = CGPoint(x: 200 + step * 50, y: 200 + step * 40)
                try model.applyCloneStamp(from: CGPoint(x: 700, y: 700), to: dst, radius: 40)
            }
        }
        for _ in 0..<5 { model.undo() }
        for _ in 0..<5 { model.redo() }

        #expect(model.liveTransformPreview == nil)
        #expect(model.liveEraserPreview == nil)

        // Drain any pending CoreImage Metal scratch buffers before sampling steady-state delta.
        ImageFilters.clearCaches()
        let footprintMB = currentFootprintMB()
        let deltaMB = footprintMB - beforeMB
        print(String(format: "S28_HEAVY_1400_PHYS_FOOTPRINT: before=%.1f MB after=%.1f MB delta=%.1f MB", beforeMB, footprintMB, deltaMB))
        #expect(deltaMB < 120.0, "Expected heavy 1400x1400 editing delta < 120 MB, got \(deltaMB) MB (before=\(beforeMB), after=\(footprintMB))")
    }
}
