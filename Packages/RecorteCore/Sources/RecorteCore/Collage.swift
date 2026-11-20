import Foundation
import CoreGraphics

public enum CollageError: Error, Sendable, Equatable {
    case invalidCanvasSize
    case contextCreationFailed
    case imageCreationFailed
}

/// Collage layout presets spanning 2 to 6 cells (grid and mosaic) plus a plain free-style canvas.
public enum CollageLayout: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case freeStyle
    // 2 cells
    case twoHorizontal
    case twoVertical
    // 3 cells
    case threeGrid
    case threeMosaicLeft
    case threeMosaicTop
    // 4 cells
    case fourGrid
    case fourMosaic
    // 5 cells
    case fiveMosaic
    // 6 cells
    case sixGrid
    case sixMosaic

    /// Number of structured cells in this layout (`0` for `.freeStyle`).
    public var cellCount: Int {
        normalizedCells.count
    }

    /// Normalized cell rects in `[0, 1] x [0, 1]` using top-left origin, y down.
    public var normalizedCells: [CGRect] {
        switch self {
        case .freeStyle:
            return []

        case .twoHorizontal:
            return [
                CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),
                CGRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
            ]

        case .twoVertical:
            return [
                CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5),
                CGRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
            ]

        case .threeGrid:
            let third = 1.0 / 3.0
            return [
                CGRect(x: 0.0, y: 0.0, width: third, height: 1.0),
                CGRect(x: third, y: 0.0, width: third, height: 1.0),
                CGRect(x: 2.0 * third, y: 0.0, width: third, height: 1.0)
            ]

        case .threeMosaicLeft:
            return [
                CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),
                CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            ]

        case .threeMosaicTop:
            return [
                CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5),
                CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            ]

        case .fourGrid:
            return [
                CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
                CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            ]

        case .fourMosaic:
            let third = 1.0 / 3.0
            return [
                CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),
                CGRect(x: 0.5, y: 0.0, width: 0.5, height: third),
                CGRect(x: 0.5, y: third, width: 0.5, height: third),
                CGRect(x: 0.5, y: 2.0 * third, width: 0.5, height: third)
            ]

        case .fiveMosaic:
            let third = 1.0 / 3.0
            return [
                CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
                CGRect(x: 0.0, y: 0.5, width: third, height: 0.5),
                CGRect(x: third, y: 0.5, width: third, height: 0.5),
                CGRect(x: 2.0 * third, y: 0.5, width: third, height: 0.5)
            ]

        case .sixGrid:
            let third = 1.0 / 3.0
            return [
                CGRect(x: 0.0, y: 0.0, width: third, height: 0.5),
                CGRect(x: third, y: 0.0, width: third, height: 0.5),
                CGRect(x: 2.0 * third, y: 0.0, width: third, height: 0.5),
                CGRect(x: 0.0, y: 0.5, width: third, height: 0.5),
                CGRect(x: third, y: 0.5, width: third, height: 0.5),
                CGRect(x: 2.0 * third, y: 0.5, width: third, height: 0.5)
            ]

        case .sixMosaic:
            let third = 1.0 / 3.0
            let twoThirds = 2.0 / 3.0
            return [
                CGRect(x: 0.0, y: 0.0, width: twoThirds, height: twoThirds),
                CGRect(x: twoThirds, y: 0.0, width: third, height: third),
                CGRect(x: twoThirds, y: third, width: third, height: third),
                CGRect(x: 0.0, y: twoThirds, width: third, height: third),
                CGRect(x: third, y: twoThirds, width: third, height: third),
                CGRect(x: twoThirds, y: twoThirds, width: third, height: third)
            ]
        }
    }

    /// Computes concrete cell rects in top-left canvas coordinates with uniform outer margin and inner gap `spacing`.
    public func cellRects(in canvasSize: CGSize, spacing: CGFloat = 12.0) -> [CGRect] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        let s = max(0, min(spacing, min(canvasSize.width, canvasSize.height) * 0.2))
        let usableW = max(1.0, canvasSize.width - s)
        let usableH = max(1.0, canvasSize.height - s)

        return normalizedCells.map { norm in
            let x0 = norm.minX * usableW + s
            let x1 = norm.maxX * usableW
            let y0 = norm.minY * usableH + s
            let y1 = norm.maxY * usableH
            return CGRect(
                x: x0,
                y: y0,
                width: max(1.0, x1 - x0),
                height: max(1.0, y1 - y0)
            )
        }
    }

    /// Convenience factory delegating to `CollageBuilder.makeDocument`.
    public func makeDocument(
        images: [CGImage],
        canvasSize: CGSize = CGSize(width: 1200, height: 1200),
        background: CanvasBackground = .solid(.white),
        spacing: CGFloat = 12.0,
        cornerRadius: Double = 0.0
    ) throws -> EditorDocument {
        try CollageBuilder.makeDocument(
            layout: self,
            images: images,
            canvasSize: canvasSize,
            background: background,
            spacing: spacing,
            cornerRadius: cornerRadius
        )
    }
}

