import Foundation
import CoreGraphics
import CoreText
import AppKit

public enum RenderError: Error, Sendable, Equatable {
    case invalidCanvasSize
    case contextCreationFailed
    case imageCreationFailed
}

public enum Renderer {

    /// Renders `document` at `scale` into a `CGImage`, compositing all visible layers in order
    /// with their transforms and opacity using CoreGraphics and CoreText.
    ///
    /// Coordinates: top-left origin, y down, in canvas points (`layer.transform.position` is the layer center).
    public static func render(_ document: EditorDocument, _ scale: CGFloat) throws -> CGImage {
        try render(document, scale: scale)
    }

    /// Renders `document` at `scale` into a `CGImage`, compositing all visible layers in order
    /// with their transforms and opacity using CoreGraphics and CoreText.
    ///
    /// Coordinates: top-left origin, y down, in canvas points (`layer.transform.position` is the layer center).
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

        // Work in logical canvas coordinates (top-left origin, y down, in canvas points)
        ctx.saveGState()
        ctx.scaleBy(x: effectiveScale, y: effectiveScale)
        ctx.translateBy(x: 0, y: document.canvasSize.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

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
                drawImageLayer(sendableImg, in: ctx, renderScale: effectiveScale)
            case .shape(let shapeSpec):
                drawShapeLayer(shapeSpec, in: ctx)
            case .text(let textSpec):
                drawTextLayer(textSpec, in: ctx)
            case .sticker(let stickerSpec):
                drawStickerLayer(stickerSpec, in: ctx)
            case .drawing(let drawingSpec):
                drawDrawingLayer(drawingSpec, in: ctx)
            }

