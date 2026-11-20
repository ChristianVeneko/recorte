import AppKit
import CoreGraphics
import CoreText
import Foundation
import Observation
import RecorteCore
import RecorteIO

@MainActor
@Observable
public final class EditorModel: Identifiable {
    public let id: UUID
    public var title: String
    public var document: EditorDocument
    public var activeTool: EditorTool = .move {
        didSet {
            if activeTool == .crop {
                if cropSpec == nil {
                    initializeCropSpec()
                }
            } else if oldValue == .crop {
                cropSpec = nil
            }
        }
    }
    public var cropSpec: CropSpec?
    public var renderedImage: CGImage?
    public var isRemovingBackground: Bool = false
    public var lastErrorMessage: String?
    public var undoManager: UndoManager

    // Tool creation defaults
    public var brushColor: RGBAColor = .red
    public var brushLineWidth: Double = 6.0
    public var defaultTextSpec: TextSpec = TextSpec(
        string: "Double-click or edit text",
        fontName: "HelveticaNeue-Bold",
        size: 36.0,
        color: .white,
        alignment: .center,
        stroke: TextStrokeSpec(color: .black, width: 2.0),
        background: nil
    )
    public var defaultShapeSpec: ShapeSpec = ShapeSpec(
        kind: .roundedRect(cornerRadius: 12),
        size: CGSize(width: 180, height: 120),
        strokeColor: .red,
        fillColor: nil,
        lineWidth: 4.0
    )
    public var defaultStickerPointSize: Double = 72.0
    public var defaultStickerTint: RGBAColor = .white

    private var continuousEditStartDocument: EditorDocument?

    public init(
        id: UUID = UUID(),
        title: String = "Untitled",
        document: EditorDocument = EditorDocument(),
        undoManager: UndoManager = UndoManager()
    ) {
        self.id = id
        self.title = title
        self.document = document
        self.undoManager = undoManager
        if !document.layers.isEmpty {
            rerender()
        }
    }

    public var isEmpty: Bool {
        document.layers.isEmpty
    }

    public var canvasCenter: CGPoint {
        CGPoint(x: document.canvasSize.width / 2.0, y: document.canvasSize.height / 2.0)
    }

    public var selectedLayer: Layer? {
        guard let selection = document.selection else { return nil }
        return document.layer(id: selection)
    }

    public var displayedLayers: [Layer] {
        document.layers.reversed()
    }

    public var canRemoveBackground: Bool {
        guard !isRemovingBackground else { return false }
        return targetImageLayerForBackgroundRemoval() != nil
    }

    // MARK: - Undo / Redo

    public func undo() {
        undoManager.undo()
    }

    public func redo() {
        undoManager.redo()
    }

