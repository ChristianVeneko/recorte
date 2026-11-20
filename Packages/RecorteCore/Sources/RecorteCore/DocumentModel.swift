import Foundation
import CoreGraphics

// MARK: - Color & Image Wrappers

/// A Sendable, Equatable RGBA color in sRGB (components 0.0...1.0).
public struct RGBAColor: Sendable, Equatable, Hashable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    public static let black = RGBAColor(r: 0, g: 0, b: 0, a: 1)
    public static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    public static let red = RGBAColor(r: 1, g: 0, b: 0, a: 1)
    public static let green = RGBAColor(r: 0, g: 1, b: 0, a: 1)
    public static let blue = RGBAColor(r: 0, g: 0, b: 1, a: 1)
    public static let yellow = RGBAColor(r: 1, g: 1, b: 0, a: 1)
}

/// A thread-safe Sendable value wrapper around `CGImage` (which is immutable).
public struct SendableImage: @unchecked Sendable, Equatable {
    public let cgImage: CGImage
    public var filterPreset: FilterPreset
    public var adjustments: Adjustments

    public init(
        _ cgImage: CGImage,
        filterPreset: FilterPreset = .none,
        adjustments: Adjustments = Adjustments()
    ) {
        self.cgImage = cgImage
        self.filterPreset = filterPreset
        self.adjustments = adjustments
    }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }
    public var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    public static func == (lhs: SendableImage, rhs: SendableImage) -> Bool {
        lhs.cgImage === rhs.cgImage &&
        lhs.filterPreset == rhs.filterPreset &&
        lhs.adjustments == rhs.adjustments
    }
}

// MARK: - Specs for Text, Shape, Sticker

public enum TextAlignmentSpec: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case left
    case center
    case right
}

public struct TextStrokeSpec: Sendable, Equatable, Hashable, Codable {
    public var color: RGBAColor
    public var width: Double

    public init(color: RGBAColor = .black, width: Double = 2.0) {
        self.color = color
        self.width = width
    }
}

public struct TextSpec: Sendable, Equatable, Hashable, Codable {
    public var string: String
    public var fontName: String
    public var size: Double
    public var color: RGBAColor
    public var alignment: TextAlignmentSpec
    public var stroke: TextStrokeSpec?
    public var background: RGBAColor?

    public init(
        string: String,
        fontName: String = "HelveticaNeue-Bold",
        size: Double = 32.0,
        color: RGBAColor = .white,
        alignment: TextAlignmentSpec = .center,
        stroke: TextStrokeSpec? = nil,
        background: RGBAColor? = nil
    ) {
        self.string = string
        self.fontName = fontName
        self.size = size
        self.color = color
        self.alignment = alignment
        self.stroke = stroke
        self.background = background
    }
}

public enum ShapeKind: Sendable, Equatable, Hashable, Codable {
    case rect
    case roundedRect(cornerRadius: Double = 12.0)
    case ellipse
    case line
    case arrow
}

public struct ShapeSpec: Sendable, Equatable, Hashable, Codable {
    public var kind: ShapeKind
    public var size: CGSize
    public var strokeColor: RGBAColor?
    public var fillColor: RGBAColor?
    public var lineWidth: Double

    public init(
        kind: ShapeKind,
        size: CGSize = CGSize(width: 160, height: 120),
        strokeColor: RGBAColor? = .red,
        fillColor: RGBAColor? = nil,
        lineWidth: Double = 3.0
    ) {
        self.kind = kind
        self.size = size
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
    }
}

public enum StickerContent: Sendable, Equatable, Hashable, Codable {
    case emoji(String)
    case sfSymbol(String)
}

public struct StickerSpec: Sendable, Equatable, Hashable, Codable {
    public var content: StickerContent
    public var pointSize: Double
    public var tintColor: RGBAColor

    public init(
        content: StickerContent,
        pointSize: Double = 64.0,
        tintColor: RGBAColor = .white
    ) {
        self.content = content
        self.pointSize = pointSize
        self.tintColor = tintColor
    }

    public static func emoji(_ value: String, pointSize: Double = 64.0) -> StickerSpec {
        StickerSpec(content: .emoji(value), pointSize: pointSize)
    }

    public static func sfSymbol(_ name: String, pointSize: Double = 64.0, tintColor: RGBAColor = .white) -> StickerSpec {
        StickerSpec(content: .sfSymbol(name), pointSize: pointSize, tintColor: tintColor)
    }
}

