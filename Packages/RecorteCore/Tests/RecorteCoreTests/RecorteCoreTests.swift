import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("RecorteCore Tests")
struct RecorteCoreTests {

    // MARK: - Test Helpers
    static func makeSolidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        ctx.setFillColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func pixelRGBA(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        data.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let idx = (y * width + x) * 4
        return (data[idx], data[idx + 1], data[idx + 2], data[idx + 3])
    }

    // MARK: - 1. Document & Layer Operations
    @Test("Document layer operations: add, remove, duplicate, reorder, visibility, lock, opacity")
    func documentLayerOps() {
        var doc = EditorDocument(
            canvasSize: CGSize(width: 800, height: 600),
            background: .solid(RGBAColor(r: 1, g: 1, b: 1, a: 1))
        )
        #expect(doc.layers.isEmpty)

        let textLayer = Layer(
            name: "Title",
            kind: .text(TextSpec(string: "Hello", fontName: "Helvetica", size: 24))
        )
        let shapeLayer = Layer(
            name: "Box",
            kind: .shape(ShapeSpec(kind: .rect, strokeColor: .red, fillColor: .blue, lineWidth: 2))
        )

        doc.add(textLayer)
        doc.add(shapeLayer)
        #expect(doc.layers.count == 2)
        #expect(doc.selection == shapeLayer.id)

        // setVisibility, setLock, setOpacity
        doc.setVisibility(id: textLayer.id, isHidden: true)
        #expect(doc.layer(id: textLayer.id)?.isHidden == true)

        doc.setLock(id: textLayer.id, isLocked: true)
        #expect(doc.layer(id: textLayer.id)?.isLocked == true)

        doc.setOpacity(id: textLayer.id, opacity: 0.45)
        #expect(abs((doc.layer(id: textLayer.id)?.opacity ?? 0) - 0.45) < 0.001)

        // Duplicate
        let dup = doc.duplicate(id: textLayer.id)
        #expect(dup != nil)
        #expect(doc.layers.count == 3)
        #expect(dup?.id != textLayer.id)

        // Reorder (move index 0 to index 2)
        let firstID = doc.layers[0].id
        doc.reorder(from: 0, to: 2)
        #expect(doc.layers[2].id == firstID)

        // Remove
        doc.remove(id: firstID)
        #expect(doc.layers.count == 2)
        #expect(doc.layer(id: firstID) == nil)
    }

    // MARK: - 2. Cropping Rect / Aspect Math & Shape Masks
    @Test("Constrain rect to aspect inside image bounds")
    func cropRectAspectMath() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // 1:1 aspect constrained inside bounds
        let proposed = CGRect(x: 100, y: 100, width: 600, height: 400)
        let square = Cropper.constrainRect(proposed, aspect: .ratio1x1, in: bounds)
        #expect(bounds.contains(square))
        #expect(abs(square.width - square.height) < 0.01)

        // 16:9 aspect overflowing bounds
        let overflow = CGRect(x: -50, y: -50, width: 1200, height: 900)
        let wide = Cropper.constrainRect(overflow, aspect: .ratio16x9, in: bounds)
        #expect(bounds.contains(wide))
        #expect(abs((wide.width / wide.height) - (16.0 / 9.0)) < 0.01)

        // Original aspect (1000:800 = 5:4)
        let orig = Cropper.constrainRect(CGRect(x: 50, y: 50, width: 500, height: 500), aspect: .original, in: bounds)
        #expect(bounds.contains(orig))
        #expect(abs((orig.width / orig.height) - (1000.0 / 800.0)) < 0.01)

