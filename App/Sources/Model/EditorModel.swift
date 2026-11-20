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

            if activeTool == .perspective {
                if perspectiveQuad == nil {
                    initializePerspectiveQuad()
                }
            } else if oldValue == .perspective {
                perspectiveQuad = nil
            }

            if oldValue == .lasso && activeTool != .lasso {
                lassoPoints = []
            }
        }
    }
    public var cropSpec: CropSpec?
    public var renderedImage: CGImage?
    public var isRemovingBackground: Bool = false
    public var lastErrorMessage: String?
    public var statusMessage: String?
    public var projectURL: URL?
    public var undoManager: UndoManager

    // Sheet presentation triggers (for menus)
    public var isPresentingResizeSheet: Bool = false
    public var isPresentingCollageSheet: Bool = false

    // Tool creation defaults
    public var brushColor: RGBAColor = .red
    public var brushLineWidth: Double = 6.0
    public var drawingToolKind: DrawingToolKind = .brush
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
    public var defaultStickerBackground: RGBAColor? = nil
    public var lastSolidCanvasBackgroundColor: RGBAColor = .white

    // S24 Viewport & 60fps Live Transform Preview
    public var viewport: CanvasViewport = CanvasViewport()
    public var liveTransformPreview: LiveTransformPreview?
    public private(set) var renderCount: Int = 0

    // S15 interactive image tool state
    public var lassoPoints: [CGPoint] = []
    public var lassoCropToBounds: Bool = true
    public var cloneSourcePoint: CGPoint?
    public var cloneRadius: Double = 24.0
    public var cloneSoftness: Double = 0.5
    public var cloneOpacity: Double = 1.0
    public var perspectiveQuad: PerspectiveQuad?
    public var deformPreset: DeformPreset = .bump
    public var deformRadius: Double = 80.0
    public var deformStrength: Double = 0.5
    public var toneCurve: ToneCurveSpec = ToneCurveSpec()

    private var continuousEditStartDocument: EditorDocument?

    public struct LiveTransformPreview: Sendable {
        public let layerID: UUID
        public let startTransform: LayerTransform
        public var currentTransform: LayerTransform
        public let split: LiveTransformSplit
        public var isRotating: Bool
        public var isShiftSnapped: Bool
    }

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
        if !document.layers.isEmpty || document.background != .transparent {
            rerender()
        }
    }

    public var isEmpty: Bool {
        document.layers.isEmpty
    }

    public var hasCanvasSurface: Bool {
        !document.layers.isEmpty || document.background != .transparent
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
        return targetImageLayer() != nil
    }

    public var hasEditableImageLayer: Bool {
        targetImageLayer() != nil
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
                target.applyDocumentSnapshot(
                    previousDoc,
                    titleSnapshot: previousTitle,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)
        if shouldManageGroup {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = previousGroupsByEvent
        }
    }

    private func applyDocumentSnapshot(
        _ snapshot: EditorDocument,
        titleSnapshot: String,
        actionName: String
    ) {
        let previousDoc = document
        let previousTitle = title
        liveTransformPreview = nil
        document = snapshot
        title = titleSnapshot
        if activeTool == .crop {
            cropSpec = nil
            activeTool = .move
        }
        if activeTool == .perspective {
            perspectiveQuad = nil
            activeTool = .move
        }
        rerender()

        registerUndoSnapshot(
            previousDoc: previousDoc,
            previousTitle: previousTitle,
            actionName: actionName
        )
    }

    private func commitMutation(actionName: String, _ mutation: (inout EditorDocument) -> Void) {
        let previousDoc = document
        let previousTitle = title
        var nextDoc = document
        mutation(&nextDoc)
        guard nextDoc != previousDoc else { return }

        document = nextDoc
        rerender()

        registerUndoSnapshot(
            previousDoc: previousDoc,
            previousTitle: previousTitle,
            actionName: actionName
        )
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

        registerUndoSnapshot(
            previousDoc: startDoc,
            previousTitle: title,
            actionName: actionName
        )
    }

    // MARK: - S24 Viewport & 60fps Live Transform

    public func zoomToFit() {
        viewport.zoomToFit()
    }

    public func zoomToActualSize() {
        viewport.zoomToActualSize()
    }

    public func zoomIn() {
        viewport.zoomIn()
    }

    public func zoomOut() {
        viewport.zoomOut()
    }

    public func toggleSmartZoom(around pointer: CGPoint? = nil, baseCenter: CGPoint = .zero) {
        viewport.toggleSmartZoom(around: pointer, baseCenter: baseCenter)
    }

    public func beginLiveTransform(for layerID: UUID, isRotating: Bool = false) {
        guard let layer = document.layer(id: layerID), !layer.isLocked else { return }
        if liveTransformPreview?.layerID == layerID {
            liveTransformPreview?.isRotating = isRotating
            return
        }
        beginContinuousEdit()
        guard let split = DocumentRenderer.renderLiveTransformSplit(
            document,
            activeLayerID: layerID
        ) else { return }

        liveTransformPreview = LiveTransformPreview(
            layerID: layerID,
            startTransform: layer.transform,
            currentTransform: layer.transform,
            split: split,
            isRotating: isRotating,
            isShiftSnapped: false
        )
    }

    public func updateLiveTransform(
        _ transform: LayerTransform,
        isRotating: Bool? = nil,
        isShiftSnapped: Bool = false
    ) {
        guard var preview = liveTransformPreview else { return }
        preview.currentTransform = transform
        if let isRotating {
            preview.isRotating = isRotating
        }
        preview.isShiftSnapped = isShiftSnapped
        liveTransformPreview = preview
    }

    public func endLiveTransform(actionName: String) {
        guard let preview = liveTransformPreview else {
            endContinuousEdit(actionName: actionName)
            return
        }
        liveTransformPreview = nil

        if preview.currentTransform != preview.startTransform,
           let idx = document.layers.firstIndex(where: { $0.id == preview.layerID }),
           !document.layers[idx].isLocked {
            document.layers[idx].transform = preview.currentTransform
            rerender()
        }
        endContinuousEdit(actionName: actionName)
    }

    /// Handles MacBook trackpad two-finger rotation events smoothly at 60fps, committing on gesture end.
    public func handleTrackpadRotate(deltaDegrees: Double, phase: NSEvent.Phase) {
        guard activeTool != .crop && activeTool != .perspective,
              let layer = selectedLayer,
              !layer.isLocked else {
            return
        }

        if phase.contains(.began) || liveTransformPreview?.layerID != layer.id {
            beginLiveTransform(for: layer.id, isRotating: true)
        }

        if var preview = liveTransformPreview, preview.layerID == layer.id {
            var next = preview.currentTransform
            let rawDegrees = next.rotationDegrees + deltaDegrees
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            next.rotationDegrees = RotationMath.snapDegrees(rawDegrees, increment: 15.0, isShiftPressed: shiftHeld)
            preview.currentTransform = next
            preview.isRotating = true
            preview.isShiftSnapped = shiftHeld
            liveTransformPreview = preview
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            endLiveTransform(actionName: "Rotate Layer")
        }
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
        renderedImage = try? DocumentRenderer.render(document, scale: 1.0)
        renderCount += 1
    }

    public func renderComposite() -> CGImage? {
        if let renderedImage {
            return renderedImage
        }
        rerender()
        return renderedImage
    }

    // MARK: - S13: .recorte Projects, PDF Export, Save to Downloads

    public func saveProject(to url: URL) throws {
        let packageURL = url.pathExtension.lowercased() == RecorteProject.fileExtension
            ? url
            : url.appendingPathExtension(RecorteProject.fileExtension)
        try RecorteProject.save(document, to: packageURL)
        projectURL = packageURL
        let baseName = packageURL.deletingPathExtension().lastPathComponent
        if !baseName.isEmpty {
            title = baseName
        }
        statusMessage = "Saved \(packageURL.lastPathComponent)"
    }

    public func loadProject(from url: URL) throws {
        let loadedDocument = try RecorteProject.load(from: url)
        let previousDoc = document
        let previousTitle = title
        let baseName = url.deletingPathExtension().lastPathComponent
        let newTitle = baseName.isEmpty ? "Untitled" : baseName

        cropSpec = nil
        perspectiveQuad = nil
        lassoPoints = []
        liveTransformPreview = nil
        activeTool = .move
        document = loadedDocument
        title = newTitle
        projectURL = url
        rerender()

        registerUndoSnapshot(
            previousDoc: previousDoc,
            previousTitle: previousTitle,
            actionName: "Open Project"
        )
    }

    public func exportPDF(to url: URL) throws {
        guard hasCanvasSurface else {
            throw RecorteProjectError.pdfCreationFailed
        }
        try RecorteProject.exportPDF(document, to: url, scale: 1.0)
        statusMessage = "Exported \(url.lastPathComponent)"
    }

    @discardableResult
    public func saveToDownloads(
        format: ImageExportFormat = .png,
        directory: URL? = nil
    ) throws -> URL {
        guard let composite = renderComposite() else {
            throw ImageExportError.encodingFailed
        }
        let targetDir: URL
        if let directory {
            targetDir = directory
        } else if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            targetDir = downloads
        } else {
            throw ImageExportError.writeFailed(URL(fileURLWithPath: "/Downloads"))
        }

        let sanitized = sanitizeFilename(title)
        let ext = format.fileExtension
        let destination = uniqueURL(in: targetDir, baseName: sanitized, fileExtension: ext)
        try ImageExporter.export(composite, to: destination, format: format)
        statusMessage = "Saved to Downloads: \(destination.lastPathComponent)"
        return destination
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recorte" : cleaned
    }

    private func uniqueURL(in directory: URL, baseName: String, fileExtension: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Input: Paste, Open, Drop

    public func pasteImage(_ imported: ImportedImage) {
        importImage(imported, at: nil, actionName: isEmpty ? "Paste Image" : "Paste Layer")
    }

    public func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general) throws {
        let imported = try ImageImporter.importFromPasteboard(pasteboard)
        pasteImage(imported)
    }

    public func openFile(from url: URL) throws {
        if url.pathExtension.lowercased() == RecorteProject.fileExtension {
            try loadProject(from: url)
        } else {
            try openImage(from: url)
        }
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

        if nextDoc.layers.isEmpty && nextDoc.background == .transparent {
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
        guard hasCanvasSurface else { return }
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
        liveTransformPreview = nil
        activeTool = .move
        document = nextDoc
        rerender()

        registerUndoSnapshot(
            previousDoc: previousDoc,
            previousTitle: previousTitle,
            actionName: "Crop"
        )
    }

    public func cancelCrop() {
        cropSpec = nil
        if activeTool == .crop {
            activeTool = .move
        }
    }

    // MARK: - S15: Image Tools (Lasso, Clone, Perspective, Deform, Curves, Resize, Rotate 90, Flip)

    public func targetImageLayer() -> (Layer, SendableImage)? {
        if let selected = selectedLayer, !selected.isLocked {
            switch selected.kind {
            case .image(let img):
                return (selected, img)
            case .text, .shape, .sticker, .drawing:
                break
            default:
                break
            }
        }
        for layer in document.layers.reversed() where !layer.isLocked {
            switch layer.kind {
            case .image(let img):
                return (layer, img)
            case .text, .shape, .sticker, .drawing:
                continue
            default:
                continue
            }
        }
        return nil
    }

    public func canvasPointToImagePoint(_ canvasPoint: CGPoint, for layer: Layer, imageSize: CGSize) -> CGPoint {
        let dx = canvasPoint.x - layer.transform.position.x
        let dy = canvasPoint.y - layer.transform.position.y
        let rad = CGFloat(-layer.transform.rotationDegrees) * .pi / 180.0
        let cosA = cos(rad)
        let sinA = sin(rad)
        let rotX = dx * cosA - dy * sinA
        let rotY = dx * sinA + dy * cosA
        let sx = abs(layer.transform.scale.width) > 0.0001 ? layer.transform.scale.width : 1.0
        let sy = abs(layer.transform.scale.height) > 0.0001 ? layer.transform.scale.height : 1.0
        let localX = rotX / sx
        let localY = rotY / sy
        return CGPoint(x: localX + imageSize.width / 2.0, y: localY + imageSize.height / 2.0)
    }

    public func imagePointToCanvasPoint(_ imagePoint: CGPoint, for layer: Layer, imageSize: CGSize) -> CGPoint {
        let localX = (imagePoint.x - imageSize.width / 2.0) * layer.transform.scale.width
        let localY = (imagePoint.y - imageSize.height / 2.0) * layer.transform.scale.height
        let rad = CGFloat(layer.transform.rotationDegrees) * .pi / 180.0
        let cosA = cos(rad)
        let sinA = sin(rad)
        let rotX = localX * cosA - localY * sinA
        let rotY = localX * sinA + localY * cosA
        return CGPoint(x: layer.transform.position.x + rotX, y: layer.transform.position.y + rotY)
    }

    public func applyLassoCutout(points: [CGPoint], cropToBounds: Bool = true) throws {
        guard points.count >= 3 else {
            throw ImageToolError.invalidParameters
        }
        guard let (layer, sendableImg) = targetImageLayer() else {
            throw ImageToolError.invalidParameters
        }

        let imageSize = sendableImg.size
        let path = CGMutablePath()
        let imagePoints = points.map { canvasPointToImagePoint($0, for: layer, imageSize: imageSize) }
        path.move(to: imagePoints[0])
        for pt in imagePoints.dropFirst() {
            path.addLine(to: pt)
        }
        path.closeSubpath()

        let cutImage = try ImageTools.lassoCutout(
            sendableImg.cgImage,
            path: path,
            cropToPathBounds: cropToBounds
        )

        var newPosition = layer.transform.position
        if cropToBounds {
            let fullRect = CGRect(origin: .zero, size: imageSize)
            let clipped = path.boundingBoxOfPath.intersection(fullRect).integral
            if !clipped.isNull {
                let croppedCenterInImage = CGPoint(x: clipped.midX, y: clipped.midY)
                newPosition = imagePointToCanvasPoint(croppedCenterInImage, for: layer, imageSize: imageSize)
            }
        }

        lassoPoints = []
        commitMutation(actionName: "Lasso Cutout") { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == layer.id }) else { return }
            doc.layers[i].kind = .image(SendableImage(
                cutImage,
                filterPreset: sendableImg.filterPreset,
                adjustments: sendableImg.adjustments,
                frame: sendableImg.frame
            ))
            doc.layers[i].transform.position = newPosition
            doc.selection = layer.id
        }
    }

    public func applyCloneStamp(
        from sourceCanvasPoint: CGPoint,
        to destinationCanvasPoint: CGPoint,
        radius: CGFloat,
        softness: CGFloat = 0.5,
        opacity: CGFloat = 1.0,
        continuous: Bool = false
    ) throws {
        guard let (layer, sendableImg) = targetImageLayer() else {
            throw ImageToolError.invalidParameters
        }
        let imgSize = sendableImg.size
        let srcPt = canvasPointToImagePoint(sourceCanvasPoint, for: layer, imageSize: imgSize)
        let dstPt = canvasPointToImagePoint(destinationCanvasPoint, for: layer, imageSize: imgSize)
        let avgScale = max(0.01, (abs(layer.transform.scale.width) + abs(layer.transform.scale.height)) / 2.0)
        let imageRadius = max(1.0, radius / avgScale)

        let stamped = try ImageTools.cloneStamp(
            sendableImg.cgImage,
            from: srcPt,
            to: dstPt,
            radius: imageRadius,
            softness: softness,
            opacity: opacity
        )

        let updatedSendable = SendableImage(
            stamped,
            filterPreset: sendableImg.filterPreset,
            adjustments: sendableImg.adjustments,
            frame: sendableImg.frame
        )

        if continuous {
            beginContinuousEdit()
            if let i = document.layers.firstIndex(where: { $0.id == layer.id }) {
                document.layers[i].kind = .image(updatedSendable)
                rerender()
            }
        } else {
            commitMutation(actionName: "Clone Stamp") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                doc.layers[i].kind = .image(updatedSendable)
            }
        }
    }

    private func initializePerspectiveQuad() {
        guard let (layer, sendableImg) = targetImageLayer() else {
            perspectiveQuad = nil
            return
        }
        let w = sendableImg.size.width
        let h = sendableImg.size.height
        perspectiveQuad = PerspectiveQuad(
            topLeft: imagePointToCanvasPoint(CGPoint(x: 0, y: 0), for: layer, imageSize: sendableImg.size),
            topRight: imagePointToCanvasPoint(CGPoint(x: w, y: 0), for: layer, imageSize: sendableImg.size),
            bottomRight: imagePointToCanvasPoint(CGPoint(x: w, y: h), for: layer, imageSize: sendableImg.size),
            bottomLeft: imagePointToCanvasPoint(CGPoint(x: 0, y: h), for: layer, imageSize: sendableImg.size)
        )
    }

    public func beginPerspective() {
        guard targetImageLayer() != nil else { return }
        activeTool = .perspective
        initializePerspectiveQuad()
    }

    public func resetPerspective() {
        initializePerspectiveQuad()
    }

    public func cancelPerspective() {
        perspectiveQuad = nil
        if activeTool == .perspective {
            activeTool = .move
        }
    }

    public func applyPerspective() throws {
        guard let quad = perspectiveQuad,
              let (layer, sendableImg) = targetImageLayer() else {
            throw ImageToolError.invalidParameters
        }
        let imgSize = sendableImg.size
        let localQuad = PerspectiveQuad(
            topLeft: canvasPointToImagePoint(quad.topLeft, for: layer, imageSize: imgSize),
            topRight: canvasPointToImagePoint(quad.topRight, for: layer, imageSize: imgSize),
            bottomRight: canvasPointToImagePoint(quad.bottomRight, for: layer, imageSize: imgSize),
            bottomLeft: canvasPointToImagePoint(quad.bottomLeft, for: layer, imageSize: imgSize)
        )

        let rectified = try ImageTools.perspectiveCorrect(sendableImg.cgImage, quad: localQuad)
        let updatedSendable = SendableImage(
            rectified,
            filterPreset: sendableImg.filterPreset,
            adjustments: sendableImg.adjustments,
            frame: sendableImg.frame
        )

        perspectiveQuad = nil
        activeTool = .move
        commitMutation(actionName: "Perspective Correction") { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == layer.id }) else { return }
            doc.layers[i].kind = .image(updatedSendable)
            if doc.layers.count == 1 {
                let newSize = CGSize(width: rectified.width, height: rectified.height)
                doc.canvasSize = newSize
                doc.layers[i].transform = LayerTransform(position: CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0))
            }
        }
    }

    public func applyDeform(
        preset: DeformPreset,
        center canvasCenterPoint: CGPoint,
        radius: CGFloat,
        strength: CGFloat = 0.5,
        continuous: Bool = false
    ) throws {
        guard let (layer, sendableImg) = targetImageLayer() else {
            throw ImageToolError.invalidParameters
        }
        let imgSize = sendableImg.size
        let centerInImage = canvasPointToImagePoint(canvasCenterPoint, for: layer, imageSize: imgSize)
        let avgScale = max(0.01, (abs(layer.transform.scale.width) + abs(layer.transform.scale.height)) / 2.0)
        let imageRadius = max(1.0, radius / avgScale)

        let deformed = try ImageTools.deform(
            sendableImg.cgImage,
            preset: preset,
            center: centerInImage,
            radius: imageRadius,
            strength: strength
        )
        let updatedSendable = SendableImage(
            deformed,
            filterPreset: sendableImg.filterPreset,
            adjustments: sendableImg.adjustments,
            frame: sendableImg.frame
        )

        if continuous {
            beginContinuousEdit()
            if let i = document.layers.firstIndex(where: { $0.id == layer.id }) {
                document.layers[i].kind = .image(updatedSendable)
                rerender()
            }
        } else {
            commitMutation(actionName: "Deform (\(preset.rawValue.capitalized))") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                doc.layers[i].kind = .image(updatedSendable)
            }
        }
    }

    public func applyToneCurve(_ curve: ToneCurveSpec, to layerID: UUID) throws {
        guard let layer = document.layer(id: layerID), !layer.isLocked else {
            throw ImageToolError.invalidParameters
        }
        let sendableImg: SendableImage
        switch layer.kind {
        case .image(let img):
            sendableImg = img
        case .text, .shape, .sticker, .drawing:
            throw ImageToolError.invalidParameters
        default:
            throw ImageToolError.invalidParameters
        }

        let curved = try ImageTools.applyCurves(sendableImg.cgImage, curve: curve)
        let updatedSendable = SendableImage(
            curved,
            filterPreset: sendableImg.filterPreset,
            adjustments: sendableImg.adjustments,
            frame: sendableImg.frame
        )
        toneCurve = ToneCurveSpec()
        commitMutation(actionName: "Apply Tone Curve") { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == layerID }) else { return }
            doc.layers[i].kind = .image(updatedSendable)
        }
    }

    public func resizeDocument(to targetSize: CGSize, keepAspect: Bool) throws {
        guard let composite = renderComposite() else {
            throw ImageToolError.invalidDimensions
        }
        let resized = try ImageTools.resize(composite, to: targetSize, keepAspect: keepAspect)
        let newSize = CGSize(width: resized.width, height: resized.height)

        commitMutation(actionName: "Resize Image") { doc in
            doc.canvasSize = newSize
            let layer = Layer(
                name: title,
                kind: .image(SendableImage(resized)),
                transform: LayerTransform(position: CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0))
            )
            doc.layers = [layer]
            doc.selection = layer.id
        }
    }

    public func rotateDocument90(direction: RotationDirection) throws {
        guard let composite = renderComposite() else {
            throw ImageToolError.invalidDimensions
        }
        let rotated = try ImageTools.rotate90(composite, direction: direction)
        let newSize = CGSize(width: rotated.width, height: rotated.height)
        let actionName = direction == .left90 ? "Rotate 90° Left" : "Rotate 90° Right"

        commitMutation(actionName: actionName) { doc in
            doc.canvasSize = newSize
            let layer = Layer(
                name: title,
                kind: .image(SendableImage(rotated)),
                transform: LayerTransform(position: CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0))
            )
            doc.layers = [layer]
            doc.selection = layer.id
        }
    }

    public func flipDocument(axis: FlipAxis) throws {
        guard let composite = renderComposite() else {
            throw ImageToolError.invalidDimensions
        }
        let flipped = try ImageTools.flip(composite, axis: axis)
        let newSize = CGSize(width: flipped.width, height: flipped.height)
        let actionName = axis == .horizontal ? "Flip Horizontal" : "Flip Vertical"

        commitMutation(actionName: actionName) { doc in
            doc.canvasSize = newSize
            let layer = Layer(
                name: title,
                kind: .image(SendableImage(flipped)),
                transform: LayerTransform(position: CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0))
            )
            doc.layers = [layer]
            doc.selection = layer.id
        }
    }

    // MARK: - S18: Collage

    public func createCollage(
        layout: CollageLayout,
        images: [CGImage],
        canvasSize: CGSize = CGSize(width: 1200, height: 1200),
        background: CanvasBackground = .solid(.white),
        spacing: CGFloat = 12.0,
        cornerRadius: Double = 0.0
    ) throws {
        let collageDoc = try CollageBuilder.makeDocument(
            layout: layout,
            images: images,
            canvasSize: canvasSize,
            background: background,
            spacing: spacing,
            cornerRadius: cornerRadius
        )
        let previousDoc = document
        let previousTitle = title

        cropSpec = nil
        perspectiveQuad = nil
        lassoPoints = []
        liveTransformPreview = nil
        activeTool = .move
        document = collageDoc
        title = layout == .freeStyle ? "Free Style Canvas" : "Collage"
        projectURL = nil
        rerender()

        registerUndoSnapshot(
            previousDoc: previousDoc,
            previousTitle: previousTitle,
            actionName: "New Collage"
        )
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
        let name = StickerDisplayName.layerName(for: resolved.kind)
        commitMutation(actionName: "Add \(name)") { doc in
            let layer = Layer(
                name: name,
                kind: .shape(resolved),
                transform: LayerTransform(position: pos)
            )
            doc.add(layer)
        }
    }

    public func addStickerLayer(
        _ spec: StickerSpec,
        at position: CGPoint? = nil,
        background: RGBAColor? = nil
    ) {
        let pos = position ?? canvasCenter
        var resolvedSpec = spec
        if let background {
            resolvedSpec.background = background
        } else if resolvedSpec.background == nil {
            resolvedSpec.background = defaultStickerBackground
        }
        let name = StickerDisplayName.layerName(for: resolvedSpec)
        commitMutation(actionName: "Add Sticker") { doc in
            let layer = Layer(
                name: name,
                kind: .sticker(resolvedSpec),
                transform: LayerTransform(position: pos)
            )
            doc.add(layer)
        }
    }

    public func stickerBackground(for layerID: UUID) -> RGBAColor? {
        guard let layer = document.layer(id: layerID),
              case .sticker(let spec) = layer.kind else {
            return nil
        }
        return spec.background
    }

    public func setStickerBackground(_ color: RGBAColor?, for layerID: UUID, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked,
              case .sticker(var spec) = document.layers[idx].kind else { return }

        spec.background = color

        if continuous {
            beginContinuousEdit()
            document.layers[idx].kind = .sticker(spec)
            rerender()
        } else {
            commitMutation(actionName: "Change Sticker Background") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                      !doc.layers[i].isLocked,
                      case .sticker(var targetSpec) = doc.layers[i].kind else { return }
                targetSpec.background = color
                doc.layers[i].kind = .sticker(targetSpec)
            }
        }
    }

    /// Toggles sticker Solid Background ON/OFF using a high-contrast default color
    /// (black for light sticker tints, white for dark tints) when enabled.
    public func toggleStickerSolidBackground(enabled: Bool, for layerID: UUID?) {
        let activeTint: RGBAColor
        if let layerID,
           let layer = document.layer(id: layerID),
           case .sticker(let spec) = layer.kind {
            activeTint = spec.tintColor
        } else {
            activeTint = defaultStickerTint
        }

        let newColor: RGBAColor? = enabled ? StickerDisplayName.contrastingBackground(for: activeTint) : nil
        defaultStickerBackground = newColor
        if let layerID {
            setStickerBackground(newColor, for: layerID)
        }
    }

    /// S17: Records a drawing stroke as a native `LayerKind.drawing(DrawingSpec)` layer using `drawingToolKind`.
    public func commitBrushStroke(
        points: [CGPoint],
        color: RGBAColor,
        lineWidth: Double,
        tool: DrawingToolKind? = nil
    ) {
        guard !points.isEmpty else { return }
        let resolvedTool = tool ?? drawingToolKind
        let stroke = DrawingStroke(
            points: points,
            color: color,
            width: max(1.0, lineWidth),
            tool: resolvedTool
        )

        commitMutation(actionName: "Draw Stroke") { doc in
            if let selection = doc.selection,
               let idx = doc.layers.firstIndex(where: { $0.id == selection }),
               !doc.layers[idx].isLocked,
               doc.layers[idx].transform == LayerTransform(position: .zero),
               case .drawing(var existingSpec) = doc.layers[idx].kind {
                existingSpec.strokes.append(stroke)
                doc.layers[idx].kind = .drawing(existingSpec)
            } else {
                let layer = Layer(
                    name: "Drawing",
                    kind: .drawing(DrawingSpec(strokes: [stroke])),
                    transform: LayerTransform(position: .zero)
                )
                doc.add(layer)
            }
        }
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
            case .text, .shape, .sticker, .drawing:
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
            case .text, .shape, .sticker, .drawing:
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
                case .text, .shape, .sticker, .drawing:
                    break
                default:
                    break
                }
            }
        }
    }

    public func setImageFrame(_ frame: ImageFrame, for layerID: UUID, continuous: Bool = false) {
        guard let idx = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[idx].isLocked else { return }

        if continuous {
            beginContinuousEdit()
            switch document.layers[idx].kind {
            case .image(var img):
                img.frame = frame
                document.layers[idx].kind = .image(img)
                rerender()
            case .text, .shape, .sticker, .drawing:
                break
            default:
                break
            }
        } else {
            commitMutation(actionName: "Change Image Frame") { doc in
                guard let i = doc.layers.firstIndex(where: { $0.id == layerID }),
                      !doc.layers[i].isLocked else { return }
                switch doc.layers[i].kind {
                case .image(var img):
                    img.frame = frame
                    doc.layers[i].kind = .image(img)
                case .text, .shape, .sticker, .drawing:
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

    public func setCanvasBackground(_ background: CanvasBackground, continuous: Bool = false) {
        if case .solid(let color) = background {
            lastSolidCanvasBackgroundColor = color
        }
        if continuous {
            beginContinuousEdit()
            document.background = background
            rerender()
        } else {
            commitMutation(actionName: "Change Background") { doc in
                doc.background = background
            }
        }
    }

    // MARK: - Background Removal (Apple Vision SubjectLifter)

    public func removeBackgroundFromSelectedLayer() async {
        guard !isRemovingBackground else { return }
        guard let (layer, sendableImg) = targetImageLayer() else {
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
                guard let i = doc.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                let updated = SendableImage(
                    lifted,
                    filterPreset: sendableImg.filterPreset,
                    adjustments: sendableImg.adjustments,
                    frame: sendableImg.frame
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
        statusMessage = "Exported \(url.lastPathComponent)"
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
                let padW: CGFloat = spec.bubble == .none ? 16 : 36
                let padH: CGFloat = spec.bubble == .none ? 12 : 28
                return CGSize(width: max(40, w + padW), height: max(28, h + padH))
            }
            return CGSize(width: 120, height: 40)
        case .sticker(let spec):
            return DocumentRenderer.stickerLogicalSize(for: spec)
        case .drawing(let spec):
            let allPts = spec.strokes.flatMap(\.points)
            guard let first = allPts.first else { return document.canvasSize }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for pt in allPts {
                minX = min(minX, pt.x); maxX = max(maxX, pt.x)
                minY = min(minY, pt.y); maxY = max(maxY, pt.y)
            }
            return CGSize(width: max(32, maxX - minX + 24), height: max(32, maxY - minY + 24))
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
            case .triangle: return "triangle"
            case .star: return "star"
            default: return "square.on.circle"
            }
        case .sticker(let spec):
            switch spec.content {
            case .emoji: return "face.smiling"
            case .sfSymbol(let name): return name
            }
        case .drawing:
            return "paintbrush.pointed"
        default:
            return "square.stack.3d.up"
        }
    }
}
