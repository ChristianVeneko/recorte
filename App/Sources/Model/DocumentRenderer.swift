import AppKit
import CoreGraphics
import CoreText
import Foundation
import RecorteCore

// MARK: - Human-Readable Names for Stickers & Shapes (S20)

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
}

// MARK: - Live GPU Transform Split (S24 60fps)

public struct LiveTransformSplit: Sendable {
    public let underlay: CGImage?
    public let activeLayerImage: CGImage
    public let overlay: CGImage?
}

// MARK: - App-Side Document Renderer (S20 SF Symbols + S21 Sticker Backgrounds)

public enum DocumentRenderer {

    /// Logical bounding size of a sticker layer in canvas points.
    public static func stickerLogicalSize(for spec: StickerSpec, hasBackground: Bool) -> CGSize {
        let multiplier: CGFloat = hasBackground ? 1.45 : 1.25
        let dim = max(32.0, ceil(CGFloat(spec.pointSize) * multiplier))
        return CGSize(width: dim, height: dim)
    }

    /// Renders a single sticker (SF Symbol or Emoji) with an optional solid rounded-rect background into a crisp `CGImage`.
    public static func rasterizeSticker(
        _ spec: StickerSpec,
        backgroundColor: RGBAColor?,
        rasterScale: CGFloat = 2.0
    ) -> CGImage? {
        let scale = max(1.0, rasterScale)
        let logicalSize = stickerLogicalSize(for: spec, hasBackground: backgroundColor != nil)
        let pixelW = max(2, Int((logicalSize.width * scale).rounded(.up)))
        let pixelH = max(2, Int((logicalSize.height * scale).rounded(.up)))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))
        ctx.clear(fullRect)
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // 1. Optional solid rounded background badge (S21)
        if let bg = backgroundColor {
            let cornerRadius = min(fullRect.width, fullRect.height) * 0.22
            let bgPath = CGPath(roundedRect: fullRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.saveGState()
            ctx.addPath(bgPath)
            ctx.setFillColor(bg.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Sticker content
        let paddingFraction: CGFloat = backgroundColor != nil ? 0.17 : 0.08
        let insetX = fullRect.width * paddingFraction
        let insetY = fullRect.height * paddingFraction
        let contentRect = fullRect.insetBy(dx: insetX, dy: insetY)

        switch spec.content {
        case .sfSymbol(let symbolName):
            drawSFSymbol(symbolName, tintColor: spec.tintColor, pointSize: CGFloat(spec.pointSize) * scale, in: contentRect, ctx: ctx)
        case .emoji(let emoji):
            drawEmoji(emoji, pointSize: CGFloat(spec.pointSize) * scale, in: contentRect, ctx: ctx)
        }

        return ctx.makeImage()
    }

    private static func drawSFSymbol(
        _ symbolName: String,
        tintColor: RGBAColor,
        pointSize: CGFloat,
        in contentRect: CGRect,
        ctx: CGContext
    ) {
        let config = NSImage.SymbolConfiguration(pointSize: max(12, pointSize), weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil),
              let configured = baseImage.withSymbolConfiguration(config) else {
            return
        }

        var proposedRect = NSRect(origin: .zero, size: configured.size)
        guard let maskCG = configured.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return
        }

        let maskW = max(1.0, CGFloat(maskCG.width))
        let maskH = max(1.0, CGFloat(maskCG.height))
        let fitScale = min(contentRect.width / maskW, contentRect.height / maskH)
        let drawW = maskW * fitScale
        let drawH = maskH * fitScale
        let drawRect = CGRect(
            x: contentRect.midX - drawW / 2.0,
            y: contentRect.midY - drawH / 2.0,
            width: drawW,
            height: drawH
        )

        // CGContext is unflipped (bottom-left origin), matching CGContext.clip(to:mask:) upright orientation.
        ctx.saveGState()
        ctx.clip(to: drawRect, mask: maskCG)
        ctx.setFillColor(tintColor.cgColor)
        ctx.fill(drawRect)
        ctx.restoreGState()
    }

    private static func drawEmoji(
        _ emoji: String,
        pointSize: CGFloat,
        in contentRect: CGRect,
        ctx: CGContext
    ) {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, max(12, pointSize), nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        guard let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, emoji as CFString, attrs as CFDictionary) else {
            return
        }
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineW = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let lineH = max(1, ascent + descent)

        let fitScale = min(1.0, min(contentRect.width / max(1, lineW), contentRect.height / lineH))

        ctx.saveGState()
        ctx.translateBy(x: contentRect.midX, y: contentRect.midY)
        ctx.scaleBy(x: fitScale, y: fitScale)
        ctx.textMatrix = .identity
        let originX = -lineW / 2.0
        let baselineY = -(ascent - descent) / 2.0
        ctx.textPosition = CGPoint(x: originX, y: baselineY)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    /// Produces a render-ready copy of `document` where SF Symbol stickers and stickers with solid backgrounds
    /// are pre-rasterized into crisp image layers so `RecorteCore.Renderer` and `RecorteProject.exportPDF` render them faithfully.
    public static func prepareForRendering(
        _ document: EditorDocument,
        stickerBackgrounds: [UUID: RGBAColor],
        rasterScale: CGFloat = 2.0
    ) -> EditorDocument {
        var prepared = document
        let scale = max(1.0, rasterScale)

        for idx in prepared.layers.indices {
            let layer = prepared.layers[idx]
            guard case .sticker(let spec) = layer.kind else { continue }
            let bg = stickerBackgrounds[layer.id]
            let needsAppRasterization: Bool = switch spec.content {
            case .sfSymbol: true
            case .emoji: bg != nil
            }
            guard needsAppRasterization,
                  let cgImage = rasterizeSticker(spec, backgroundColor: bg, rasterScale: scale) else {
                continue
            }

            var updatedLayer = layer
            updatedLayer.kind = .image(SendableImage(cgImage))
            updatedLayer.transform.scale = CGSize(
                width: layer.transform.scale.width / scale,
                height: layer.transform.scale.height / scale
            )
            prepared.layers[idx] = updatedLayer
        }
        return prepared
    }

    /// Renders `document` using App-side sticker rasterization + `RecorteCore.Renderer`.
    public static func render(
        _ document: EditorDocument,
        stickerBackgrounds: [UUID: RGBAColor] = [:],
        scale: CGFloat = 1.0
    ) throws -> CGImage {
        let prepared = prepareForRendering(document, stickerBackgrounds: stickerBackgrounds)
        return try Renderer.render(prepared, scale: scale)
    }

    /// Renders a one-time split (underlay, active layer, overlay) so interactive transform gestures
    /// can transform `activeLayerImage` on the GPU at 60–120fps without re-rendering per frame.
    public static func renderLiveTransformSplit(
        _ document: EditorDocument,
        activeLayerID: UUID,
        stickerBackgrounds: [UUID: RGBAColor]
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
            underlay = try? render(underlayDoc, stickerBackgrounds: stickerBackgrounds, scale: 1.0)
        } else {
            underlay = nil
        }

        let activeDoc = EditorDocument(
            canvasSize: document.canvasSize,
            background: .transparent,
            layers: [activeLayer],
            selection: nil
        )
        guard let activeImage = try? render(activeDoc, stickerBackgrounds: stickerBackgrounds, scale: 1.0) else {
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
            overlay = try? render(overlayDoc, stickerBackgrounds: stickerBackgrounds, scale: 1.0)
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