    private func registerUndoSnapshot(
        previousDoc: EditorDocument,
        previousTitle: String,
        actionName: String
    ) {
        let shouldManageGroup = !undoManager.isUndoing && !undoManager.isRedoing && undoManager.groupingLevel == 0
        let previousGroupsByEvent = undoManager.groupsByEvent
        if shouldManageGroup {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.applyDocumentSnapshot(previousDoc, titleSnapshot: previousTitle, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        if shouldManageGroup {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = previousGroupsByEvent
        }
    }

    private func applyDocumentSnapshot(_ snapshot: EditorDocument, titleSnapshot: String, actionName: String) {
        let previousDoc = document
        let previousTitle = title
        document = snapshot
        title = titleSnapshot
        if activeTool == .crop {
            cropSpec = nil
            activeTool = .move
        }
        rerender()

        registerUndoSnapshot(previousDoc: previousDoc, previousTitle: previousTitle, actionName: actionName)
    }

    private func commitMutation(actionName: String, _ mutation: (inout EditorDocument) -> Void) {
        let previousDoc = document
        let previousTitle = title
        var nextDoc = document
        mutation(&nextDoc)
        guard nextDoc != previousDoc else { return }

        document = nextDoc
        rerender()

        registerUndoSnapshot(previousDoc: previousDoc, previousTitle: previousTitle, actionName: actionName)
    }

    public func beginContinuousEdit() {
        if continuousEditStartDocument == nil {
            continuousEditStartDocument = document
        }
    }

    public func endContinuousEdit(actionName: String) {
        guard let startDoc = continuousEditStartDocument else { return }
        continuousEditStartDocument = nil
        guard startDoc != document else { return }

        registerUndoSnapshot(previousDoc: startDoc, previousTitle: title, actionName: actionName)
    }

    // MARK: - Rendering

    public func rerender() {
        guard document.canvasSize.width >= 1, document.canvasSize.height >= 1 else {
            renderedImage = nil
            return
        }
        if document.layers.isEmpty && document.background == .transparent {
            renderedImage = nil
            return
        }
        renderedImage = try? Renderer.render(document, scale: 1.0)
    }

    public func renderComposite() -> CGImage? {
        if let renderedImage {
            return renderedImage
        }
        rerender()
        return renderedImage
    }

    // MARK: - Input: Paste, Open, Drop

    public func pasteImage(_ imported: ImportedImage) {
        importImage(imported, at: nil, actionName: isEmpty ? "Paste Image" : "Paste Layer")
    }

    public func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general) throws {
        let imported = try ImageImporter.importFromPasteboard(pasteboard)
        pasteImage(imported)
    }

    public func openImage(from url: URL) throws {
        let imported = try ImageImporter.importFromURL(url)
        importImage(imported, at: nil, actionName: isEmpty ? "Open Image" : "Import Layer")
    }

    public func importDroppedImage(_ imported: ImportedImage, at canvasPoint: CGPoint? = nil) {
        importImage(imported, at: canvasPoint, actionName: isEmpty ? "Drop Image" : "Drop Layer")
    }

    private func importImage(_ imported: ImportedImage, at canvasPoint: CGPoint?, actionName: String) {
        let previousDoc = document
        let previousTitle = title

        var nextDoc = document
        let cgImage = imported.image

        if nextDoc.layers.isEmpty {
            let newSize = CGSize(width: cgImage.width, height: cgImage.height)
            nextDoc.canvasSize = newSize
            let layer = Layer(
                name: imported.suggestedName,
                kind: .image(SendableImage(cgImage)),
                transform: LayerTransform(position: CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0))
            )
            nextDoc.add(layer)
            title = imported.suggestedName
        } else {
            let position = canvasPoint ?? CGPoint(
                x: nextDoc.canvasSize.width / 2.0,
                y: nextDoc.canvasSize.height / 2.0
            )
            let layer = Layer(
                name: imported.suggestedName,
                kind: .image(SendableImage(cgImage)),
                transform: LayerTransform(position: position)
            )
            nextDoc.add(layer)
        }

        document = nextDoc
        rerender()

        registerUndoSnapshot(previousDoc: previousDoc, previousTitle: previousTitle, actionName: actionName)
    }

    @discardableResult
    public func dropImageFromTray(
        sourceEditorID: UUID,
        from workspace: Workspace,
        at canvasPoint: CGPoint? = nil
    ) -> Bool {
        guard let sourceEditor = workspace.editor(id: sourceEditorID),
              let sourceImage = sourceEditor.renderComposite() else {
            return false
        }
        let imported = ImportedImage(image: sourceImage, suggestedName: sourceEditor.title)
        importImage(imported, at: canvasPoint, actionName: "Add Layer from Tray")
        return true
    }

    // MARK: - Cropping

    private func initializeCropSpec() {
        let bounds = CGRect(origin: .zero, size: document.canvasSize)
        cropSpec = CropSpec(rect: bounds, aspect: .free, shape: .rectangle)
    }

    public func beginCrop() {
        guard !isEmpty else { return }
        activeTool = .crop
        initializeCropSpec()
    }

