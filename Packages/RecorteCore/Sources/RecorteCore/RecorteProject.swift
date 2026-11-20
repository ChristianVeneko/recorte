import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum RecorteProjectError: Error, Sendable, Equatable {
    case invalidPackageURL
    case missingManifest
    case missingAsset(String)
    case imageEncodingFailed
    case imageDecodingFailed
    case pdfCreationFailed
    case ioFailed(String)
}

/// Codable representation of a layer kind inside `document.json`.
public enum SerializedLayerKind: Sendable, Equatable, Codable {
    case image(
        assetPath: String,
        filterPreset: FilterPreset,
        adjustments: Adjustments,
        frame: ImageFrame
    )
    case text(TextSpec)
    case shape(ShapeSpec)
    case sticker(StickerSpec)
    case drawing(DrawingSpec)
}

/// Codable representation of a single layer inside `document.json`.
public struct SerializedLayer: Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var kind: SerializedLayerKind
    public var transform: LayerTransform
    public var opacity: Double
    public var isHidden: Bool
    public var isLocked: Bool
    /// Optional relative path to an 8-bit grayscale alpha mask PNG inside `assets/`.
    public var alphaMaskPath: String?

    public init(
        id: UUID,
        name: String,
        kind: SerializedLayerKind,
        transform: LayerTransform,
        opacity: Double,
        isHidden: Bool,
        isLocked: Bool,
        alphaMaskPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.transform = transform
        self.opacity = opacity
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.alphaMaskPath = alphaMaskPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, transform, opacity, isHidden, isLocked, alphaMaskPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(SerializedLayerKind.self, forKey: .kind)
        self.transform = try c.decode(LayerTransform.self, forKey: .transform)
        self.opacity = try c.decode(Double.self, forKey: .opacity)
        self.isHidden = try c.decode(Bool.self, forKey: .isHidden)
        self.isLocked = try c.decode(Bool.self, forKey: .isLocked)
        self.alphaMaskPath = try c.decodeIfPresent(String.self, forKey: .alphaMaskPath)
    }
}

/// Codable JSON manifest stored as `document.json` inside a `.recorte` package directory.
public struct RecorteProjectManifest: Sendable, Equatable, Codable {
    public var version: Int
    public var canvasSize: CGSize
    public var background: CanvasBackground
    public var layers: [SerializedLayer]
    public var selection: UUID?

    public init(
        version: Int = RecorteProject.currentFormatVersion,
        canvasSize: CGSize,
        background: CanvasBackground,
        layers: [SerializedLayer],
        selection: UUID?
    ) {
        self.version = version
        self.canvasSize = canvasSize
        self.background = background
        self.layers = layers
        self.selection = selection
    }
}

/// Editable `.recorte` package persistence (document.json + PNG asset per image layer) and PDF export.
public struct RecorteProject: Sendable, Equatable {
    public static let fileExtension = "recorte"
    public static let manifestFilename = "document.json"
    public static let assetsDirectoryName = "assets"
    public static let currentFormatVersion = 1

    public var document: EditorDocument

    public init(document: EditorDocument) {
        self.document = document
    }

    /// Saves `self.document` to a `.recorte` package directory at `url`.
    public func save(to url: URL) throws {
        try Self.save(document, to: url)
    }

    /// Saves `document` as a `.recorte` package directory containing `document.json`
    /// and one lossless PNG asset per image layer under `assets/`.
    public static func save(_ document: EditorDocument, to url: URL) throws {
        let fm = FileManager.default
        guard url.isFileURL else {
            throw RecorteProjectError.invalidPackageURL
        }

        // Ensure package directory and assets/ directory exist
        let assetsDir = url.appendingPathComponent(assetsDirectoryName, isDirectory: true)
        do {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        } catch {
            throw RecorteProjectError.ioFailed(error.localizedDescription)
        }

        var serializedLayers: [SerializedLayer] = []
        serializedLayers.reserveCapacity(document.layers.count)
        var writtenAssetFilenames = Set<String>()

        for layer in document.layers {
            let serializedKind: SerializedLayerKind
            var maskRelativePath: String? = nil
            switch layer.kind {
            case .image(let sendableImg):
                let filename = "\(layer.id.uuidString).png"
                let relativePath = "\(assetsDirectoryName)/\(filename)"
                let assetURL = assetsDir.appendingPathComponent(filename)
                try writePNG(sendableImg.cgImage, to: assetURL)
                writtenAssetFilenames.insert(filename)
                if let mask = sendableImg.alphaMask {
                    let maskFilename = "\(layer.id.uuidString)-mask.png"
                    let maskURL = assetsDir.appendingPathComponent(maskFilename)
                    try writePNG(mask, to: maskURL)
                    writtenAssetFilenames.insert(maskFilename)
                    maskRelativePath = "\(assetsDirectoryName)/\(maskFilename)"
                }
                serializedKind = .image(
                    assetPath: relativePath,
                    filterPreset: sendableImg.filterPreset,
                    adjustments: sendableImg.adjustments,
                    frame: sendableImg.frame
                )
            case .text(let spec):
                serializedKind = .text(spec)
            case .shape(let spec):
                serializedKind = .shape(spec)
            case .sticker(let spec):
                serializedKind = .sticker(spec)
            case .drawing(let spec):
                serializedKind = .drawing(spec)
            }

            serializedLayers.append(SerializedLayer(
                id: layer.id,
                name: layer.name,
                kind: serializedKind,
                transform: layer.transform,
                opacity: layer.opacity,
                isHidden: layer.isHidden,
                isLocked: layer.isLocked,
                alphaMaskPath: maskRelativePath
            ))
        }

        // Remove any stale PNG files left over from a previous save to the same package
        if let existing = try? fm.contentsOfDirectory(atPath: assetsDir.path) {
            for name in existing where name.hasSuffix(".png") && !writtenAssetFilenames.contains(name) {
                try? fm.removeItem(at: assetsDir.appendingPathComponent(name))
            }
        }

        let manifest = RecorteProjectManifest(
            version: currentFormatVersion,
            canvasSize: document.canvasSize,
            background: document.background,
            layers: serializedLayers,
            selection: document.selection
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = url.appendingPathComponent(manifestFilename)
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw RecorteProjectError.ioFailed(error.localizedDescription)
        }
    }