/// Builds collage `EditorDocument`s with aspect-fill cell fitting, spacing, and rounded corners.
public enum CollageBuilder {

    /// Produces an `EditorDocument` with `images` fitted (aspect-fill) into `layout`'s cells
    /// using `spacing` and `cornerRadius`. For `.freeStyle`, produces a plain canvas without grid cropping.
    public static func makeDocument(
        layout: CollageLayout,
        images: [CGImage],
        canvasSize: CGSize = CGSize(width: 1200, height: 1200),
        background: CanvasBackground = .solid(.white),
        spacing: CGFloat = 12.0,
        cornerRadius: Double = 0.0
    ) throws -> EditorDocument {
        guard canvasSize.width >= 1.0, canvasSize.height >= 1.0 else {
            throw CollageError.invalidCanvasSize
        }

        let frame: ImageFrame = cornerRadius > 0 ? .roundedCorners(radius: cornerRadius) : .none
        var doc = EditorDocument(canvasSize: canvasSize, background: background)

        if layout == .freeStyle {
            // Plain free-style canvas: place images uncropped around center with subtle stagger for multiple items
            let center = CGPoint(x: canvasSize.width / 2.0, y: canvasSize.height / 2.0)
            let count = images.count
            for (index, img) in images.enumerated() {
                let offset = count > 1 ? CGFloat(index - (count - 1) / 2) * 24.0 : 0.0
                let pos = CGPoint(x: center.x + offset, y: center.y + offset)
                let layer = Layer(
                    name: "Image \(index + 1)",
                    kind: .image(SendableImage(img, frame: frame)),
                    transform: LayerTransform(position: pos)
                )
                doc.add(layer)
            }
            return doc
        }

        let cells = layout.cellRects(in: canvasSize, spacing: spacing)
        for (index, (cellRect, image)) in zip(cells, images).enumerated() {
            let fitted = try aspectFill(image, into: cellRect.size)
            let layer = Layer(
                name: "Cell \(index + 1)",
                kind: .image(SendableImage(fitted, frame: frame)),
                transform: LayerTransform(position: CGPoint(x: cellRect.midX, y: cellRect.midY))
            )
            doc.add(layer)
        }

        return doc
    }

    /// Scales and center-crops `image` using aspect-fill to completely cover `targetSize`.
    public static func aspectFill(_ image: CGImage, into targetSize: CGSize) throws -> CGImage {
        let outW = max(1, Int(targetSize.width.rounded()))
        let outH = max(1, Int(targetSize.height.rounded()))
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0 else {
            throw CollageError.invalidCanvasSize
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CollageError.contextCreationFailed
        }

        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)))

        let scale = max(CGFloat(outW) / srcW, CGFloat(outH) / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawRect = CGRect(
            x: (CGFloat(outW) - drawW) / 2.0,
            y: (CGFloat(outH) - drawH) / 2.0,
            width: drawW,
            height: drawH
        )
        ctx.draw(image, in: drawRect)

        guard let output = ctx.makeImage() else {
            throw CollageError.imageCreationFailed
        }
        return output
    }
}