            ctx.restoreGState()
        }

        ctx.restoreGState()

        guard let output = ctx.makeImage() else {
            throw RenderError.imageCreationFailed
        }
        return output
    }

    // MARK: - Image Layer

    private static func drawImageLayer(_ sendableImg: SendableImage, in ctx: CGContext, renderScale: CGFloat) {
        let filteredImage: CGImage
        if sendableImg.filterPreset != .none || !sendableImg.adjustments.isIdentity {
            filteredImage = (try? ImageFilters.apply(
                to: sendableImg.cgImage,
                preset: sendableImg.filterPreset,
                adjustments: sendableImg.adjustments
            )) ?? sendableImg.cgImage
        } else {
            filteredImage = sendableImg.cgImage
        }

        let imgToDraw: CGImage
        if let mask = sendableImg.alphaMask {
            imgToDraw = (try? ImageEraser.applyAlphaMask(mask, to: filteredImage)) ?? filteredImage
        } else {
            imgToDraw = filteredImage
        }

        let w = CGFloat(imgToDraw.width)
        let h = CGFloat(imgToDraw.height)
        let localRect = CGRect(x: -w / 2.0, y: -h / 2.0, width: w, height: h)

        func drawUprightImage() {
            ctx.saveGState()
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.draw(imgToDraw, in: localRect)
            ctx.restoreGState()
        }

        switch sendableImg.frame {
        case .none:
            drawUprightImage()

        case .border(let width, let color):
            drawUprightImage()
            let bw = min(max(CGFloat(width), 0), min(w, h) / 2.0)
            if bw > 0 {
                ctx.saveGState()
                let strokeRect = localRect.insetBy(dx: bw / 2.0, dy: bw / 2.0)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(bw)
                ctx.stroke(strokeRect)
                ctx.restoreGState()
            }

        case .roundedCorners(let radius):
            let r = min(max(CGFloat(radius), 0), min(w, h) / 2.0)
            ctx.saveGState()
            let clipPath = CGPath(roundedRect: localRect, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()
            drawUprightImage()
            ctx.restoreGState()

        case .polaroid(let caption, let borderColor):
            let sidePad = max(8.0, min(w, h) * 0.08)
            let topPad = sidePad
            let bottomPad = max(24.0, h * 0.24)
            let frameRect = CGRect(
                x: localRect.minX - sidePad,
                y: localRect.minY - topPad,
                width: w + sidePad * 2.0,
                height: h + topPad + bottomPad
            )

            ctx.saveGState()
            // Subtle shadow under the Polaroid card (negative y offset = downward in Quartz device space)
            ctx.setShadow(
                offset: CGSize(width: 0, height: -2.0 * renderScale),
                blur: 6.0 * renderScale,
                color: RGBAColor(r: 0, g: 0, b: 0, a: 0.22).cgColor
            )
            ctx.setFillColor(borderColor.cgColor)
            ctx.fill(frameRect)
            ctx.restoreGState()

            drawUprightImage()

            if let caption, !caption.isEmpty {
                let captionSize = max(10.0, min(bottomPad * 0.48, 22.0))
                let captionSpec = TextSpec(
                    string: caption,
                    fontName: "HelveticaNeue",
                    size: Double(captionSize),
                    color: RGBAColor(r: 0.16, g: 0.16, b: 0.2, a: 1.0),
                    alignment: .center
                )
                ctx.saveGState()
                ctx.translateBy(x: 0, y: localRect.maxY + bottomPad / 2.0)
                drawTextLayer(captionSpec, in: ctx)
                ctx.restoreGState()
            }

        case .dropShadow(let radius, let offsetX, let offsetY, let color):
            ctx.saveGState()
            // Quartz shadow offsets are in unflipped device space (+y is up), so negate offsetY for top-left y-down
            ctx.setShadow(
                offset: CGSize(width: CGFloat(offsetX) * renderScale, height: -CGFloat(offsetY) * renderScale),
                blur: max(0, CGFloat(radius)) * renderScale,
                color: color.cgColor
            )
            drawUprightImage()
            ctx.restoreGState()
        }
    }

    // MARK: - Shape Layer

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
        case .triangle:
            // In top-left y-down space: minY is top apex, maxY is bottom base
            path.move(to: CGPoint(x: 0, y: localRect.minY))
            path.addLine(to: CGPoint(x: localRect.maxX, y: localRect.maxY))
            path.addLine(to: CGPoint(x: localRect.minX, y: localRect.maxY))
            path.closeSubpath()
        case .star:
            let rxOuter = w / 2.0
            let ryOuter = h / 2.0
            let rxInner = rxOuter * 0.382
            let ryInner = ryOuter * 0.382
            let points = 5
            for i in 0..<(points * 2) {
                let isOuter = (i % 2 == 0)
                let rx = isOuter ? rxOuter : rxInner
                let ry = isOuter ? ryOuter : ryInner
                // -pi/2 points straight up (-y) in top-left y-down space
                let angle = (CGFloat(i) * .pi / CGFloat(points)) - (.pi / 2.0)
                let pt = CGPoint(x: rx * cos(angle), y: ry * sin(angle))
                if i == 0 {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
            }
            path.closeSubpath()
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

    // MARK: - Text Layer

    private struct MeasuredLine {
        let ctLine: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        var height: CGFloat { ascent + descent }
    }

    private static func makeLines(
        text: String,
        font: CTFont,
        foregroundColor: CGColor,
        strokeColor: CGColor? = nil,
        strokeWidthPercent: Double? = nil
    ) -> [MeasuredLine] {
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: foregroundColor
        ]
        if let strokeColor, let strokeWidthPercent {
            attributes[kCTStrokeColorAttributeName] = strokeColor
            attributes[kCTStrokeWidthAttributeName] = strokeWidthPercent as CFNumber
        }

        let rawLines = text.components(separatedBy: "\n")
        return rawLines.compactMap { lineStr in
            guard let attrString = CFAttributedStringCreate(
                kCFAllocatorDefault,
                lineStr as CFString,
                attributes as CFDictionary
            ) else { return nil }
            let ctLine = CTLineCreateWithAttributedString(attrString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            if ascent == 0 && descent == 0 {
                ascent = CTFontGetAscent(font)
                descent = CTFontGetDescent(font)
            }
            return MeasuredLine(ctLine: ctLine, width: width, ascent: ascent, descent: descent, leading: leading)
        }
    }

    private static func drawLinesUpright(
        _ lines: [MeasuredLine],
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        lineSpacing: CGFloat,
        alignment: TextAlignmentSpec,
        in ctx: CGContext
    ) {
        // Unflip locally so CoreText draws glyphs upright in our y-down canvas
        ctx.saveGState()
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.textMatrix = .identity

        // In locally unflipped coords (+y is UP): top of text block is +totalHeight/2, moving DOWN subtracts y
        var cursorTop = totalHeight / 2.0
        for (idx, line) in lines.enumerated() {
            let x: CGFloat
            switch alignment {
            case .left:
                x = -totalWidth / 2.0
            case .center:
                x = -line.width / 2.0
            case .right:
                x = totalWidth / 2.0 - line.width
            }
            let baselineY = cursorTop - line.ascent
            ctx.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(line.ctLine, ctx)
            cursorTop -= line.height
            if idx + 1 < lines.count {
                cursorTop -= lineSpacing
            }
        }
        ctx.restoreGState()
    }

    private static func drawTextLayer(_ spec: TextSpec, in ctx: CGContext) {
        let font = CTFontCreateWithName(spec.fontName as CFString, CGFloat(spec.size), nil)
        let lineSpacing = max(2.0, CGFloat(spec.size) * 0.15)

        let hasGradient = (spec.gradient?.colors.isEmpty == false)
        let solidStrokePercent: Double? = (!hasGradient && (spec.stroke?.width ?? 0) > 0)
            ? -(spec.stroke!.width / max(spec.size, 1.0) * 100.0)
            : nil

        let primaryLines = makeLines(
            text: spec.string,
            font: font,
            foregroundColor: hasGradient ? RGBAColor.white.cgColor : spec.color.cgColor,
            strokeColor: solidStrokePercent != nil ? spec.stroke?.color.cgColor : nil,
            strokeWidthPercent: solidStrokePercent
        )
        guard !primaryLines.isEmpty else { return }

        let totalWidth = primaryLines.map(\.width).max() ?? 0
        let totalHeight = primaryLines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, primaryLines.count - 1))
        let textBounds = CGRect(
            x: -totalWidth / 2.0,
            y: -totalHeight / 2.0,
            width: totalWidth,
            height: totalHeight
        )

        // 1. Draw Bubble or Background behind text (in top-left y-down local space)
        if spec.bubble != .none {
            drawTextBubble(spec: spec, textBounds: textBounds, in: ctx)
        } else if let bg = spec.background {
            let boxRect = textBounds.insetBy(dx: -6.0, dy: -4.0)
            ctx.saveGState()
            ctx.setFillColor(bg.cgColor)
            let bgPath = CGPath(roundedRect: boxRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Draw Text (gradient-filled or solid)
        if let gradient = spec.gradient, !gradient.colors.isEmpty {
            let cgColors: [CGColor]
            if gradient.colors.count == 1 {
                let c = gradient.colors[0].cgColor
                cgColors = [c, c]
            } else {
                cgColors = gradient.colors.map(\.cgColor)
            }
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawLinesUpright(
                primaryLines,
                totalWidth: totalWidth,
                totalHeight: totalHeight,
                lineSpacing: lineSpacing,
                alignment: spec.alignment,
                in: ctx
            )
            if let cgGradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: nil) {
                ctx.setBlendMode(.sourceIn)
                let rad = CGFloat(gradient.angleDegrees) * .pi / 180.0
                let dx = cos(rad)
                let dy = sin(rad)
                let halfLen = max(1.0, (abs(dx) * totalWidth + abs(dy) * totalHeight) / 2.0)
                let start = CGPoint(x: -dx * halfLen, y: -dy * halfLen)
                let end = CGPoint(x: dx * halfLen, y: dy * halfLen)
                ctx.drawLinearGradient(
                    cgGradient,
                    start: start,
                    end: end,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()

            // Optional outline stroke on gradient text (positive stroke width = stroke only)
            if let stroke = spec.stroke, stroke.width > 0 {
                let strokePercent = stroke.width / max(spec.size, 1.0) * 100.0
                let strokeLines = makeLines(
                    text: spec.string,
                    font: font,
                    foregroundColor: RGBAColor.clear.cgColor,
                    strokeColor: stroke.color.cgColor,
                    strokeWidthPercent: strokePercent
                )
                drawLinesUpright(
                    strokeLines,
                    totalWidth: totalWidth,
                    totalHeight: totalHeight,
                    lineSpacing: lineSpacing,
                    alignment: spec.alignment,
                    in: ctx
                )
            }
        } else {
            drawLinesUpright(
                primaryLines,
                totalWidth: totalWidth,
                totalHeight: totalHeight,
                lineSpacing: lineSpacing,
                alignment: spec.alignment,
                in: ctx
            )
        }
    }

    private static func drawTextBubble(spec: TextSpec, textBounds: CGRect, in ctx: CGContext) {
        let textLuminance = 0.299 * spec.color.r + 0.587 * spec.color.g + 0.114 * spec.color.b
        let defaultBubbleFill: RGBAColor = textLuminance > 0.7
            ? RGBAColor(r: 0.14, g: 0.14, b: 0.18, a: 1.0)
            : .white
        let fillColor = spec.bubbleColor ?? spec.background ?? defaultBubbleFill
        let strokeColor = spec.bubbleStrokeColor
        let strokeWidth = max(0, CGFloat(spec.bubbleStrokeWidth))

        let padX = max(16.0, CGFloat(spec.size) * 0.45)
        let padY = max(10.0, CGFloat(spec.size) * 0.30)
        let box = textBounds.insetBy(dx: -padX, dy: -padY)

        func fillAndStroke(_ path: CGPath) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()
            if let strokeColor, strokeWidth > 0 {
                ctx.addPath(path)
                ctx.setStrokeColor(strokeColor.cgColor)
                ctx.setLineWidth(strokeWidth)
                ctx.setLineJoin(.round)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        switch spec.bubble {
        case .none:
            break

        case .rounded:
            let r = min(box.height / 2.0, max(12.0, CGFloat(spec.size) * 0.45))
            let path = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
            fillAndStroke(path)

        case .speech:
            let r = min(box.width / 4.0, box.height / 3.0, 14.0)
            let tailHeight = max(14.0, box.height * 0.38)
            let tailBaseLeft = box.minX + max(r + 6.0, box.width * 0.18)
            let tailBaseRight = min(box.maxX - r - 4.0, tailBaseLeft + max(14.0, box.width * 0.14))
            let tailTip = CGPoint(x: max(box.minX + 4.0, tailBaseLeft - 8.0), y: box.maxY + tailHeight)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: box.minX + r, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + r), radius: r)
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX - r, y: box.maxY), radius: r)
            path.addLine(to: CGPoint(x: tailBaseRight, y: box.maxY))
            path.addLine(to: tailTip)
            path.addLine(to: CGPoint(x: tailBaseLeft, y: box.maxY))
            path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY - r), radius: r)
            path.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + r, y: box.minY), radius: r)
            path.closeSubpath()
            fillAndStroke(path)

        case .thought:
            // Scalloped cloud body composed of overlapping bumps around the box perimeter + trailing thought dots
            let cloudPath = CGMutablePath()
            let rx = box.width / 2.0
            let ry = box.height / 2.0
            let bumpCount = 12
            let bumpRadius = max(10.0, min(box.width, box.height) * 0.24)
            cloudPath.addEllipse(in: box)
            for i in 0..<bumpCount {
                let angle = CGFloat(i) * (2.0 * .pi / CGFloat(bumpCount))
                let cx = box.midX + rx * 0.88 * cos(angle)
                let cy = box.midY + ry * 0.88 * sin(angle)
                cloudPath.addEllipse(in: CGRect(x: cx - bumpRadius, y: cy - bumpRadius, width: bumpRadius * 2, height: bumpRadius * 2))
            }
            ctx.saveGState()
            if let strokeColor, strokeWidth > 0 {
                // Draw slightly expanded stroke halo underneath so internal bump overlaps stay clean
                ctx.setFillColor(strokeColor.cgColor)
                let outerPath = CGMutablePath()
                outerPath.addEllipse(in: box.insetBy(dx: -strokeWidth, dy: -strokeWidth))
                for i in 0..<bumpCount {
                    let angle = CGFloat(i) * (2.0 * .pi / CGFloat(bumpCount))
                    let cx = box.midX + rx * 0.88 * cos(angle)
                    let cy = box.midY + ry * 0.88 * sin(angle)
                    let br = bumpRadius + strokeWidth
                    outerPath.addEllipse(in: CGRect(x: cx - br, y: cy - br, width: br * 2, height: br * 2))
                }
                ctx.addPath(outerPath)
                ctx.fillPath()
            }
            ctx.addPath(cloudPath)
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Descending thought dots below bottom-left
            let dot1R = max(5.0, min(box.width, box.height) * 0.11)
            let dot2R = max(3.5, dot1R * 0.65)
            let dot1Center = CGPoint(x: box.minX + box.width * 0.22, y: box.maxY + bumpRadius * 0.75 + dot1R)
            let dot2Center = CGPoint(x: dot1Center.x - dot1R * 1.1, y: dot1Center.y + dot1R + dot2R + 4.0)
            for (c, r) in [(dot1Center, dot1R), (dot2Center, dot2R)] {
                let dotPath = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
                fillAndStroke(dotPath)
            }

        case .shout:
            // Jagged comic-book starburst polygon around the text
            let spikes = 16
            let outerRx = box.width * 0.72
            let outerRy = box.height * 0.82
            let innerRx = box.width * 0.54
            let innerRy = box.height * 0.56
            let path = CGMutablePath()
            for i in 0..<(spikes * 2) {
                let isOuter = (i % 2 == 0)
                let rx = isOuter ? outerRx : innerRx
                let ry = isOuter ? outerRy : innerRy
                let angle = CGFloat(i) * .pi / CGFloat(spikes)
                let pt = CGPoint(x: box.midX + rx * cos(angle), y: box.midY + ry * sin(angle))
                if i == 0 {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
            }
            path.closeSubpath()
            fillAndStroke(path)
        }
    }

    // MARK: - Sticker Layer

    private static func drawStickerLayer(_ spec: StickerSpec, in ctx: CGContext) {
        if let bg = spec.background {
            let dim = max(32.0, ceil(CGFloat(spec.pointSize) * 1.45))
            let badgeRect = CGRect(x: -dim / 2.0, y: -dim / 2.0, width: dim, height: dim)
            let cornerRadius = dim * 0.22
            let path = CGPath(roundedRect: badgeRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(bg.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        let text: String
        switch spec.content {
        case .emoji(let emoji):
            text = emoji
        case .sfSymbol(let symbolName):
            drawSymbolSticker(symbolName, spec: spec, in: ctx)
            return
        }

        let textSpec = TextSpec(
            string: text,
            fontName: "AppleColorEmoji",
            size: spec.pointSize,
            color: spec.tintColor
        )
        drawTextLayer(textSpec, in: ctx)
    }

    /// Draws an SF Symbol tinted with the sticker color, centered on the layer origin.
    private static func drawSymbolSticker(_ name: String, spec: StickerSpec, in ctx: CGContext) {
        let tint = NSColor(srgbRed: spec.tintColor.r, green: spec.tintColor.g, blue: spec.tintColor.b, alpha: spec.tintColor.a)
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(spec.pointSize), weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        var rect = CGRect(origin: .zero, size: symbol.size)
        guard let image = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let w = symbol.size.width, h = symbol.size.height
        ctx.saveGState()
        ctx.scaleBy(x: 1.0, y: -1.0)  // context is top-left; CGImage draws bottom-up
        ctx.draw(image, in: CGRect(x: -w / 2.0, y: -h / 2.0, width: w, height: h))
        ctx.restoreGState()
    }

    // MARK: - Drawing Layer

    private static func drawDrawingLayer(_ spec: DrawingSpec, in ctx: CGContext) {
        for stroke in spec.strokes {
            guard !stroke.points.isEmpty, stroke.width > 0 else { continue }
            let lineWidth = CGFloat(stroke.width)

            ctx.saveGState()

            switch stroke.tool {
            case .brush:
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setLineWidth(lineWidth)
                ctx.setStrokeColor(stroke.color.cgColor)
                ctx.setFillColor(stroke.color.cgColor)

                if stroke.points.count == 1 {
                    let pt = stroke.points[0]
                    let r = lineWidth / 2.0
                    ctx.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: lineWidth, height: lineWidth))
                } else {
                    let path = smoothStrokePath(points: stroke.points)
                    ctx.addPath(path)
                    ctx.strokePath()
                }

            case .marker:
                ctx.setLineCap(.square)
                ctx.setLineJoin(.round)
                ctx.setLineWidth(lineWidth)
                ctx.setStrokeColor(stroke.color.cgColor)
                ctx.setFillColor(stroke.color.cgColor)

                if stroke.points.count == 1 {
                    let pt = stroke.points[0]
                    let r = lineWidth / 2.0
                    ctx.fill(CGRect(x: pt.x - r, y: pt.y - r, width: lineWidth, height: lineWidth))
                } else {
                    let path = polylinePath(points: stroke.points)
                    ctx.addPath(path)
                    ctx.strokePath()
                }

            case .highlighter:
                // Use a transparency layer so overlapping segments in a single highlighter stroke maintain uniform translucency
                let translucentAlpha = CGFloat(min(stroke.color.a, 0.4))
                let opaqueColor = RGBAColor(r: stroke.color.r, g: stroke.color.g, b: stroke.color.b, a: 1.0)
                ctx.setAlpha(translucentAlpha)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setLineCap(.butt)
                ctx.setLineJoin(.round)
                ctx.setLineWidth(lineWidth)
                ctx.setStrokeColor(opaqueColor.cgColor)
                ctx.setFillColor(opaqueColor.cgColor)

                if stroke.points.count == 1 {
                    let pt = stroke.points[0]
                    let r = lineWidth / 2.0
                    ctx.fill(CGRect(x: pt.x - r, y: pt.y - r, width: lineWidth, height: lineWidth))
                } else {
                    let path = polylinePath(points: stroke.points)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
                ctx.endTransparencyLayer()
            }

            ctx.restoreGState()
        }
    }

    private static func smoothStrokePath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let current = points[i]
            let next = points[i + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2.0, y: (current.y + next.y) / 2.0)
            path.addQuadCurve(to: mid, control: current)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    private static func polylinePath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for pt in points.dropFirst() {
            path.addLine(to: pt)
        }
        return path
    }
}