    /// Loads an `EditorDocument` from a `.recorte` package directory at `url`.
    public static func load(from url: URL) throws -> EditorDocument {
        let fm = FileManager.default
        guard url.isFileURL else {
            throw RecorteProjectError.invalidPackageURL
        }

        let manifestURL = url.appendingPathComponent(manifestFilename)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw RecorteProjectError.missingManifest
        }

        let manifest: RecorteProjectManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(RecorteProjectManifest.self, from: data)
        } catch {
            throw RecorteProjectError.ioFailed(error.localizedDescription)
        }

        var layers: [Layer] = []
        layers.reserveCapacity(manifest.layers.count)

        for serialized in manifest.layers {
            let kind: LayerKind
            switch serialized.kind {
            case .image(let assetPath, let filterPreset, let adjustments, let frame):
                let assetURL = url.appendingPathComponent(assetPath)
                guard fm.fileExists(atPath: assetURL.path) else {
                    throw RecorteProjectError.missingAsset(assetPath)
                }
                let cgImage = try readPNG(from: assetURL)
                var loadedMask: CGImage? = nil
                if let maskPath = serialized.alphaMaskPath {
                    let maskURL = url.appendingPathComponent(maskPath)
                    guard fm.fileExists(atPath: maskURL.path) else {
                        throw RecorteProjectError.missingAsset(maskPath)
                    }
                    loadedMask = try readPNG(from: maskURL)
                }
                kind = .image(SendableImage(
                    cgImage,
                    filterPreset: filterPreset,
                    adjustments: adjustments,
                    frame: frame,
                    alphaMask: loadedMask
                ))
            case .text(let spec):
                kind = .text(spec)
            case .shape(let spec):
                kind = .shape(spec)
            case .sticker(let spec):
                kind = .sticker(spec)
            case .drawing(let spec):
                kind = .drawing(spec)
            }

            layers.append(Layer(
                id: serialized.id,
                name: serialized.name,
                kind: kind,
                transform: serialized.transform,
                opacity: serialized.opacity,
                isHidden: serialized.isHidden,
                isLocked: serialized.isLocked
            ))
        }

        return EditorDocument(
            canvasSize: manifest.canvasSize,
            background: manifest.background,
            layers: layers,
            selection: manifest.selection
        )
    }

    /// Loads a `RecorteProject` wrapper from a `.recorte` package directory at `url`.
    public static func loadProject(from url: URL) throws -> RecorteProject {
        RecorteProject(document: try load(from: url))
    }

    // MARK: - PDF Export

    /// Renders `document` and exports it as a single-page PDF in memory.
    public static func exportPDFData(_ document: EditorDocument, scale: CGFloat = 1.0) throws -> Data {
        let rendered = try Renderer.render(document, scale: scale)
        let pageBounds = CGRect(origin: .zero, size: document.canvasSize)
        var mediaBox = pageBounds

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RecorteProjectError.pdfCreationFailed
        }

        pdfContext.beginPDFPage(nil)
        // Standard PDF context is unflipped (bottom-left origin), so CGContext.draw renders rendered CGImage upright
        pdfContext.draw(rendered, in: pageBounds)
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        let data = mutableData as Data
        guard !data.isEmpty else {
            throw RecorteProjectError.pdfCreationFailed
        }
        return data
    }

    /// Renders `document` and writes a single-page PDF file to `url`.
    public static func exportPDF(_ document: EditorDocument, to url: URL, scale: CGFloat = 1.0) throws {
        let data = try exportPDFData(document, scale: scale)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw RecorteProjectError.ioFailed(error.localizedDescription)
        }
    }

    // MARK: - PNG Asset Helpers

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RecorteProjectError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RecorteProjectError.imageEncodingFailed
        }
    }

    private static func readPNG(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RecorteProjectError.imageDecodingFailed
        }
        return image
    }
}
