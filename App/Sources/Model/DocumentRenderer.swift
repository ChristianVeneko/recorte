import CoreGraphics
import Foundation
import RecorteCore

// MARK: - Human-Readable Names & Contrasting Defaults for Stickers & Shapes (S20, S21)

public enum StickerDisplayName {

    private static let sfSymbolLabels: [String: String] = [
        "star.fill": "Star",
        "heart.fill": "Heart",
        "bolt.fill": "Lightning",
        "flame.fill": "Flame",
        "sparkles": "Sparkles",
        "checkmark.seal.fill": "Verified",
        "checkmark.circle.fill": "Checkmark",
        "xmark.octagon.fill": "Stop",
        "exclamationmark.triangle.fill": "Warning",
        "questionmark.circle.fill": "Question",
        "arrow.up.right.circle.fill": "Arrow Up Right",
        "arrow.right.circle.fill": "Arrow Right",
        "hand.thumbsup.fill": "Thumbs Up",
        "eye.fill": "Eye",
        "pin.fill": "Pin",
        "tag.fill": "Tag",
        "flag.fill": "Flag",
        "bell.fill": "Bell",
        "bookmark.fill": "Bookmark",
        "camera.fill": "Camera",
        "paintbrush.fill": "Paintbrush",
        "wand.and.stars": "Magic Wand",
        "crop": "Crop",
        "paperplane.fill": "Paper Plane",
        "lock.fill": "Lock",
        "shield.fill": "Shield",
        "crown.fill": "Crown",
        "trophy.fill": "Trophy",
        "gift.fill": "Gift",
        "bubble.left.and.bubble.right.fill": "Chat Bubbles"
    ]

    private static let droppedSuffixTokens: Set<String> = [
        "fill", "circle", "square", "rectangle", "badge", "slash"
    ]

    /// Converts an SF Symbol identifier (e.g. `"star.fill"`) into a clean, human-readable title (e.g. `"Star"`).
    public static func humanName(for symbolName: String) -> String {
        let normalized = symbolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = sfSymbolLabels[normalized] {
            return mapped
        }

        let rawTokens = normalized
            .replacingOccurrences(of: "_", with: ".")
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }

        var kept = rawTokens.filter { !droppedSuffixTokens.contains($0) }
        if kept.isEmpty {
            kept = rawTokens
        }
        let words = kept.map { token -> String in
            token.prefix(1).uppercased() + token.dropFirst()
        }
        let result = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Icon" : result
    }

    /// Human-readable layer name for a sticker (e.g. `"Star sticker"`, `"Sticker 🔥"`).
    public static func layerName(for spec: StickerSpec) -> String {
        switch spec.content {
        case .emoji(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Emoji sticker" : "Sticker \(trimmed)"
        case .sfSymbol(let symbol):
            return "\(humanName(for: symbol)) sticker"
        }
    }

    /// Human-readable layer name for a shape (e.g. `"Rectangle"`, `"Star"`).
    public static func layerName(for kind: ShapeKind) -> String {
        switch kind {
        case .rect: "Rectangle"
        case .roundedRect: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .triangle: "Triangle"
        case .star: "Star"
        @unknown default: "Shape"
        }
    }

    /// Returns a high-contrast default solid background for a sticker tint:
    /// `.black` for light tints (luminance >= 0.55) and `.white` for dark tints.
    public static func contrastingBackground(for tint: RGBAColor) -> RGBAColor {
        let luminance = 0.299 * tint.r + 0.587 * tint.g + 0.114 * tint.b
        return luminance >= 0.55 ? .black : .white
    }
}

// MARK: - Live GPU Transform Split (S24 60fps)

public struct LiveTransformSplit: Sendable {
    public let underlay: CGImage?
    public let activeLayerImage: CGImage
    public let overlay: CGImage?
}

// MARK: - App-Side Document Renderer Helpers

public enum DocumentRenderer {

    /// Logical bounding size of a sticker layer in canvas points.
    public static func stickerLogicalSize(for spec: StickerSpec) -> CGSize {
        let multiplier: CGFloat = spec.background != nil ? 1.45 : 1.25
        let dim = max(32.0, ceil(CGFloat(spec.pointSize) * multiplier))
        return CGSize(width: dim, height: dim)
    }

    /// Renders `document` via `RecorteCore.Renderer`.
    public static func render(
        _ document: EditorDocument,
        scale: CGFloat = 1.0
    ) throws -> CGImage {
        try Renderer.render(document, scale: scale)
    }

    /// Renders a one-time split (underlay, active layer, overlay) so interactive transform gestures
    /// can transform `activeLayerImage` on the GPU at 60–120fps without re-rendering per frame.
    public static func renderLiveTransformSplit(
        _ document: EditorDocument,
        activeLayerID: UUID
    ) -> LiveTransformSplit? {
        guard let activeIndex = document.layers.firstIndex(where: { $0.id == activeLayerID }) else {
            return nil
        }

        let belowLayers = Array(document.layers[..<activeIndex])
        let activeLayer = document.layers[activeIndex]
        let aboveLayers = activeIndex + 1 < document.layers.count
            ? Array(document.layers[(activeIndex + 1)...])
            : []

        let underlay: CGImage?
        if !belowLayers.isEmpty || document.background != .transparent {
            let underlayDoc = EditorDocument(
                canvasSize: document.canvasSize,
                background: document.background,
                layers: belowLayers,
                selection: nil
            )
            underlay = try? render(underlayDoc, scale: 1.0)
        } else {
            underlay = nil
        }

        let activeDoc = EditorDocument(
            canvasSize: document.canvasSize,
            background: .transparent,
            layers: [activeLayer],
            selection: nil
        )
        guard let activeImage = try? render(activeDoc, scale: 1.0) else {
            return nil
        }

        let overlay: CGImage?
        if !aboveLayers.isEmpty {
            let overlayDoc = EditorDocument(
                canvasSize: document.canvasSize,
                background: .transparent,
                layers: aboveLayers,
                selection: nil
            )
            overlay = try? render(overlayDoc, scale: 1.0)
        } else {
            overlay = nil
        }

        return LiveTransformSplit(
            underlay: underlay,
            activeLayerImage: activeImage,
            overlay: overlay
        )
    }
}