// MARK: - Layer & Document Model

public enum LayerKind: Sendable, Equatable {
    case image(SendableImage)
    case text(TextSpec)
    case shape(ShapeSpec)
    case sticker(StickerSpec)
}

public struct LayerTransform: Sendable, Equatable, Hashable, Codable {
    public var position: CGPoint
    public var scale: CGSize
    public var rotationDegrees: Double

    public var rotation: Double {
        get { rotationDegrees }
        set { rotationDegrees = newValue }
    }

    public init(
        position: CGPoint = .zero,
        scale: CGSize = CGSize(width: 1.0, height: 1.0),
        rotationDegrees: Double = 0.0
    ) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
    }

    public init(
        position: CGPoint = .zero,
        scale uniformScale: Double,
        rotationDegrees: Double = 0.0
    ) {
        self.position = position
        self.scale = CGSize(width: uniformScale, height: uniformScale)
        self.rotationDegrees = rotationDegrees
    }

    public init(
        position: CGPoint = .zero,
        scale uniformScale: Double,
        rotation: Double
    ) {
        self.position = position
        self.scale = CGSize(width: uniformScale, height: uniformScale)
        self.rotationDegrees = rotation
    }
}

public struct Layer: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: LayerKind
    public var transform: LayerTransform
    public var opacity: Double
    public var isHidden: Bool
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: LayerKind,
        transform: LayerTransform = LayerTransform(),
        opacity: Double = 1.0,
        isHidden: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.transform = transform
        self.opacity = min(max(opacity, 0.0), 1.0)
        self.isHidden = isHidden
        self.isLocked = isLocked
    }
}

public enum CanvasBackground: Sendable, Equatable, Hashable, Codable {
    case transparent
    case solid(RGBAColor)
}

public struct EditorDocument: Sendable, Equatable {
    public var canvasSize: CGSize
    public var background: CanvasBackground
    public var layers: [Layer]
    public var selection: UUID?

    public init(
        canvasSize: CGSize = CGSize(width: 1200, height: 800),
        background: CanvasBackground = .transparent,
        layers: [Layer] = [],
        selection: UUID? = nil
    ) {
        self.canvasSize = canvasSize
        self.background = background
        self.layers = layers
        self.selection = selection
    }

    public func layer(id: UUID) -> Layer? {
        layers.first(where: { $0.id == id })
    }

    // MARK: Mutating Layer Operations

    /// Adds a layer to the top of the stack and selects it.
    public mutating func add(_ layer: Layer) {
        layers.append(layer)
        selection = layer.id
    }

    /// Removes the layer with the given ID. Updates selection if needed.
    public mutating func remove(id: UUID) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers.remove(at: idx)
        if selection == id {
            selection = layers.last?.id
        }
    }

    /// Duplicates the layer with the given ID, inserts it directly above, selects and returns it.
    @discardableResult
    public mutating func duplicate(id: UUID) -> Layer? {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = layers[idx]
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        layers.insert(copy, at: idx + 1)
        selection = copy.id
        return copy
    }

    /// Reorders (moves) a layer from `sourceIndex` to `destinationIndex`.
    public mutating func reorder(from sourceIndex: Int, to destinationIndex: Int) {
        guard layers.indices.contains(sourceIndex),
              (0..<layers.count).contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let item = layers.remove(at: sourceIndex)
        layers.insert(item, at: destinationIndex)
    }

    /// Moves a layer by ID to a new index.
    public mutating func move(id: UUID, to destinationIndex: Int) {
        guard let sourceIndex = layers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(destinationIndex, 0), max(layers.count - 1, 0))
        reorder(from: sourceIndex, to: clamped)
    }

    /// Sets visibility (`isHidden`) for a layer by ID.
    public mutating func setVisibility(id: UUID, isHidden: Bool) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].isHidden = isHidden
    }

    /// Sets lock state (`isLocked`) for a layer by ID.
    public mutating func setLock(id: UUID, isLocked: Bool) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].isLocked = isLocked
    }

    /// Sets opacity (clamped to `0.0...1.0`) for a layer by ID.
    public mutating func setOpacity(id: UUID, opacity: Double) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].opacity = min(max(opacity, 0.0), 1.0)
    }
}
