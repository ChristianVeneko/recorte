import CoreGraphics
import Foundation
import Testing
@testable import RecorteCore

@Suite("S21 StickerSpec Background Core Tests")
struct StickerBackgroundTests {

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorte-sticker-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("StickerSpec decodes legacy JSON without background field as nil")
    func legacyStickerSpecDecodesWithoutBackground() throws {
        let legacyJSON = """
        {
            "content": { "sfSymbol": { "_0": "star.fill" } },
            "pointSize": 64.0,
            "tintColor": { "r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0 }
        }
        """
        let decoded = try JSONDecoder().decode(StickerSpec.self, from: Data(legacyJSON.utf8))
        #expect(decoded.content == .sfSymbol("star.fill"))
        #expect(decoded.pointSize == 64.0)
        #expect(decoded.tintColor == .white)
        #expect(decoded.background == nil)
    }

    @Test("RecorteProject save/load round-trip preserves StickerSpec.background")
    func projectSaveLoadRoundTripPreservesStickerBackground() throws {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let packageURL = tempDir.appendingPathComponent("StickerBg.recorte", isDirectory: true)

        let bgColor = RGBAColor(r: 0.15, g: 0.45, b: 0.85, a: 1.0)
        let emojiSticker = Layer(
            name: "Sticker 🔥",
            kind: .sticker(.emoji("🔥", pointSize: 72, background: bgColor)),
            transform: LayerTransform(position: CGPoint(x: 100, y: 100))
        )
        let symbolSticker = Layer(
            name: "Star sticker",
            kind: .sticker(.sfSymbol("star.fill", pointSize: 64, tintColor: .white, background: .black)),
            transform: LayerTransform(position: CGPoint(x: 220, y: 100))
        )
        let plainSticker = Layer(
            name: "Heart sticker",
            kind: .sticker(.sfSymbol("heart.fill", pointSize: 48, tintColor: .red)),
            transform: LayerTransform(position: CGPoint(x: 160, y: 180))
        )

        let original = EditorDocument(
            canvasSize: CGSize(width: 320, height: 240),
            background: .transparent,
            layers: [emojiSticker, symbolSticker, plainSticker]
        )

        try RecorteProject.save(original, to: packageURL)
        let loaded = try RecorteProject.load(from: packageURL)

        #expect(loaded.layers.count == 3)
        if case .sticker(let loadedEmoji) = loaded.layers[0].kind {
            #expect(loadedEmoji.background == bgColor)
        } else {
            Issue.record("Expected emoji sticker layer")
        }
        if case .sticker(let loadedSymbol) = loaded.layers[1].kind {
            #expect(loadedSymbol.background == .black)
        } else {
            Issue.record("Expected SF Symbol sticker layer")
        }
        if case .sticker(let loadedPlain) = loaded.layers[2].kind {
            #expect(loadedPlain.background == nil)
        } else {
            Issue.record("Expected plain sticker layer")
        }
    }

    @Test("Renderer draws StickerSpec.background as a rounded rect behind the sticker")
    func rendererDrawsStickerBackgroundRoundedRect() throws {
        let spec = StickerSpec.emoji("⭐", pointSize: 80, background: .blue)
        let doc = EditorDocument(
            canvasSize: CGSize(width: 240, height: 240),
            background: .transparent,
            layers: [
                Layer(
                    name: "Sticker ⭐",
                    kind: .sticker(spec),
                    transform: LayerTransform(position: CGPoint(x: 120, y: 120))
                )
            ]
        )

        let img = try Renderer.render(doc, scale: 1.0)
        let grid = PixelGrid(img)

        // Inside the rounded badge (near top-left interior of badge, outside the emoji glyph) should be solid blue
        let insideBadge = grid.pixel(x: 120 - 44, y: 120 - 44)
        #expect(insideBadge.a > 240, "Expected opaque badge pixel, got alpha \(insideBadge.a)")
        #expect(insideBadge.b > 220)
        #expect(insideBadge.r < 30)

        // Very corner of the bounding square (outside the rounded corner radius) should remain transparent
        let badgeHalf = Int(ceil(80.0 * 1.45) / 2.0)
        let outerCorner = grid.pixel(x: 120 - badgeHalf, y: 120 - badgeHalf)
        #expect(outerCorner.a == 0, "Expected rounded corner at (\(120 - badgeHalf), \(120 - badgeHalf)) to be transparent")

        // Outside the sticker completely should be transparent
        let farOutside = grid.pixel(x: 4, y: 4)
        #expect(farOutside.a == 0)
    }
}
