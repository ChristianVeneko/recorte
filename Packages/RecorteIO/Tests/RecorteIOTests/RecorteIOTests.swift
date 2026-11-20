import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RecorteIO

@Suite("RecorteIO Tests")
struct RecorteIOTests {
    private static func makeTestImage(width: Int, height: Int, alpha: UInt8, uniform: Bool = false) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                // Premultiplied RGBA
                let a = uniform ? alpha : ((x < width / 2) ? alpha : 255)
                let r = UInt8((Int(200) * Int(a)) / 255)
                let g = UInt8((Int(100) * Int(a)) / 255)
                let b = UInt8((Int(50) * Int(a)) / 255)
                pixelData[offset + 0] = r
                pixelData[offset + 1] = g
                pixelData[offset + 2] = b
                pixelData[offset + 3] = a
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            Issue.record("Failed to create test CGImage")
            throw ImageImportError.decodingFailed
        }
        return image
    }

    private static func pixelAlpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return 255
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = y * bytesPerRow + x * 4
        return pixels[offset + 3]
    }

    @Test("PNG export and import round trip preserves dimensions and alpha")
    func pngRoundTrip() throws {
        let original = try Self.makeTestImage(width: 32, height: 24, alpha: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("sample.png")
        try ImageExporter.export(original, to: fileURL, format: .png)

        let imported = try ImageImporter.importFromURL(fileURL)
        #expect(imported.image.width == 32)
        #expect(imported.image.height == 24)
        #expect(imported.suggestedName == "sample")
        #expect(Self.pixelAlpha(of: imported.image, x: 2, y: 2) == 0)
        #expect(Self.pixelAlpha(of: imported.image, x: 28, y: 2) == 255)
    }

    @Test("JPEG export and import round trip preserves dimensions")
    func jpegRoundTrip() throws {
        let original = try Self.makeTestImage(width: 40, height: 30, alpha: 255)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("photo.jpg")
        try ImageExporter.export(original, to: fileURL, format: .jpeg(quality: 0.9))

        let imported = try ImageImporter.importFromURL(fileURL)
        #expect(imported.image.width == 40)
        #expect(imported.image.height == 30)
        #expect(imported.suggestedName == "photo")
        #expect(Self.pixelAlpha(of: imported.image, x: 2, y: 2) == 255)
    }

    @Test("HEIC export and import round trip preserves dimensions and alpha")
    func heicRoundTrip() throws {
        let original = try Self.makeTestImage(width: 64, height: 64, alpha: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("alpha.heic")
        try ImageExporter.export(original, to: fileURL, format: .heic(quality: 0.95))

        let imported = try ImageImporter.importFromURL(fileURL)
        #expect(imported.image.width == 64)
        #expect(imported.image.height == 64)
        #expect(imported.suggestedName == "alpha")
        #expect(Self.pixelAlpha(of: imported.image, x: 4, y: 4) < 15)
        #expect(Self.pixelAlpha(of: imported.image, x: 56, y: 4) > 240)
    }

    @Test("Pasteboard round trip writes PNG and TIFF and imports back")
    func pasteboardRoundTrip() throws {
        let pb = NSPasteboard(name: .init(UUID().uuidString))
        defer { pb.releaseGlobally() }

        let original = try Self.makeTestImage(width: 28, height: 20, alpha: 0)
        let copied = Clipboard.copy(original, to: pb)
        #expect(copied)
        #expect(pb.data(forType: .png) != nil)
        #expect(pb.data(forType: .tiff) != nil)

        let imported = try ImageImporter.importFromPasteboard(pb)
        #expect(imported.image.width == 28)
        #expect(imported.image.height == 20)
        #expect(Self.pixelAlpha(of: imported.image, x: 2, y: 2) == 0)
        #expect(Self.pixelAlpha(of: imported.image, x: 24, y: 2) == 255)
    }

    @Test("Pasteboard imports file URL of image and TIFF screenshot data")
    func pasteboardFileURLAndTIFF() throws {
        let original = try Self.makeTestImage(width: 18, height: 14, alpha: 255)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("from-finder.png")
        try ImageExporter.export(original, to: fileURL, format: .png)

        let pbURL = NSPasteboard(name: .init(UUID().uuidString))
        defer { pbURL.releaseGlobally() }
        pbURL.clearContents()
        pbURL.writeObjects([fileURL as NSURL])

        let importedFromURL = try ImageImporter.importFromPasteboard(pbURL)
        #expect(importedFromURL.image.width == 18)
        #expect(importedFromURL.image.height == 14)
        #expect(importedFromURL.suggestedName == "from-finder")

        // Simulate Cmd+Ctrl+Shift+4 screenshot placing TIFF data on pasteboard
        let pbTIFF = NSPasteboard(name: .init(UUID().uuidString))
        defer { pbTIFF.releaseGlobally() }
        let tiffData = try ImageExporter.encodeTIFF(original)
        pbTIFF.clearContents()
        pbTIFF.setData(tiffData, forType: .tiff)

        let importedFromTIFF = try ImageImporter.importFromPasteboard(pbTIFF)
        #expect(importedFromTIFF.image.width == 18)
        #expect(importedFromTIFF.image.height == 14)
        #expect(importedFromTIFF.suggestedName == "Screenshot")
    }

    @Test("NSItemProvider import reads registered image data")
    func itemProviderImport() async throws {
        let original = try Self.makeTestImage(width: 22, height: 16, alpha: 255)
        let pngData = try ImageExporter.encode(original, format: .png)

        let provider = NSItemProvider()
        provider.suggestedName = "dropped-item"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(pngData, nil)
            return nil
        }

        let imported = try await ImageImporter.importFromItemProvider(provider)
        #expect(imported.image.width == 22)
        #expect(imported.image.height == 16)
        #expect(imported.suggestedName == "dropped-item")
    }

    @Test("ShareService writes temporary PNG file and constructs ShareableImage")
    func shareServiceTempPNG() throws {
        let original = try Self.makeTestImage(width: 20, height: 20, alpha: 128)
        let tempURL = try ShareService.writeTemporaryPNG(original, name: "SharedShot")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: tempURL.path))
        let imported = try ImageImporter.importFromURL(tempURL)
        #expect(imported.image.width == 20)
        #expect(imported.image.height == 20)
        #expect(imported.suggestedName == "SharedShot")

        let shareable = ShareableImage(image: original, suggestedName: "SharedShot")
        #expect(shareable.image.width == 20)
        #expect(shareable.suggestedName == "SharedShot")
    }

    @Test("StickerCatalog is non-empty and unique")
    func stickerCatalogNonEmptyAndUnique() {
        #expect(!StickerCatalog.emojiCategories.isEmpty)
        for category in StickerCatalog.emojiCategories {
            #expect(!category.name.isEmpty)
            #expect(!category.emojis.isEmpty)
        }
        let allEmojis = StickerCatalog.allEmojis
        #expect(!allEmojis.isEmpty)
        #expect(Set(allEmojis).count == allEmojis.count)
        #expect(StickerCatalog.emojisByCategory.count == StickerCatalog.emojiCategories.count)

        let symbols = StickerCatalog.sfSymbols
        #expect(!symbols.isEmpty)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("SubjectLifter throws on a blank image")
    func subjectLifterThrowsOnBlankImage() async throws {
        let transparentBlank = try Self.makeTestImage(width: 64, height: 64, alpha: 0, uniform: true)
        await #expect(throws: SubjectLifterError.noSubjectFound) {
            _ = try await SubjectLifter.liftSubject(transparentBlank)
        }

        let solidBlank = try Self.makeTestImage(width: 64, height: 64, alpha: 255, uniform: true)
        await #expect(throws: SubjectLifterError.noSubjectFound) {
            _ = try await SubjectLifter.liftSubject(solidBlank)
        }
    }
}
