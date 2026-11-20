import Foundation
import CoreGraphics
import CoreText

public enum RenderError: Error, Sendable, Equatable {
    case invalidCanvasSize
    case contextCreationFailed
    case imageCreationFailed
}

public enum Renderer {

    /// Renders `document` at `scale` into a `CGImage`, compositing all visible layers in order
    /// with their transforms and opacity using CoreGraphics and CoreText.
    public static func render(_ document: EditorDocument, _ scale: CGFloat) throws -> CGImage {
        try render(document, scale: scale)
    }

    /// Renders `document` at `scale` into a `CGImage`, compositing all visible layers in order
    /// with their transforms and opacity using CoreGraphics and CoreText.
    public static func render(_ document: EditorDocument, scale: CGFloat = 1.0) throws -> CGImage {
        let effectiveScale = max(scale, 0.01)
        let pixelW = Int((document.canvasSize.width * effectiveScale).rounded())
        let pixelH = Int((document.canvasSize.height * effectiveScale).rounded())
        guard pixelW > 0, pixelH > 0 else {
            throw RenderError.invalidCanvasSize
        }

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
            throw RenderError.contextCreationFailed
        }

        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))
        ctx.clear(fullRect)

        // Work in logical canvas coordinates by scaling context
        ctx.saveGState()
        ctx.scaleBy(x: effectiveScale, y: effectiveScale)

        let canvasRect = CGRect(origin: .zero, size: document.canvasSize)

        // 1. Draw Background
        switch document.background {
        case .transparent:
            break
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(canvasRect)
        }

        // 2. Draw visible layers in stack order (bottom to top)
        for layer in document.layers where !layer.isHidden && layer.opacity > 0.0 {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(layer.opacity))

            // Apply layer transform around layer.transform.position
            ctx.translateBy(x: layer.transform.position.x, y: layer.transform.position.y)
            if layer.transform.rotationDegrees != 0 {
                let rad = CGFloat(layer.transform.rotationDegrees) * .pi / 180.0
                ctx.rotate(by: rad)
            }
            ctx.scaleBy(x: layer.transform.scale.width, y: layer.transform.scale.height)

            switch layer.kind {
            case .image(let sendableImg):
                drawImageLayer(sendableImg, in: ctx)
            case .shape(let shapeSpec):
                drawShapeLayer(shapeSpec, in: ctx)
            case .text(let textSpec):
                drawTextLayer(textSpec, in: ctx)
            case .sticker(let stickerSpec):
                drawStickerLayer(stickerSpec, in: ctx)
            }

            ctx.restoreGState()
        }

        ctx.restoreGState()

        guard let output = ctx.makeImage() else {
            throw RenderError.imageCreationFailed
        }
        return output
    }

    private static func drawImageLayer(_ sendableImg: SendableImage, in ctx: CGContext) {
        let imgToDraw: CGImage
        if sendableImg.filterPreset != .none || !sendableImg.adjustments.isIdentity {
            imgToDraw = (try? ImageFilters.apply(
                to: sendableImg.cgImage,
                preset: sendableImg.filterPreset,
                adjustments: sendableImg.adjustments
            )) ?? sendableImg.cgImage
        } else {
            imgToDraw = sendableImg.cgImage
        }

        let w = CGFloat(imgToDraw.width)
        let h = CGFloat(imgToDraw.height)
        let localRect = CGRect(x: -w / 2.0, y: -h / 2.0, width: w, height: h)
        ctx.draw(imgToDraw, in: localRect)
    }

    private static func drawShapeLayer(_ spec: ShapeSpec, in ctx: CGContext) {
        let w = spec.size.width
        let h = spec.size.height
        let localRect = CGRect(x: -w / 2.0, y: -h / 2.0, width: w, height: h)

        let path = CGMutablePath()
        switch spec.kind {
        case .rect:
            path.addRect(localRect)
        case .roundedRect(let radius):
            let r = min(CGFloat(radius), min(w, h) / 2.0)
            path.addRoundedRect(in: localRect, cornerWidth: r, cornerHeight: r)
        case .ellipse:
            path.addEllipse(in: localRect)
        case .line:
            path.move(to: CGPoint(x: localRect.minX, y: 0))
            path.addLine(to: CGPoint(x: localRect.maxX, y: 0))
        case .arrow:
            let start = CGPoint(x: localRect.minX, y: 0)
            let end = CGPoint(x: localRect.maxX, y: 0)
            let headLen = min(w * 0.25, max(12.0, CGFloat(spec.lineWidth) * 3.5))
            let headHalfW = headLen * 0.6
            path.move(to: start)
            path.addLine(to: end)
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - headLen, y: headHalfW))
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - headLen, y: -headHalfW))
        }

        if let fill = spec.fillColor, spec.kind != .line && spec.kind != .arrow {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        if let stroke = spec.strokeColor, spec.lineWidth > 0 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(CGFloat(spec.lineWidth))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private static func drawTextLayer(_ spec: TextSpec, in ctx: CGContext) {
        let font = CTFontCreateWithName(spec.fontName as CFString, CGFloat(spec.size), nil)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: spec.color.cgColor
        ]

        if let stroke = spec.stroke, stroke.width > 0 {
            attributes[kCTStrokeColorAttributeName] = stroke.color.cgColor
            // Negative stroke width in CoreText means both fill and stroke
            let percent = -stroke.width / max(spec.size, 1.0) * 100.0
            attributes[kCTStrokeWidthAttributeName] = percent as CFNumber
        }

        guard let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault,
            spec.string as CFString,
            attributes as CFDictionary
        ) else { return }

        let line = CTLineCreateWithAttributedString(attrString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent

        let boxRect = CGRect(
            x: -width / 2.0 - 6.0,
            y: -height / 2.0 - 4.0,
            width: width + 12.0,
            height: height + 8.0
        )

        if let bg = spec.background {
            ctx.saveGState()
            ctx.setFillColor(bg.cgColor)
            let bgPath = CGPath(roundedRect: boxRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -width / 2.0, y: -height / 2.0 + descent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawStickerLayer(_ spec: StickerSpec, in ctx: CGContext) {
        let text: String
        switch spec.content {
        case .emoji(let emoji):
            text = emoji
        case .sfSymbol(let symbolName):
            text = symbolName
        }

        let textSpec = TextSpec(
            string: text,
            fontName: "AppleColorEmoji",
            size: spec.pointSize,
            color: spec.tintColor
        )
        drawTextLayer(textSpec, in: ctx)
    }
}
