import AppKit
import CoreGraphics
import Foundation
import RecorteCore
import RecorteIO
import SwiftUI
import Testing
@testable import Recorte

@Suite("T9 Polish Specs (S20, S21, S22, S24, S25)")
@MainActor
struct PolishSpecsTests {

    // MARK: - Pixel Helpers

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

    private func readPixels(of image: CGImage) -> (pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
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
        return (pixels, width, height, bytesPerRow)
    }

    private func rgbaAt(x: Int, y: Int, in image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let buf = readPixels(of: image)
        let offset = y * buf.bytesPerRow + x * 4
        return (buf.pixels[offset], buf.pixels[offset + 1], buf.pixels[offset + 2], buf.pixels[offset + 3])
    }

    private func opaqueBounds(in image: CGImage) -> CGRect? {
        let buf = readPixels(of: image)
        var minX = buf.width
        var minY = buf.height
        var maxX = -1
        var maxY = -1
        for y in 0..<buf.height {
            for x in 0..<buf.width {
                let a = buf.pixels[y * buf.bytesPerRow + x * 4 + 3]
                if a > 10 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - S20: Stickers & Shapes Human Names & SF Symbol Rendering

    @Test("S20: SF Symbol sticker has human layer name and renders as tinted upright icon, never raw identifier text")
    func sfSymbolStickerHumanNameAndIconRender() throws {
        let model = EditorModel(document: EditorDocument(canvasSize: CGSize(width: 320, height: 200)))
        model.addStickerLayer(.sfSymbol("star.fill", pointSize: 64, tintColor: .yellow))

        let layer = try #require(model.selectedLayer)
        #expect(!layer.name.contains("."))
        #expect(layer.name == "Star sticker")

        let rendered = try #require(model.renderedImage)
        let bounds = try #require(opaqueBounds(in: rendered))
        let aspect = bounds.width / max(1, bounds.height)
        #expect(aspect > 0.7 && aspect < 1.45, "Expected star icon (aspect ~1.0), got \(bounds)")

        // Center pixel of star.fill should be tinted yellow (high R, high G, low B, opaque)
        let centerPx = rgbaAt(x: Int(bounds.midX), y: Int(bounds.midY), in: rendered)
        #expect(centerPx.a > 200)
        #expect(centerPx.r > 200)
        #expect(centerPx.g > 200)
        #expect(centerPx.b < 40)
    }

    @Test("S20: Asymmetric SF Symbol renders upright (triangle wider at bottom than top)")
    func asymmetricSFSymbolRendersUpright() throws {
        let model = EditorModel(document: EditorDocument(canvasSize: CGSize(width: 200, height: 200)))
        model.addStickerLayer(.sfSymbol("exclamationmark.triangle.fill", pointSize: 80, tintColor: .red))

        let rendered = try #require(model.renderedImage)
        let bounds = try #require(opaqueBounds(in: rendered))
        let buf = readPixels(of: rendered)

        // Row near top (20% down the triangle) vs row near bottom (80% down the triangle)
        let topY = Int(bounds.minY + bounds.height * 0.2)
        let bottomY = Int(bounds.minY + bounds.height * 0.8)

        var topOpaque = 0
        var bottomOpaque = 0
        for x in Int(bounds.minX)...Int(bounds.maxX) {
            if buf.pixels[topY * buf.bytesPerRow + x * 4 + 3] > 20 { topOpaque += 1 }
            if buf.pixels[bottomY * buf.bytesPerRow + x * 4 + 3] > 20 { bottomOpaque += 1 }
        }
        #expect(bottomOpaque > topOpaque, "Expected triangle bottom (\(bottomOpaque)px) wider than top (\(topOpaque)px)")
    }

    @Test("S20: All catalog SF Symbols and shapes produce human-readable names without code/identifier tokens")
    func allStickersAndShapesHaveHumanNames() {
        for symbol in StickerCatalog.sfSymbols {
            let human = StickerDisplayName.humanName(for: symbol)
            #expect(!human.isEmpty)
            #expect(!human.contains("."))
            #expect(!human.contains("_"))
            let layerName = StickerDisplayName.layerName(for: .sfSymbol(symbol))
            #expect(!layerName.contains("."))
            #expect(layerName.hasSuffix(" sticker"))
        }

        // Fallback sanitizer for arbitrary unknown SF Symbol
        #expect(StickerDisplayName.humanName(for: "cloud.sun.rain.fill") == "Cloud Sun Rain")

        // All shapes produce clean human names
        let model = EditorModel(document: EditorDocument(canvasSize: CGSize(width: 200, height: 200)))
        let expectedShapes: [(ShapeKind, String)] = [
            (.rect, "Rectangle"),
            (.roundedRect(cornerRadius: 12), "Rounded Rectangle"),
            (.ellipse, "Ellipse"),
            (.line, "Line"),
            (.arrow, "Arrow"),
            (.triangle, "Triangle"),
            (.star, "Star")
        ]
        for (kind, expectedName) in expectedShapes {
            model.addShapeLayer(ShapeSpec(kind: kind))
            #expect(model.selectedLayer?.name == expectedName)
        }
    }

    // MARK: - S21: Sticker Solid Background & Canvas Solid Background

    @Test("S21: Sticker solid background renders, exports PNG/PDF, persists in .recorte, duplicates, and undoes")
    func stickerSolidBackgroundRendersExportsAndPersists() throws {
        let model = EditorModel(document: EditorDocument(canvasSize: CGSize(width: 240, height: 240)))
        model.addStickerLayer(.sfSymbol("star.fill", pointSize: 80, tintColor: .white))
        let stickerID = try #require(model.selectedLayer?.id)

        // Initially no sticker background: pixel near badge corner (offset from center) is transparent
        let initialRendered = try #require(model.renderedImage)
        let badgeCornerX = 120 - 44
        let badgeCornerY = 120 - 44
        #expect(rgbaAt(x: badgeCornerX, y: badgeCornerY, in: initialRendered).a == 0)

        // Apply solid blue background to the sticker
        model.setStickerBackground(.blue, for: stickerID)
        #expect(model.stickerBackground(for: stickerID) == .blue)

        let withBgRendered = try #require(model.renderedImage)
        let cornerPx = rgbaAt(x: badgeCornerX, y: badgeCornerY, in: withBgRendered)
        #expect(cornerPx.a > 240, "Expected opaque solid blue sticker badge at (\(badgeCornerX), \(badgeCornerY))")
        #expect(cornerPx.b > 220)
        #expect(cornerPx.r < 30)

        // Export PNG and verify exported pixels have the blue badge
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorteS21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pngURL = tempDir.appendingPathComponent("sticker-bg.png")
        try model.exportImage(format: .png, to: pngURL)
        let reimported = try ImageImporter.importFromURL(pngURL)
        let exportedCornerPx = rgbaAt(x: badgeCornerX, y: badgeCornerY, in: reimported.image)
        #expect(exportedCornerPx.a > 240)
        #expect(exportedCornerPx.b > 220)

        // Export PDF succeeds with prepared SF symbol + solid background
        let pdfURL = tempDir.appendingPathComponent("sticker-bg.pdf")
        try model.exportPDF(to: pdfURL)
        let pdfData = try Data(contentsOf: pdfURL)
        #expect(pdfData.starts(with: Data("%PDF".utf8)))

        // Save and reload .recorte preserves sticker background
        let projectURL = tempDir.appendingPathComponent("StickerBg.recorte")
        try model.saveProject(to: projectURL)
        let reloaded = EditorModel()
        try reloaded.loadProject(from: projectURL)
        #expect(reloaded.stickerBackground(for: stickerID) == .blue)

        // Duplicate preserves sticker background
        model.duplicateLayer(id: stickerID)
        let dupID = try #require(model.selectedLayer?.id)
        #expect(dupID != stickerID)
        #expect(model.stickerBackground(for: dupID) == .blue)

        // Undo duplicate, then undo sticker background restores transparent corner
        model.undo()
        model.undo()
        #expect(model.stickerBackground(for: stickerID) == nil)
        let undoneRendered = try #require(model.renderedImage)
        #expect(rgbaAt(x: badgeCornerX, y: badgeCornerY, in: undoneRendered).a == 0)
    }

    @Test("S21: Emoji sticker solid background also renders and exports")
    func emojiStickerSolidBackgroundWorks() throws {
        let model = EditorModel(document: EditorDocument(canvasSize: CGSize(width: 240, height: 240)))
        model.defaultStickerBackground = .red
        model.addStickerLayer(.emoji("🔥", pointSize: 80))

        let rendered = try #require(model.renderedImage)
        let cornerPx = rgbaAt(x: 120 - 44, y: 120 - 44, in: rendered)
        #expect(cornerPx.a > 240)
        #expect(cornerPx.r > 220)
        #expect(cornerPx.b < 30)
    }

    @Test("S21: Canvas Solid Background toggle + color renders, exports, and roundtrips ColorBridge")
    func canvasSolidBackgroundAndColorBridgeWork() throws {
        // ColorBridge preserves SwiftUI colors cleanly
        let convertedRed = RGBAColor(swiftUIColor: Color(.sRGB, red: 0.85, green: 0.15, blue: 0.25, opacity: 1.0))
        #expect(abs(convertedRed.r - 0.85) < 0.02)
        #expect(abs(convertedRed.g - 0.15) < 0.02)
        #expect(abs(convertedRed.b - 0.25) < 0.02)

        let model = EditorModel(document: EditorDocument(canvasSize: CGSize(width: 160, height: 120)))
        model.setCanvasBackground(.solid(RGBAColor(r: 0.1, g: 0.8, b: 0.2, a: 1.0)))
        #expect(model.hasCanvasSurface)

        let rendered = try #require(model.renderedImage)
        let px = rgbaAt(x: 5, y: 5, in: rendered)
        #expect(px.a == 255)
        #expect(px.g > 190)
        #expect(px.r < 40)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorteS21Canvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pngURL = tempDir.appendingPathComponent("canvas-bg.png")
        try model.exportImage(format: .png, to: pngURL)
        let exported = try ImageImporter.importFromURL(pngURL)
        let expPx = rgbaAt(x: 5, y: 5, in: exported.image)
        #expect(expPx.a == 255)
        #expect(expPx.g > 190)

        model.undo()
        #expect(model.document.background == .transparent)
    }

    // MARK: - S22: Image Layer Opacity (Live + Single Undo Step per Drag)

    @Test("S22: Image layer opacity applies live and collapses a continuous drag into one undo step")
    func imageLayerOpacityLiveAndSingleUndoStep() throws {
        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 100, height: 100, r: 255, g: 0, b: 0, a: 255), suggestedName: "Photo"))
        let layerID = try #require(model.selectedLayer?.id)

        let fullAlpha = rgbaAt(x: 50, y: 50, in: try #require(model.renderedImage)).a
        #expect(fullAlpha == 255)

        // Simulate continuous slider drag: 1.0 -> 0.8 -> 0.5 -> 0.25
        model.setOpacity(id: layerID, opacity: 0.8, continuous: true)
        model.setOpacity(id: layerID, opacity: 0.5, continuous: true)
        let halfAlpha = rgbaAt(x: 50, y: 50, in: try #require(model.renderedImage)).a
        #expect(halfAlpha >= 120 && halfAlpha <= 136, "Expected ~50% alpha live, got \(halfAlpha)")

        model.setOpacity(id: layerID, opacity: 0.25, continuous: true)
        model.endContinuousEdit(actionName: "Change Opacity")
        #expect(model.document.layer(id: layerID)?.opacity == 0.25)

        // Single undo must jump all the way back to 1.0
        model.undo()
        #expect(model.document.layer(id: layerID)?.opacity == 1.0)
        #expect(rgbaAt(x: 50, y: 50, in: try #require(model.renderedImage)).a == 255)

        // Single redo returns to 0.25
        model.redo()
        #expect(model.document.layer(id: layerID)?.opacity == 0.25)
    }

    // MARK: - S24: Trackpad Zoom, Pan, Smart Zoom, Shortcuts & 60fps Live Transform

    @Test("S24: Pinch zoom anchors pointer, clamps 10%-800%, pan/smart-zoom/Cmd shortcuts work")
    func viewportTrackpadZoomPanAndShortcuts() {
        var viewport = CanvasViewport()
        let docSize = CGSize(width: 1600, height: 1000)
        let stageAvail = CGSize(width: 800, height: 500)
        let baseCenter = CGPoint(x: 440, y: 280)

        let fit = CanvasViewport.computeFitScale(documentSize: docSize, availableSize: stageAvail)
        #expect(abs(fit - 0.5) < 0.001)
        viewport.updateFitScale(fit)
        #expect(viewport.effectiveScale == 0.5)
        #expect(viewport.zoomPercentage == 50)

        // Pinch zoom around off-center pointer keeps the canvas point under the pointer stationary
        let pointer = CGPoint(x: 620, y: 190)
        let frameBefore = viewport.canvasFrame(documentSize: docSize, baseCenter: baseCenter)
        let canvasPtBefore = CGPoint(
            x: (pointer.x - frameBefore.minX) / viewport.effectiveScale,
            y: (pointer.y - frameBefore.minY) / viewport.effectiveScale
        )

        viewport.zoom(to: 2.0, around: pointer, baseCenter: baseCenter)
        #expect(viewport.effectiveScale == 2.0)
        let frameAfter = viewport.canvasFrame(documentSize: docSize, baseCenter: baseCenter)
        let canvasPtAfter = CGPoint(
            x: (pointer.x - frameAfter.minX) / viewport.effectiveScale,
            y: (pointer.y - frameAfter.minY) / viewport.effectiveScale
        )
        #expect(abs(canvasPtBefore.x - canvasPtAfter.x) < 0.01)
        #expect(abs(canvasPtBefore.y - canvasPtAfter.y) < 0.01)

        // Zoom clamping 10% - 800%
        viewport.zoom(to: 50.0, around: pointer, baseCenter: baseCenter)
        #expect(viewport.effectiveScale == 8.0)
        viewport.zoom(to: 0.01, around: pointer, baseCenter: baseCenter)
        #expect(viewport.effectiveScale == 0.10)

        // Two-finger pan updates panOffset without resetting zoom
        let panBefore = viewport.panOffset
        viewport.pan(by: CGSize(width: 45, height: -30))
        #expect(abs(viewport.panOffset.width - (panBefore.width + 45)) < 0.001)
        #expect(abs(viewport.panOffset.height - (panBefore.height - 30)) < 0.001)

        // Cmd+0 Fit, Cmd+1 100%, Smart Zoom toggles Fit <-> 100%
        viewport.zoomToFit()
        #expect(viewport.isFitMode)
        #expect(viewport.effectiveScale == 0.5)
        #expect(viewport.panOffset == .zero)

        viewport.toggleSmartZoom(baseCenter: baseCenter)
        #expect(!viewport.isFitMode)
        #expect(viewport.effectiveScale == 1.0)

        viewport.toggleSmartZoom(baseCenter: baseCenter)
        #expect(viewport.isFitMode)
        #expect(viewport.effectiveScale == 0.5)

        viewport.zoomToActualSize()
        #expect(viewport.effectiveScale == 1.0)
        viewport.zoomIn()
        #expect(viewport.effectiveScale > 1.0)
        viewport.zoomOut()
        #expect(abs(viewport.effectiveScale - 1.0) < 0.001)
    }

    @Test("S24: 60fps live trackpad rotation avoids per-frame rerenders and commits one undo step on end")
    func trackpadRotationAvoidsPerFrameRerender() throws {
        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 200, height: 150, r: 40, g: 120, b: 220), suggestedName: "Photo"))
        let layerID = try #require(model.selectedLayer?.id)

