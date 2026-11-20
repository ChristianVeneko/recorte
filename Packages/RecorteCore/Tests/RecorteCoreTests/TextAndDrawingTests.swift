import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

/// Fast bulk pixel reader (top-left origin: row 0 is top of image).
struct PixelGrid {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        let w = image.width
        let h = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        data.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.width = w
        self.height = h
        self.bytes = data
    }

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let idx = (y * width + x) * 4
        return (bytes[idx], bytes[idx + 1], bytes[idx + 2], bytes[idx + 3])
    }
}

@Suite("S16 Text & S17 Drawing, Frames, Shapes Tests")
struct TextAndDrawingTests {

    // MARK: - S16: Text Gradient Fill

    @Test("TextSpec horizontal gradient fill transitions from left color to right color")
    func textHorizontalGradientFill() throws {
        let spec = TextSpec(
            string: "MMMMMM",
            fontName: "HelveticaNeue-Bold",
            size: 64,
            color: .white,
            gradient: TextGradientSpec(colors: [.red, .blue], angleDegrees: 0)
        )
        let doc = EditorDocument(
            canvasSize: CGSize(width: 400, height: 140),
            background: .transparent,
            layers: [
                Layer(name: "GradText", kind: .text(spec), transform: LayerTransform(position: CGPoint(x: 200, y: 70)))
            ]
        )

        let img = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(img)

        // Collect inked pixels and find horizontal bounds
        var minX = img.width
        var maxX = -1
        for y in 0..<img.height {
            for x in 0..<img.width where grid.pixel(x: x, y: y).a > 200 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        #expect(maxX - minX > 100)

        let leftCutoff = minX + (maxX - minX) / 4
        let rightCutoff = maxX - (maxX - minX) / 4

        var leftR = 0, leftB = 0, leftN = 0
        var rightR = 0, rightB = 0, rightN = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let p = grid.pixel(x: x, y: y)
                guard p.a > 200 else { continue }
                if x <= leftCutoff {
                    leftR += Int(p.r); leftB += Int(p.b); leftN += 1
                } else if x >= rightCutoff {
                    rightR += Int(p.r); rightB += Int(p.b); rightN += 1
                }
            }
        }
        #expect(leftN > 20 && rightN > 20)
        // Left side should be strongly red-dominant, right side strongly blue-dominant
        #expect(leftR / leftN > leftB / leftN + 80)
        #expect(rightB / rightN > rightR / rightN + 80)
    }

    @Test("TextSpec vertical gradient fill (90 deg) transitions from top color to bottom color")
    func textVerticalGradientFill() throws {
        let spec = TextSpec(
            string: "HHH",
            fontName: "HelveticaNeue-Bold",
            size: 96,
            color: .white,
            gradient: TextGradientSpec(colors: [.green, .blue], angleDegrees: 90)
        )
        let doc = EditorDocument(
            canvasSize: CGSize(width: 300, height: 160),
            background: .transparent,
            layers: [
                Layer(name: "VertGrad", kind: .text(spec), transform: LayerTransform(position: CGPoint(x: 150, y: 80)))
            ]
        )

        let img = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(img)

        var minY = img.height
        var maxY = -1
        for y in 0..<img.height {
            for x in 0..<img.width where grid.pixel(x: x, y: y).a > 200 {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        #expect(maxY - minY > 40)

        let topCutoff = minY + (maxY - minY) / 3
        let bottomCutoff = maxY - (maxY - minY) / 3
        var topG = 0, topB = 0, topN = 0
        var botG = 0, botB = 0, botN = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let p = grid.pixel(x: x, y: y)
                guard p.a > 200 else { continue }
                if y <= topCutoff {
                    topG += Int(p.g); topB += Int(p.b); topN += 1
                } else if y >= bottomCutoff {
                    botG += Int(p.g); botB += Int(p.b); botN += 1
                }
            }
        }
        #expect(topN > 20 && botN > 20)
        #expect(topG / topN > topB / topN + 60)
        #expect(botB / botN > botG / botN + 60)
    }

    // MARK: - S16: Text Bubble Styles

    @Test("All TextBubbleStyle presets draw bubbles behind text and differ from none")
    func textBubbleStylesRender() throws {
        func renderBubble(_ style: TextBubbleStyle) throws -> PixelGrid {
            let spec = TextSpec(
                string: "Hello!",
                fontName: "HelveticaNeue-Bold",
                size: 28,
                color: .black,
                bubble: style,
                bubbleColor: .yellow,
                bubbleStrokeColor: .black,
                bubbleStrokeWidth: 2.0
            )
            let doc = EditorDocument(
                canvasSize: CGSize(width: 260, height: 180),
                background: .transparent,
                layers: [
                    Layer(name: "Bubble", kind: .text(spec), transform: LayerTransform(position: CGPoint(x: 130, y: 80)))
                ]
            )
            return PixelGrid(try Renderer.render(doc, scale: 1.0))
        }

        func countYellow(_ grid: PixelGrid) -> Int {
            var count = 0
            for y in 0..<grid.height {
                for x in 0..<grid.width {
                    let p = grid.pixel(x: x, y: y)
                    if p.a > 200 && p.r > 200 && p.g > 200 && p.b < 50 {
                        count += 1
                    }
                }
            }
            return count
        }

        let noneGrid = try renderBubble(.none)
        #expect(countYellow(noneGrid) == 0)

        for style in [TextBubbleStyle.rounded, .speech, .thought, .shout] {
            let g = try renderBubble(style)
            let yellowPixels = countYellow(g)
            #expect(yellowPixels > 1000, "Expected visible yellow bubble for \(style), got \(yellowPixels)")
            // Text pixels (dark/black) must still be visible on top of the bubble
            var darkPixels = 0
            for y in 55..<105 {
                for x in 70..<190 {
                    let p = g.pixel(x: x, y: y)
                    if p.a > 200 && p.r < 60 && p.g < 60 && p.b < 60 {
                        darkPixels += 1
                    }
                }
            }
            #expect(darkPixels > 50, "Expected dark text drawn on top of \(style) bubble")
        }

        // Speech and thought bubbles extend downward below the text box (y > 110) with tails/dots
        let speechGrid = try renderBubble(.speech)
        let thoughtGrid = try renderBubble(.thought)
        let roundedGrid = try renderBubble(.rounded)

        func opaqueBelow(_ grid: PixelGrid, yStart: Int) -> Int {
            var n = 0
            for y in yStart..<grid.height {
                for x in 0..<grid.width where grid.pixel(x: x, y: y).a > 128 {
                    n += 1
                }
            }
            return n
        }
        #expect(opaqueBelow(speechGrid, yStart: 112) > opaqueBelow(roundedGrid, yStart: 112))
        #expect(opaqueBelow(thoughtGrid, yStart: 112) > opaqueBelow(roundedGrid, yStart: 112))
    }

    // MARK: - S17: Drawing Layer

    @Test("LayerKind.drawing renders brush, marker, and highlighter strokes at top-left coordinates")
    func drawingLayerRendersTools() throws {
        let brushStroke = DrawingStroke(
            points: [CGPoint(x: 20, y: 25), CGPoint(x: 100, y: 25), CGPoint(x: 180, y: 25)],
            color: .red,
            width: 10,
            tool: .brush
        )
        let markerStroke = DrawingStroke(
            points: [CGPoint(x: 20, y: 75), CGPoint(x: 180, y: 75)],
            color: .blue,
            width: 10,
            tool: .marker
        )
        let highlighterStroke = DrawingStroke(
            points: [CGPoint(x: 20, y: 125), CGPoint(x: 180, y: 125)],
            color: .yellow,
            width: 14,
            tool: .highlighter
        )
        let dotStroke = DrawingStroke(
            points: [CGPoint(x: 100, y: 170)],
            color: .green,
            width: 12,
            tool: .brush
        )

        let doc = EditorDocument(
            canvasSize: CGSize(width: 200, height: 200),
            background: .transparent,
            layers: [
                Layer(
                    name: "Sketch",
                    kind: .drawing(DrawingSpec(strokes: [brushStroke, markerStroke, highlighterStroke, dotStroke]))
                )
            ]
        )

        let img = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(img)

        // Brush stroke at y=25 (top) is opaque red
        let pBrush = grid.pixel(x: 100, y: 25)
        #expect(pBrush.r > 230 && pBrush.g < 20 && pBrush.a == 255)

        // Marker stroke at y=75 is opaque blue
        let pMarker = grid.pixel(x: 100, y: 75)
        #expect(pMarker.b > 230 && pMarker.r < 20 && pMarker.a == 255)

        // Highlighter stroke at y=125 is translucent yellow (0 < a < 180)
        let pHigh = grid.pixel(x: 100, y: 125)
        #expect(pHigh.a > 40 && pHigh.a < 180)

        // Single-point dot at (100, 170) is green
        let pDot = grid.pixel(x: 100, y: 170)
        #expect(pDot.g > 230 && pDot.a == 255)

        // Empty region between strokes is transparent
        let pEmpty = grid.pixel(x: 100, y: 50)
        #expect(pEmpty.a == 0)
    }

    // MARK: - S17: ImageFrame

    @Test("ImageFrame variants: border, roundedCorners, polaroid, dropShadow render visibly")
    func imageFrameVariants() throws {
        let baseImg = RecorteCoreTests.makeSolidImage(width: 80, height: 80, r: 0, g: 120, b: 255, a: 255)

        // 1. Border
        let borderDoc = EditorDocument(
            canvasSize: CGSize(width: 140, height: 140),
            background: .transparent,
            layers: [
                Layer(
                    name: "Bordered",
                    kind: .image(SendableImage(baseImg, frame: .border(width: 8, color: .red))),
                    transform: LayerTransform(position: CGPoint(x: 70, y: 70))
                )
            ]
        )
        let borderGrid = PixelGrid(try Renderer.render(borderDoc, scale: 1.0))
        // Edge of image at x=32, y=70 should be red border; center (70, 70) stays blue
        let edgePx = borderGrid.pixel(x: 32, y: 70)
        let centerPx = borderGrid.pixel(x: 70, y: 70)
        #expect(edgePx.r > 220 && edgePx.b < 30 && edgePx.a == 255)
        #expect(centerPx.b > 220 && centerPx.r < 30 && centerPx.a == 255)

        // 2. Rounded corners
        let roundedDoc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 100),
            background: .transparent,
            layers: [
                Layer(
                    name: "Rounded",
                    kind: .image(SendableImage(baseImg, frame: .roundedCorners(radius: 25))),
                    transform: LayerTransform(position: CGPoint(x: 50, y: 50))
                )
            ]
        )
        let roundedGrid = PixelGrid(try Renderer.render(roundedDoc, scale: 1.0))
        // Corner of image rect (11, 11) should be clipped transparent; center (50, 50) stays opaque blue
        #expect(roundedGrid.pixel(x: 11, y: 11).a == 0)
        #expect(roundedGrid.pixel(x: 50, y: 50).a == 255 && roundedGrid.pixel(x: 50, y: 50).b > 220)

        // 3. Polaroid
        let polaroidDoc = EditorDocument(
            canvasSize: CGSize(width: 160, height: 180),
            background: .transparent,
            layers: [
                Layer(
                    name: "Polaroid",
                    kind: .image(SendableImage(baseImg, frame: .polaroid(caption: "Trip", borderColor: .white))),
                    transform: LayerTransform(position: CGPoint(x: 80, y: 80))
                )
            ]
        )
        let polaroidGrid = PixelGrid(try Renderer.render(polaroidDoc, scale: 1.0))
        // Below the 80x80 image (y = 120..140) should have the thick white Polaroid chin!
        let chinPx = polaroidGrid.pixel(x: 55, y: 132)
        #expect(chinPx.r > 230 && chinPx.g > 230 && chinPx.b > 230 && chinPx.a == 255)
        // Center of image remains blue
        #expect(polaroidGrid.pixel(x: 80, y: 80).b > 220)

        // 4. Drop shadow (offsetY = +10 pushes shadow DOWN below the image bottom y = 110)
        let shadowDoc = EditorDocument(
            canvasSize: CGSize(width: 160, height: 160),
            background: .transparent,
            layers: [
                Layer(
                    name: "Shadowed",
                    kind: .image(SendableImage(baseImg, frame: .dropShadow(radius: 10, offsetX: 0, offsetY: 12, color: RGBAColor(r: 0, g: 0, b: 0, a: 0.8)))),
                    transform: LayerTransform(position: CGPoint(x: 80, y: 70))
                )
            ]
        )
        let shadowGrid = PixelGrid(try Renderer.render(shadowDoc, scale: 1.0))
        // Directly below image (image ends at y = 70 + 40 = 110) at y = 116 should have visible dark shadow
        let belowPx = shadowGrid.pixel(x: 80, y: 116)
        // Directly above image (image starts at y = 30) at y = 20 should have much less or zero shadow
        let abovePx = shadowGrid.pixel(x: 80, y: 20)
        #expect(belowPx.a > 40, "Expected visible drop shadow below image, got \(belowPx)")
        #expect(belowPx.a > abovePx.a, "Expected positive offsetY shadow to be stronger below (\(belowPx.a)) than above (\(abovePx.a))")
    }

    // MARK: - S17: Basic Paint Shapes (triangle, star)

    @Test("ShapeKind.triangle renders upright with apex at top and wide base at bottom")
    func triangleShapeRendersUpright() throws {
        let doc = EditorDocument(
            canvasSize: CGSize(width: 120, height: 120),
            background: .transparent,
            layers: [
                Layer(
                    name: "Tri",
                    kind: .shape(ShapeSpec(kind: .triangle, size: CGSize(width: 80, height: 80), strokeColor: nil, fillColor: .red, lineWidth: 0)),
                    transform: LayerTransform(position: CGPoint(x: 60, y: 60))
                )
            ]
        )
        let grid = PixelGrid(try Renderer.render(doc, scale: 1.0))
        // Top corners (25, 25) and (95, 25) are outside the triangle
        #expect(grid.pixel(x: 25, y: 25).a == 0)
        #expect(grid.pixel(x: 95, y: 25).a == 0)
        // Near apex (60, 25) is inside
        #expect(grid.pixel(x: 60, y: 25).r > 230 && grid.pixel(x: 60, y: 25).a == 255)
        // Wide bottom base near y=95 is filled at both x=30 and x=90
        #expect(grid.pixel(x: 30, y: 95).r > 230 && grid.pixel(x: 30, y: 95).a == 255)
        #expect(grid.pixel(x: 90, y: 95).r > 230 && grid.pixel(x: 90, y: 95).a == 255)
    }

    @Test("ShapeKind.star renders upright 5-pointed star with top point at apex")
    func starShapeRendersUpright() throws {
        let doc = EditorDocument(
            canvasSize: CGSize(width: 120, height: 120),
            background: .transparent,
            layers: [
                Layer(
                    name: "Star",
                    kind: .shape(ShapeSpec(kind: .star, size: CGSize(width: 80, height: 80), strokeColor: nil, fillColor: .yellow, lineWidth: 0)),
                    transform: LayerTransform(position: CGPoint(x: 60, y: 60))
                )
            ]
        )
        let grid = PixelGrid(try Renderer.render(doc, scale: 1.0))
        // Center is filled yellow
        let center = grid.pixel(x: 60, y: 60)
        #expect(center.r > 230 && center.g > 230 && center.a == 255)
        // Top vertical point (60, 24) is inside the upright star apex
        let topPoint = grid.pixel(x: 60, y: 24)
        #expect(topPoint.r > 230 && topPoint.g > 230 && topPoint.a == 255)
        // Bottom center notch (60, 95) is outside an upright 5-pointed star (between the two bottom legs)
        #expect(grid.pixel(x: 60, y: 95).a == 0)
    }
}