    public func updateCropRect(_ rect: CGRect) {
        guard var spec = cropSpec else { return }
        let bounds = CGRect(origin: .zero, size: document.canvasSize)
        spec.rect = Cropper.constrainRect(rect, aspect: spec.aspect, in: bounds)
        cropSpec = spec
    }

    public func updateCropAspect(_ aspect: CropAspect) {
        guard var spec = cropSpec else { return }
        let bounds = CGRect(origin: .zero, size: document.canvasSize)
        spec.aspect = aspect
        spec.rect = Cropper.constrainRect(spec.rect, aspect: aspect, in: bounds)
        cropSpec = spec
    }

    public func updateCropShape(_ shape: CropShape) {
        guard var spec = cropSpec else { return }
        spec.shape = shape
        cropSpec = spec
    }

    public func setCropRotation(_ degrees: Double) {
        guard var spec = cropSpec else { return }
        spec.rotationDegrees = degrees
        cropSpec = spec
    }

    public func rotateCrop90(clockwise: Bool) {
        guard var spec = cropSpec else { return }
        let delta = clockwise ? 90.0 : -90.0
        var next = (spec.rotationDegrees + delta).truncatingRemainder(dividingBy: 360.0)
        if next > 180.0 { next -= 360.0 }
        if next < -180.0 { next += 360.0 }
        spec.rotationDegrees = next
        cropSpec = spec
    }

    public func toggleCropFlipH() {
        guard var spec = cropSpec else { return }
        spec.flipH.toggle()
        cropSpec = spec
    }

    public func toggleCropFlipV() {
        guard var spec = cropSpec else { return }
        spec.flipV.toggle()
        cropSpec = spec
    }

    public func resetCrop() {
        initializeCropSpec()
    }

    public func applyCrop() throws {
        guard let spec = cropSpec, let sourceImage = renderComposite() else { return }
        let cropped = try Cropper.crop(sourceImage, spec: spec)
        let newSize = CGSize(width: cropped.width, height: cropped.height)

        let previousDoc = document
        let previousTitle = title

        var nextDoc = EditorDocument(
            canvasSize: newSize,
            background: spec.shape == .rectangle ? document.background : .transparent,
            layers: [],
            selection: nil
        )
        let croppedLayer = Layer(
            name: title,
            kind: .image(SendableImage(cropped)),
            transform: LayerTransform(position: CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0))
        )
        nextDoc.add(croppedLayer)

        cropSpec = nil
        activeTool = .move
        document = nextDoc
        rerender()