        // Free aspect clamps to bounds
        let free = Cropper.constrainRect(CGRect(x: 900, y: 700, width: 200, height: 200), aspect: .free, in: bounds)
        #expect(bounds.contains(free))
    }

    @Test("Each non-rectangular crop shape produces transparent corners and opaque center")
    func cropShapesProduceTransparentCorners() throws {
        let src = Self.makeSolidImage(width: 200, height: 200, r: 255, g: 40, b: 40, a: 255)
        let cropRect = CGRect(x: 0, y: 0, width: 200, height: 200)

        let maskedShapes: [CropShape] = [
            .roundedRect(radius: 50),
            .ellipse,
            .star,
            .heart
        ]

        for shape in maskedShapes {
            let spec = CropSpec(rect: cropRect, aspect: .ratio1x1, shape: shape)
            let cropped = try Cropper.crop(src, spec: spec)
            #expect(cropped.width == 200)
            #expect(cropped.height == 200)

            let topLeft = Self.pixelRGBA(in: cropped, x: 2, y: 2)
            let topRight = Self.pixelRGBA(in: cropped, x: 197, y: 2)
            let bottomLeft = Self.pixelRGBA(in: cropped, x: 2, y: 197)
            let bottomRight = Self.pixelRGBA(in: cropped, x: 197, y: 197)
            let center = Self.pixelRGBA(in: cropped, x: 100, y: 100)

            #expect(topLeft.a == 0, "Top-left should be transparent for \(shape)")
            #expect(topRight.a == 0, "Top-right should be transparent for \(shape)")
            #expect(bottomLeft.a == 0, "Bottom-left should be transparent for \(shape)")
            #expect(bottomRight.a == 0, "Bottom-right should be transparent for \(shape)")
            #expect(center.a == 255 && center.r > 200, "Center should be opaque red for \(shape)")
        }

        // Rectangle keeps corners opaque
        let rectSpec = CropSpec(rect: cropRect, aspect: .ratio1x1, shape: .rectangle)
        let rectCropped = try Cropper.crop(src, spec: rectSpec)
        let corner = Self.pixelRGBA(in: rectCropped, x: 2, y: 2)
        #expect(corner.a == 255)
    }

    @Test("Crop supports rotation and flips")
    func cropRotationAndFlips() throws {
        // Left half red, right half blue
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let img = ctx.makeImage()!

        let spec = CropSpec(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            aspect: .free,
            shape: .rectangle,
            rotationDegrees: 0,
            flipH: true,
            flipV: false
        )
        let flipped = try Cropper.crop(img, spec: spec)
        let leftPixel = Self.pixelRGBA(in: flipped, x: 10, y: 50)
        let rightPixel = Self.pixelRGBA(in: flipped, x: 90, y: 50)
        #expect(leftPixel.b > 200 && leftPixel.r < 30)
        #expect(rightPixel.r > 200 && rightPixel.b < 30)
    }

    // MARK: - 3. Filters & Adjustments
    @Test("Filter presets and adjustments produce valid CGImage using shared CIContext")
    func filterPresetsAndAdjustments() throws {
        let src = Self.makeSolidImage(width: 64, height: 64, r: 220, g: 80, b: 40, a: 255)
        for preset in FilterPreset.allCases {
            let out = try ImageFilters.apply(to: src, preset: preset)
            #expect(out.width == 64 && out.height == 64)
        }
        let mono = try ImageFilters.apply(
            to: src,
            preset: .mono,
            adjustments: Adjustments(
                brightness: -0.05,
                contrast: 1.1,
                saturation: 0.9,
                exposure: 0.1,
                warmth: 0.2,
                sharpness: 0.3,
                vignette: 0.4
            )
        )
        #expect(mono.width == 64 && mono.height == 64)
    }

    @Test("Renderer draws text, shape, and sticker layers")
    func renderTextShapeStickerLayers() throws {
        var doc = EditorDocument(
            canvasSize: CGSize(width: 200, height: 200),
            background: .solid(.black)
        )
        doc.add(Layer(
            name: "GreenBox",
            kind: .shape(ShapeSpec(kind: .roundedRect(cornerRadius: 8), size: CGSize(width: 100, height: 100), strokeColor: .white, fillColor: .green, lineWidth: 2)),
            transform: LayerTransform(position: CGPoint(x: 100, y: 100), scale: 1.0, rotation: 0)
        ))
        doc.add(Layer(
            name: "Label",
            kind: .text(TextSpec(string: "Recorte", size: 20, color: .white, stroke: TextStrokeSpec(color: .black, width: 1), background: .red)),
            transform: LayerTransform(position: CGPoint(x: 100, y: 150), scale: 1.0, rotation: 0)
        ))
        doc.add(Layer(
            name: "StarSticker",
            kind: .sticker(.emoji("⭐", pointSize: 28)),
            transform: LayerTransform(position: CGPoint(x: 100, y: 50), scale: 1.0, rotation: 0)
        ))
        let img = try Renderer.render(doc, 1.0)
        #expect(img.width == 200 && img.height == 200)
        // Center of GreenBox at (100, 100) should be green
        let center = Self.pixelRGBA(in: img, x: 100, y: 100)
        #expect(center.g > 200 && center.r < 30)
    }

    // MARK: - 4. Renderer Composites Layers
    @Test("Renderer composites 2 layers and checks pixel colors")
    func renderTwoLayersChecksPixels() throws {
        let bgRed = Self.makeSolidImage(width: 100, height: 100, r: 255, g: 0, b: 0, a: 255)
        let fgBlue = Self.makeSolidImage(width: 40, height: 40, r: 0, g: 0, b: 255, a: 255)

        let layer1 = Layer(
            name: "RedBase",
            kind: .image(SendableImage(bgRed)),
            transform: LayerTransform(position: CGPoint(x: 50, y: 50), scale: 1.0, rotationDegrees: 0)
        )
        let layer2 = Layer(
            name: "BlueOverlay",
            kind: .image(SendableImage(fgBlue)),
            transform: LayerTransform(position: CGPoint(x: 50, y: 50), scale: 1.0, rotationDegrees: 0)
        )

        let doc = EditorDocument(
            canvasSize: CGSize(width: 100, height: 100),
            background: .transparent,
            layers: [layer1, layer2]
        )

        let output = try Renderer.render(doc, scale: 1.0)
        #expect(output.width == 100 && output.height == 100)

        // Outer corner (10, 10) only covered by layer1 (Red)
        let outer = Self.pixelRGBA(in: output, x: 10, y: 10)
        #expect(outer.r > 240 && outer.g < 15 && outer.b < 15 && outer.a == 255)

        // Center (50, 50) covered by layer2 (Blue) on top of layer1
        let center = Self.pixelRGBA(in: output, x: 50, y: 50)
        #expect(center.b > 240 && center.r < 15 && center.g < 15 && center.a == 255)
    }

    // MARK: - 5. UndoStack<State>
    @Test("UndoStack push, undo, redo, canUndo, canRedo")
    func undoStackOperations() {
        var stack = UndoStack<Int>(initial: 1)
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.current == 1)

        stack.push(2)
        stack.push(3)
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.current == 3)

        let u1 = stack.undo()
        #expect(u1 == 2)
        #expect(stack.current == 2)
        #expect(stack.canUndo)
        #expect(stack.canRedo)

        let r1 = stack.redo()
        #expect(r1 == 3)
        #expect(stack.current == 3)
        #expect(!stack.canRedo)

        // Pushing after undo clears redo history
        _ = stack.undo()
        stack.push(42)
        #expect(stack.current == 42)
        #expect(!stack.canRedo)
    }
}
