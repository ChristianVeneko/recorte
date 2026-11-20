import AppKit
import CoreGraphics
import Foundation
import RecorteCore
import RecorteIO
import Testing
@testable import Recorte

@Suite("EditorModel & Workspace Tests")
@MainActor
struct EditorModelTests {

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

    private func alphaAt(x: Int, y: Int, in image: CGImage) -> UInt8 {
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
        return pixels[offset + 3]
    }

    @Test("Paste creates a document when empty, then adds a layer when non-empty")
    func pasteCreatesDocumentThenLayer() {
        let model = EditorModel()
        #expect(model.isEmpty)

        let first = ImportedImage(image: makeSolidImage(width: 400, height: 300, r: 220, g: 50, b: 50), suggestedName: "Screenshot 1")
        model.pasteImage(first)

        #expect(!model.isEmpty)
        #expect(model.document.canvasSize == CGSize(width: 400, height: 300))
        #expect(model.document.layers.count == 1)
        #expect(model.title == "Screenshot 1")
        #expect(model.document.layers[0].transform.position == CGPoint(x: 200, y: 150))

        let second = ImportedImage(image: makeSolidImage(width: 120, height: 80, r: 50, g: 120, b: 220), suggestedName: "Badge")
        model.pasteImage(second)

        #expect(model.document.canvasSize == CGSize(width: 400, height: 300))
        #expect(model.document.layers.count == 2)
        #expect(model.document.layers[1].name == "Badge")
        #expect(model.document.selection == model.document.layers[1].id)
    }

    @Test("Paste from NSPasteboard imports clipboard image")
    func pasteFromPasteboardWorks() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let img = makeSolidImage(width: 160, height: 90, r: 30, g: 200, b: 100)
        #expect(Clipboard.copy(img, to: pasteboard))

        let model = EditorModel()
        try model.pasteFromPasteboard(pasteboard)

