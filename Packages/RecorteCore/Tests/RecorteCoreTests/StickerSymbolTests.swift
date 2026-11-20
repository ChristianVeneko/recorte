import Testing
import CoreGraphics
import Foundation
@testable import RecorteCore

@Suite("Sticker symbols")
struct StickerSymbolTests {
    /// Bounding box of pixels with alpha > 0.
    private func inkBounds(_ grid: PixelGrid) -> (width: Int, height: Int) {
        var minX = grid.width, minY = grid.height, maxX = -1, maxY = -1
        for y in 0..<grid.height {
            for x in 0..<grid.width where grid.pixel(x: x, y: y).a > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? (0, 0) : (maxX - minX + 1, maxY - minY + 1)
    }

    @Test("SF Symbol sticker draws the symbol, not its name as text")
    func sfSymbolDrawsIcon() throws {
        let layer = Layer(
            name: "Star sticker",
            kind: .sticker(.sfSymbol("star.fill", pointSize: 64, tintColor: RGBAColor(r: 1, g: 0, b: 0))),
            transform: LayerTransform(position: CGPoint(x: 200, y: 100))
        )
        let doc = EditorDocument(canvasSize: CGSize(width: 400, height: 200), background: .transparent, layers: [layer])
        let bounds = inkBounds(PixelGrid(try Renderer.render(doc, scale: 1.0)))

        // The literal text "star.fill" is several times wider than tall; a star glyph is roughly square.
        #expect(bounds.width > 20 && bounds.height > 20)
        #expect(Double(bounds.width) / Double(bounds.height) < 1.6)
    }
}
