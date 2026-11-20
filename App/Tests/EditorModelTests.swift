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
}