        #expect(model.document.canvasSize == CGSize(width: 160, height: 90))
        #expect(model.document.layers.count == 1)
    }

    @Test("Apply crop changes canvas size and applies shape mask")
    func applyCropChangesCanvasSize() throws {
        let model = EditorModel()
        let img = makeSolidImage(width: 300, height: 200, r: 40, g: 140, b: 240)
        model.pasteImage(ImportedImage(image: img, suggestedName: "Photo"))

        model.beginCrop()
        #expect(model.activeTool == .crop)
        #expect(model.cropSpec != nil)

        model.updateCropAspect(.ratio1x1)
        model.updateCropRect(CGRect(x: 50, y: 20, width: 120, height: 120))
        model.updateCropShape(.ellipse)
        try model.applyCrop()

        #expect(model.cropSpec == nil)
        #expect(model.activeTool == .move)
        #expect(model.document.canvasSize == CGSize(width: 120, height: 120))
        #expect(model.renderedImage?.width == 120)
        #expect(model.renderedImage?.height == 120)
        if let rendered = model.renderedImage {
            #expect(alphaAt(x: 0, y: 0, in: rendered) == 0)
            #expect(alphaAt(x: 60, y: 60, in: rendered) == 255)
        }
    }

    @Test("Undo restores previous state and redo reapplies across crop and layer edits")
    func undoRestoresState() throws {
        let undoManager = UndoManager()
        let model = EditorModel(undoManager: undoManager)
        let img = makeSolidImage(width: 320, height: 240, r: 10, g: 180, b: 90)
        model.pasteImage(ImportedImage(image: img, suggestedName: "Base"))

        model.addTextLayer(TextSpec(string: "Hello"))
        #expect(model.document.layers.count == 2)

        model.beginCrop()
        model.updateCropRect(CGRect(x: 20, y: 20, width: 100, height: 80))
        try model.applyCrop()
        #expect(model.document.canvasSize == CGSize(width: 100, height: 80))
        #expect(model.document.layers.count == 1)

        // Undo crop
        model.undo()
        #expect(model.document.canvasSize == CGSize(width: 320, height: 240))
        #expect(model.document.layers.count == 2)

        // Undo text layer
        model.undo()
        #expect(model.document.layers.count == 1)

        // Redo text layer
        model.redo()
        #expect(model.document.layers.count == 2)

        // Redo crop
        model.redo()
        #expect(model.document.canvasSize == CGSize(width: 100, height: 80))
    }

    @Test("Tray drop from another open document adds a new layer and supports undo")
    func trayDropAddsLayer() {
        let workspace = Workspace()
        let target = workspace.createEditor(title: "Main")
        target.pasteImage(ImportedImage(image: makeSolidImage(width: 400, height: 300, r: 20, g: 20, b: 20), suggestedName: "Main"))

        let source = workspace.createEditor(title: "Cutout")
        source.pasteImage(ImportedImage(image: makeSolidImage(width: 100, height: 100, r: 255, g: 200, b: 0), suggestedName: "Cutout"))

        #expect(workspace.editors.count == 2)
        #expect(target.document.layers.count == 1)

        let dropped = target.dropImageFromTray(
            sourceEditorID: source.id,
            from: workspace,
            at: CGPoint(x: 180, y: 120)
        )
        #expect(dropped)
        #expect(target.document.layers.count == 2)
        #expect(target.document.layers.last?.name == "Cutout")
        #expect(target.document.layers.last?.transform.position == CGPoint(x: 180, y: 120))

        target.undo()
        #expect(target.document.layers.count == 1)
    }

    @Test("Layer operations: duplicate, delete, reorder, visibility, lock, opacity")
    func layerOperationsWork() {
        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 200, height: 200), suggestedName: "BG"))
        model.addShapeLayer(ShapeSpec(kind: .rect))
        model.addStickerLayer(.emoji("🔥"))
        #expect(model.document.layers.count == 3)

        let topID = model.document.layers[2].id
        model.duplicateSelectedLayer()
        #expect(model.document.layers.count == 4)

        model.deleteSelectedLayer()
        #expect(model.document.layers.count == 3)

        // Toggle visibility & opacity
        model.toggleVisibility(id: topID)
        #expect(model.document.layer(id: topID)?.isHidden == true)

        model.setOpacity(id: topID, opacity: 0.45)
        #expect(model.document.layer(id: topID)?.opacity == 0.45)

        // Lock blocks moving
        let originalPos = model.document.layer(id: topID)!.transform.position
        model.toggleLock(id: topID)
        #expect(model.document.layer(id: topID)?.isLocked == true)
        model.moveLayer(id: topID, to: CGPoint(x: 10, y: 10))
        #expect(model.document.layer(id: topID)?.transform.position == originalPos)

        // Reorder in top-to-bottom UI order: move top-most (index 0 in UI) to bottom (index 3 in UI)
        let bottomIDBefore = model.document.layers[0].id
        model.reorderDisplayedLayers(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(model.document.layers[0].id == topID)
        #expect(model.document.layers[1].id == bottomIDBefore)
    }

    @Test("Filters, drawing stroke, clipboard copy, and export work")
    func filtersDrawAndOutputWork() throws {
        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 120, height: 80, r: 100, g: 150, b: 200), suggestedName: "Shot"))
        let baseLayerID = model.document.layers[0].id

        model.setFilterPreset(.noir, for: baseLayerID)
        model.setAdjustments(Adjustments(brightness: 0.1, contrast: 1.2), for: baseLayerID)
        if case .image(let img) = model.document.layer(id: baseLayerID)?.kind {
            #expect(img.filterPreset == .noir)
            #expect(img.adjustments.contrast == 1.2)
        } else {
            Issue.record("Expected image layer")
        }

        // Draw stroke adds a drawing layer
        model.commitBrushStroke(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 60)],
            color: .red,
            lineWidth: 6.0
        )
        #expect(model.document.layers.count == 2)

        // Copy composite to unique pasteboard
        let pb = NSPasteboard.withUniqueName()
        #expect(model.copyCompositeToClipboard(pb))
        let reimported = try ImageImporter.importFromPasteboard(pb)
        #expect(reimported.image.width == 120)
        #expect(reimported.image.height == 80)

        // Export PNG, JPEG, HEIC to temporary directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorteAppTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for format in [ImageExportFormat.png, .jpeg(quality: 0.9), .heic(quality: 0.9)] {
            let fileURL = tempDir.appendingPathComponent("out.\(format.fileExtension)")
            try model.exportImage(format: format, to: fileURL)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("Remove background reports an error on blank solid image without crashing")
    func removeBackgroundHandlesBlankImage() async {
        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 64, height: 64, r: 255, g: 255, b: 255), suggestedName: "Blank"))
        await model.removeBackgroundFromSelectedLayer()
        #expect(!model.isRemovingBackground)
        #expect(model.lastErrorMessage != nil)
    }

    @Test("S13: Save/Open .recorte project preserves layers, PDF export writes PDF, Save to Downloads writes file")
    func projectPersistencePDFAndDownloads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorteT7-S13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 240, height: 180, r: 50, g: 120, b: 220), suggestedName: "Photo"))
        model.addTextLayer(TextSpec(string: "Saved Note"))
        model.commitBrushStroke(points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], color: .red, lineWidth: 5.0)

        let projectURL = tempDir.appendingPathComponent("Sample.recorte")
        try model.saveProject(to: projectURL)
        #expect(model.projectURL == projectURL)

        let loaded = EditorModel()
        try loaded.loadProject(from: projectURL)
        #expect(loaded.document.canvasSize == CGSize(width: 240, height: 180))
        #expect(loaded.document.layers.count == 3)
        #expect(loaded.projectURL == projectURL)

        let pdfURL = tempDir.appendingPathComponent("Output.pdf")
        try loaded.exportPDF(to: pdfURL)
        let pdfData = try Data(contentsOf: pdfURL)
        #expect(pdfData.starts(with: Data("%PDF".utf8)))

        let downloadsDir = tempDir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        let saved1 = try loaded.saveToDownloads(format: .png, directory: downloadsDir)
        let saved2 = try loaded.saveToDownloads(format: .png, directory: downloadsDir)
        #expect(FileManager.default.fileExists(atPath: saved1.path))
        #expect(FileManager.default.fileExists(atPath: saved2.path))
        #expect(saved1.lastPathComponent != saved2.lastPathComponent)
    }

    @Test("S15: Lasso, Clone, Perspective, Deform, Curves, Resize, Rotate 90, and Flip edit and undo cleanly")
    func imageToolsEditAndUndo() throws {
        let model = EditorModel()
        let baseImg = makeSolidImage(width: 200, height: 100, r: 80, g: 120, b: 180)
        model.pasteImage(ImportedImage(image: baseImg, suggestedName: "Base"))
        let layerID = model.document.layers[0].id

        // Resize with keepAspect
        try model.resizeDocument(to: CGSize(width: 100, height: 100), keepAspect: true)
        #expect(model.document.canvasSize == CGSize(width: 100, height: 50))
        model.undo()
        #expect(model.document.canvasSize == CGSize(width: 200, height: 100))

        // Rotate 90 right & undo
        try model.rotateDocument90(direction: .right90)
        #expect(model.document.canvasSize == CGSize(width: 100, height: 200))
        model.undo()
        #expect(model.document.canvasSize == CGSize(width: 200, height: 100))

        // Flip horizontal & undo
        try model.flipDocument(axis: .horizontal)
        #expect(model.document.canvasSize == CGSize(width: 200, height: 100))
        model.undo()

        // Tone curve & undo
        let brightCurve = ToneCurveSpec(
            point0: CGPoint(x: 0.0, y: 0.0),
            point1: CGPoint(x: 0.25, y: 0.4),
            point2: CGPoint(x: 0.5, y: 0.7),
            point3: CGPoint(x: 0.75, y: 0.9),
            point4: CGPoint(x: 1.0, y: 1.0)
        )
        try model.applyToneCurve(brightCurve, to: layerID)
        let afterCurveDoc = model.document
        model.undo()
        #expect(model.document != afterCurveDoc)

        // Deform & undo
        try model.applyDeform(preset: .twirl, center: CGPoint(x: 100, y: 50), radius: 40, strength: 0.5)
        let afterDeformDoc = model.document
        model.undo()
        #expect(model.document != afterDeformDoc)

        // Clone stamp & undo
        try model.applyCloneStamp(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 60), radius: 15)
        let afterCloneDoc = model.document
        model.undo()
        #expect(model.document != afterCloneDoc)

        // Perspective & undo
        model.beginPerspective()
        #expect(model.perspectiveQuad != nil)
        model.perspectiveQuad = PerspectiveQuad(
            topLeft: CGPoint(x: 10, y: 10),
            topRight: CGPoint(x: 190, y: 10),
            bottomRight: CGPoint(x: 180, y: 90),
            bottomLeft: CGPoint(x: 20, y: 90)
        )
        try model.applyPerspective()
        #expect(model.perspectiveQuad == nil)
        let afterPerspDoc = model.document
        model.undo()
        #expect(model.document != afterPerspDoc)

        // Lasso cutout & undo
        let lassoPoints = [
            CGPoint(x: 40, y: 20),
            CGPoint(x: 160, y: 20),
            CGPoint(x: 160, y: 80),
            CGPoint(x: 40, y: 80)
        ]
        try model.applyLassoCutout(points: lassoPoints, cropToBounds: true)
        if case .image(let cutImg) = model.selectedLayer?.kind {
            #expect(cutImg.width == 120)
            #expect(cutImg.height == 60)
        } else {
            Issue.record("Expected cropped image layer after lasso cutout")
        }
        model.undo()
        if case .image(let restoredImg) = model.selectedLayer?.kind {
            #expect(restoredImg.width == 200)
            #expect(restoredImg.height == 100)
        } else {
            Issue.record("Expected original image layer after undo")
        }
    }

    @Test("S16: Text gradient fill and speech bubble style update and undo cleanly")
    func textGradientAndBubbleWork() {
        let model = EditorModel()
        model.addTextLayer(TextSpec(string: "Hello"))
        let layerID = model.document.layers[0].id

        var styled = TextSpec(string: "Wow!")
        styled.gradient = TextGradientSpec(colors: [.red, .yellow], angleDegrees: 45)
        styled.bubble = .speech
        styled.bubbleColor = .white
        styled.bubbleStrokeColor = .black
        styled.bubbleStrokeWidth = 3.0

        model.updateTextSpec(styled, for: layerID)
        if case .text(let spec) = model.document.layer(id: layerID)?.kind {
            #expect(spec.gradient?.colors.count == 2)
            #expect(spec.bubble == .speech)
            #expect(spec.bubbleStrokeWidth == 3.0)
        } else {
            Issue.record("Expected text layer")
        }
        #expect(model.renderedImage != nil)

        model.undo()
        if case .text(let spec) = model.document.layer(id: layerID)?.kind {
            #expect(spec.gradient == nil)
            #expect(spec.bubble == .none)
        } else {
            Issue.record("Expected original text layer after undo")
        }
    }

    @Test("S17: Drawing tool kinds, image frames, and triangle/star shapes work and undo")
    func drawingToolsFramesAndShapesWork() {
        let model = EditorModel()
        model.pasteImage(ImportedImage(image: makeSolidImage(width: 200, height: 200), suggestedName: "Pic"))
        let imgID = model.document.layers[0].id

        model.setImageFrame(.polaroid(caption: "Summer", borderColor: .white), for: imgID)
        if case .image(let img) = model.document.layer(id: imgID)?.kind {
            #expect(img.frame == .polaroid(caption: "Summer", borderColor: .white))
        } else {
            Issue.record("Expected image layer")
        }
        model.undo()
        if case .image(let img) = model.document.layer(id: imgID)?.kind {
            #expect(img.frame == .none)
        }

        // Drawing tool with brush/marker/highlighter creates a LayerKind.drawing layer
        model.drawingToolKind = .highlighter
        model.commitBrushStroke(points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 40)], color: .yellow, lineWidth: 16)
        if case .drawing(let drawingSpec) = model.selectedLayer?.kind {
            #expect(drawingSpec.strokes.count == 1)
            #expect(drawingSpec.strokes[0].tool == .highlighter)
        } else {
            Issue.record("Expected LayerKind.drawing layer")
        }

        // Basic Paint shapes including triangle and star
        model.addShapeLayer(ShapeSpec(kind: .triangle))
        #expect(model.selectedLayer?.name == "Triangle")
        model.addShapeLayer(ShapeSpec(kind: .star))
        #expect(model.selectedLayer?.name == "Star")
        #expect(model.renderedImage != nil)
    }

    @Test("S18: Collage grid layout populates cells and Free Style creates a blank canvas")
    func collageLayoutsAndFreeStyleWork() throws {
        let model = EditorModel()
        let imgs = [
            makeSolidImage(width: 100, height: 100, r: 255, g: 0, b: 0),
            makeSolidImage(width: 100, height: 100, r: 0, g: 255, b: 0),
            makeSolidImage(width: 100, height: 100, r: 0, g: 0, b: 255),
            makeSolidImage(width: 100, height: 100, r: 255, g: 255, b: 0)
        ]

        try model.createCollage(
            layout: .fourGrid,
            images: imgs,
            canvasSize: CGSize(width: 600, height: 600),
            background: .solid(.white),
            spacing: 12,
            cornerRadius: 8
        )
        #expect(model.document.canvasSize == CGSize(width: 600, height: 600))
        #expect(model.document.layers.count == 4)
        #expect(model.renderedImage?.width == 600)

        try model.createCollage(
            layout: .freeStyle,
            images: [],
            canvasSize: CGSize(width: 800, height: 600),
            background: .solid(.white)
        )
        #expect(model.document.canvasSize == CGSize(width: 800, height: 600))
        #expect(model.document.layers.isEmpty)

        // Undo restores the 4-cell collage
        model.undo()
        #expect(model.document.layers.count == 4)
        #expect(model.document.canvasSize == CGSize(width: 600, height: 600))
    }
}