        registerUndoSnapshot(previousDoc: previousDoc, previousTitle: previousTitle, actionName: "Crop")
    }

    public func cancelCrop() {
        cropSpec = nil
        if activeTool == .crop {
            activeTool = .move
        }
    }

    // MARK: - Layer Creation

    public func addTextLayer(_ spec: TextSpec? = nil, at position: CGPoint? = nil) {
        let resolved = spec ?? defaultTextSpec
        let pos = position ?? canvasCenter
        let label = resolved.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.isEmpty ? "Text" : String(label.prefix(24))
        commitMutation(actionName: "Add Text") { doc in
            let layer = Layer(
                name: name,
                kind: .text(resolved),
                transform: LayerTransform(position: pos)
            )
            doc.add(layer)
        }
    }

    public func addShapeLayer(_ spec: ShapeSpec? = nil, at position: CGPoint? = nil) {
        let resolved = spec ?? defaultShapeSpec
        let pos = position ?? canvasCenter
        let name: String = switch resolved.kind {
        case .rect: "Rectangle"
        case .roundedRect: "Rounded Rect"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        default: "Shape"
        }
        commitMutation(actionName: "Add \(name)") { doc in
            let layer = Layer(
                name: name,
                kind: .shape(resolved),
                transform: LayerTransform(position: pos)
            )
            doc.add(layer)
        }
    }

    public func addStickerLayer(_ spec: StickerSpec, at position: CGPoint? = nil) {
        let pos = position ?? canvasCenter
        let name: String = switch spec.content {
        case .emoji(let value): "Sticker \(value)"
        case .sfSymbol(let symbol): symbol
        }
        commitMutation(actionName: "Add Sticker") { doc in
            let layer = Layer(
                name: name,
                kind: .sticker(spec),
                transform: LayerTransform(position: pos)
            )
            doc.add(layer)
        }
    }

    public func commitBrushStroke(points: [CGPoint], color: RGBAColor, lineWidth: Double) {
        guard !points.isEmpty else { return }
        guard let strokeImage = rasterizeBrushStroke(
            points: points,
            color: color,
            lineWidth: lineWidth,
            canvasSize: document.canvasSize
        ) else {
            return
        }
        let pos = canvasCenter
        commitMutation(actionName: "Draw Stroke") { doc in
            let layer = Layer(
                name: "Drawing",
                kind: .image(SendableImage(strokeImage)),
                transform: LayerTransform(position: pos)
            )
            doc.add(layer)
        }
    }

    private func rasterizeBrushStroke(
        points: [CGPoint],
        color: RGBAColor,
        lineWidth: Double,
        canvasSize: CGSize
    ) -> CGImage? {
        let width = max(1, Int(canvasSize.width.rounded()))
        let height = max(1, Int(canvasSize.height.rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip context vertically so top-left (y-down) canvas points rasterize accurately
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(CGFloat(max(1.0, lineWidth)))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if points.count == 1, let first = points.first {
            let radius = CGFloat(max(1.0, lineWidth)) / 2.0
            ctx.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
        } else {
            ctx.beginPath()
            ctx.move(to: points[0])
            for pt in points.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
        }

        return ctx.makeImage()
    }

    // MARK: - Layer Operations

    public func selectLayer(id: UUID?) {
        document.selection = id
    }

    public func duplicateLayer(id: UUID) {
        commitMutation(actionName: "Duplicate Layer") { doc in
            doc.duplicate(id: id)
        }
    }

    public func duplicateSelectedLayer() {
        guard let id = document.selection else { return }
        duplicateLayer(id: id)
    }

    public func deleteLayer(id: UUID) {
        commitMutation(actionName: "Delete Layer") { doc in
            doc.remove(id: id)
        }
    }

    public func deleteSelectedLayer() {
        guard let id = document.selection else { return }
        deleteLayer(id: id)
    }

    public func toggleVisibility(id: UUID) {
        guard let layer = document.layer(id: id) else { return }
        commitMutation(actionName: layer.isHidden ? "Show Layer" : "Hide Layer") { doc in
            doc.setVisibility(id: id, isHidden: !layer.isHidden)
        }
    }

    public func toggleLock(id: UUID) {
        guard let layer = document.layer(id: id) else { return }
        commitMutation(actionName: layer.isLocked ? "Unlock Layer" : "Lock Layer") { doc in
            doc.setLock(id: id, isLocked: !layer.isLocked)
        }
    }

    public func setOpacity(id: UUID, opacity: Double, continuous: Bool = false) {
        if continuous {
            beginContinuousEdit()
            document.setOpacity(id: id, opacity: opacity)
            rerender()
        } else {
            commitMutation(actionName: "Change Opacity") { doc in
                doc.setOpacity(id: id, opacity: opacity)
            }
        }
    }

    /// Reorders layers from the top-to-bottom UI display order (`displayedLayers = layers.reversed()`).
    public func reorderDisplayedLayers(fromOffsets: IndexSet, toOffset: Int) {
        var displayed = displayedLayers
        let moving = fromOffsets.sorted().map { displayed[$0] }
        for index in fromOffsets.sorted(by: >) {
            displayed.remove(at: index)
        }
        let adjustedOffset = toOffset - fromOffsets.filter { $0 < toOffset }.count
        let clampedOffset = min(max(adjustedOffset, 0), displayed.count)
        displayed.insert(contentsOf: moving, at: clampedOffset)
        let reorderedUnderlying = Array(displayed.reversed())

        commitMutation(actionName: "Reorder Layers") { doc in
            doc.layers = reorderedUnderlying
        }
    }

    public func moveLayer(id: UUID, to position: CGPoint, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == id }),
              !document.layers[idx].isLocked else { return }
        if continuous {
            beginContinuousEdit()
            document.layers[idx].transform.position = position
            rerender()
        } else {
            commitMutation(actionName: "Move Layer") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == id }), !doc.layers[i].isLocked else { return }
                doc.layers[i].transform.position = position
            }
        }
    }

    public func setLayerTransform(id: UUID, transform: LayerTransform, continuous: Bool = false, actionName: String = "Transform Layer") {
        guard let idx = document.layers.firstIndex(where: { $0.id == id }),
              !document.layers[idx].isLocked else { return }
        if continuous {
            beginContinuousEdit()
            document.layers[idx].transform = transform
            rerender()
        } else {
            commitMutation(actionName: actionName) { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == id }), !doc.layers[i].isLocked else { return }
                doc.layers[i].transform = transform
            }
        }
    }

    public func renameLayer(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commitMutation(actionName: "Rename Layer") { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            doc.layers[i].name = trimmed
        }
    }

    // MARK: - Layer Content Updates

    public func setFilterPreset(_ preset: FilterPreset, for layerID: UUID) {
        commitMutation(actionName: "Apply Filter") { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                  !doc.layers[i].isLocked else { return }
            switch doc.layers[i].kind {
            case .image(var img):
                img.filterPreset = preset
                doc.layers[i].kind = .image(img)
            case .text, .shape, .sticker:
                break
            default:
                break
            }
        }
    }

    public func setAdjustments(_ adjustments: Adjustments, for layerID: UUID, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked else { return }

        if continuous {
            beginContinuousEdit()
            switch document.layers[idx].kind {
            case .image(var img):
                img.adjustments = adjustments
                document.layers[idx].kind = .image(img)
                rerender()
            case .text, .shape, .sticker:
                break
            default:
                break
            }
        } else {
            commitMutation(actionName: "Adjust Image") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                      !doc.layers[i].isLocked else { return }
                switch doc.layers[i].kind {
                case .image(var img):
                    img.adjustments = adjustments
                    doc.layers[i].kind = .image(img)
                case .text, .shape, .sticker:
                    break
                default:
                    break
                }
            }
        }
    }

    public func updateTextSpec(_ spec: TextSpec, for layerID: UUID, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked else { return }

        if continuous {
            beginContinuousEdit()
            document.layers[idx].kind = .text(spec)
            rerender()
        } else {
            commitMutation(actionName: "Edit Text") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                      !doc.layers[i].isLocked else { return }
                doc.layers[i].kind = .text(spec)
            }
        }
    }

    public func updateShapeSpec(_ spec: ShapeSpec, for layerID: UUID, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked else { return }

        if continuous {
            beginContinuousEdit()
            document.layers[idx].kind = .shape(spec)
            rerender()
        } else {
            commitMutation(actionName: "Edit Shape") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                      !doc.layers[i].isLocked else { return }
                doc.layers[i].kind = .shape(spec)
            }
        }
    }

    public func updateStickerSpec(_ spec: StickerSpec, for layerID: UUID, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked else { return }

        if continuous {
            beginContinuousEdit()
            document.layers[idx].kind = .sticker(spec)
            rerender()
        } else {
            commitMutation(actionName: "Edit Sticker") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                      !doc.layers[i].isLocked else { return }
                doc.layers[i].kind = .sticker(spec)
            }
        }
    }

    public func setCanvasBackground(_ background: CanvasBackground) {
        commitMutation(actionName: "Change Background") { doc in
            doc.background = background
        }
    }

    // MARK: - Background Removal (Apple Vision SubjectLifter)

    private func targetImageLayerForBackgroundRemoval() -> (UUID, SendableImage)? {
        if let selected = selectedLayer, !selected.isLocked {
            switch selected.kind {
            case .image(let img):
                return (selected.id, img)
            case .text, .shape, .sticker:
                break
            default:
                break
            }
        }
        for layer in document.layers.reversed() where !layer.isLocked {
            switch layer.kind {
            case .image(let img):
                return (layer.id, img)
            case .text, .shape, .sticker:
                continue
            default:
                continue
            }
        }
        return nil
    }

    public func removeBackgroundFromSelectedLayer() async {
        guard !isRemovingBackground else { return }
        guard let (layerID, sendableImg) = targetImageLayerForBackgroundRemoval() else {
            lastErrorMessage = "Select an unlocked image layer to remove its background."
            return
        }

        isRemovingBackground = true
        lastErrorMessage = nil
        defer { isRemovingBackground = false }

        do {
            let sourceCG = sendableImg.cgImage
            let lifted = try await Task.detached(priority: .userInitiated) {
                try await SubjectLifter.liftSubject(sourceCG)
            }.value

            commitMutation(actionName: "Remove Background") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }) else { return }
                let updated = SendableImage(
                    lifted,
                    filterPreset: sendableImg.filterPreset,
                    adjustments: sendableImg.adjustments
                )
                doc.layers[i].kind = .image(updated)
            }
        } catch let error as SubjectLifterError {
            switch error {
            case .noSubjectFound:
                lastErrorMessage = "No foreground subject was detected in the selected image."
            case .invalidImage:
                lastErrorMessage = "The selected image could not be processed."
            case .maskGenerationFailed:
                lastErrorMessage = "Background removal failed to generate a subject mask."
            }
        } catch {
            lastErrorMessage = "Background removal failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Output: Copy, Share, AirDrop, Export

    @discardableResult
    public func copyCompositeToClipboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let composite = renderComposite() else { return false }
        return Clipboard.copy(composite, to: pasteboard)
    }

    public func shareableImage() -> ShareableImage? {
        guard let composite = renderComposite() else { return nil }
        return ShareableImage(image: composite, suggestedName: title)
    }

    public func shareViaAirDrop() {
        guard let composite = renderComposite() else { return }
        do {
            try ShareService.shareViaAirDrop(composite, name: title)
        } catch {
            lastErrorMessage = "AirDrop is unavailable on this Mac."
        }
    }

    public func exportImage(format: ImageExportFormat, to url: URL) throws {
        guard let composite = renderComposite() else {
            throw ImageExportError.encodingFailed
        }
        try ImageExporter.export(composite, to: url, format: format)
    }

    // MARK: - Layer Geometry & Display Helpers

    public func layerIntrinsicSize(for layer: Layer) -> CGSize {
        switch layer.kind {
        case .image(let img):
            return img.size
        case .shape(let spec):
            return CGSize(width: max(24, spec.size.width), height: max(24, spec.size.height))
        case .text(let spec):
            let font = CTFontCreateWithName(spec.fontName as CFString, CGFloat(spec.size), nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font]
            if let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, spec.string as CFString, attrs as CFDictionary) {
                let line = CTLineCreateWithAttributedString(attrStr)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                let h = ascent + descent
                return CGSize(width: max(40, w + 16), height: max(28, h + 12))
            }
            return CGSize(width: 120, height: 40)
        case .sticker(let spec):
            let dim = max(32, CGFloat(spec.pointSize) * 1.25)
            return CGSize(width: dim, height: dim)
        default:
            return CGSize(width: 120, height: 120)
        }
    }

    public func layerDisplayIcon(for layer: Layer) -> String {
        switch layer.kind {
        case .image:
            return "photo"
        case .text:
            return "textformat"
        case .shape(let spec):
            switch spec.kind {
            case .rect: return "rectangle"
            case .roundedRect: return "rectangle.roundedtop"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            default: return "square.on.circle"
            }
        case .sticker(let spec):
            switch spec.content {
            case .emoji: return "face.smiling"
            case .sfSymbol(let name): return name
            }
        default:
            return "square.stack.3d.up"
        }
    }
}