        let rendersBefore = model.renderCount

        // Multi-frame rotation gesture (began + 5 changed frames)
        model.handleTrackpadRotate(deltaDegrees: 5.0, phase: .began)
        for _ in 0..<5 {
            model.handleTrackpadRotate(deltaDegrees: 5.0, phase: .changed)
        }

        // Zero full document rerenders during active gesture frames
        #expect(model.renderCount == rendersBefore)
        #expect(model.liveTransformPreview?.isRotating == true)
        #expect(abs((model.liveTransformPreview?.currentTransform.rotationDegrees ?? 0) - 30.0) < 0.001)

        // Gesture end commits once with exactly 1 rerender
        model.handleTrackpadRotate(deltaDegrees: 0.0, phase: .ended)
        #expect(model.liveTransformPreview == nil)
        #expect(model.renderCount == rendersBefore + 1)
        #expect(abs((model.document.layer(id: layerID)?.transform.rotationDegrees ?? 0) - 30.0) < 0.001)

        // Single undo restores 0°
        model.undo()
        #expect(abs((model.document.layer(id: layerID)?.transform.rotationDegrees ?? 99) - 0.0) < 0.001)
    }

    // MARK: - S25: Rotation Shift Snapping & Context Cursors

    @Test("S25: Rotation Shift snapping snaps cleanly to 15-degree increments and formats glass badge text")
    func rotationShiftSnappingAndFormatting() {
        #expect(RotationMath.snapDegrees(7.0, isShiftPressed: true) == 0.0)
        #expect(RotationMath.snapDegrees(8.0, isShiftPressed: true) == 15.0)
        #expect(RotationMath.snapDegrees(22.4, isShiftPressed: true) == 15.0)
        #expect(RotationMath.snapDegrees(22.6, isShiftPressed: true) == 30.0)
        #expect(RotationMath.snapDegrees(-22.0, isShiftPressed: true) == -15.0)
        #expect(RotationMath.snapDegrees(-23.0, isShiftPressed: true) == -30.0)
        #expect(RotationMath.snapDegrees(176.0, isShiftPressed: true) == 180.0)
        #expect(RotationMath.snapDegrees(-176.0, isShiftPressed: true) == 180.0)

        // Without Shift, angle passes through normalized
        #expect(abs(RotationMath.snapDegrees(190.0, isShiftPressed: false) - (-170.0)) < 0.001)

        // Glass badge formatting
        #expect(RotationMath.formattedAngle(0.0) == "0°")
        #expect(RotationMath.formattedAngle(-0.0) == "0°")
        #expect(RotationMath.formattedAngle(45.2) == "45°")
        #expect(RotationMath.formattedAngle(-15.0) == "-15°")
        #expect(RotationMath.formattedAngle(-180.0) == "180°")
    }

    @Test("S25: Selection & crop handle resize cursor orientations adapt accurately to layer rotation")
    func resizeCursorOrientationsAdaptToRotation() {
        // Unrotated corners
        #expect(CanvasCursorLogic.resizePosition(xSign: -1, ySign: -1, layerRotationDegrees: 0) == .topLeading)
        #expect(CanvasCursorLogic.resizePosition(xSign: 1, ySign: -1, layerRotationDegrees: 0) == .topTrailing)
        #expect(CanvasCursorLogic.resizePosition(xSign: -1, ySign: 1, layerRotationDegrees: 0) == .bottomLeading)
        #expect(CanvasCursorLogic.resizePosition(xSign: 1, ySign: 1, layerRotationDegrees: 0) == .bottomTrailing)

        // Rotated 90° clockwise: top-left corner moves to top-right
        #expect(CanvasCursorLogic.resizePosition(xSign: -1, ySign: -1, layerRotationDegrees: 90) == .topTrailing)
        #expect(CanvasCursorLogic.resizePosition(xSign: 1, ySign: -1, layerRotationDegrees: 90) == .bottomTrailing)

        // Rotated 45° clockwise: top-left corner points straight up (.top)
        #expect(CanvasCursorLogic.resizePosition(xSign: -1, ySign: -1, layerRotationDegrees: 45) == .top)

        // Custom rotate cursor image is valid and non-empty
        let rotateImg = CanvasCursors.rotateCursorImage
        #expect(rotateImg.size.width >= 16)
        #expect(rotateImg.size.height >= 16)
    }
}
