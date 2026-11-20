import AppKit
import CoreGraphics
import Foundation

public enum Clipboard: Sendable {
    @discardableResult
    public static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let pngData = try? ImageExporter.encode(image, format: .png),
              let tiffData = try? ImageExporter.encodeTIFF(image) else {
            return false
        }

        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        let wrotePNG = pasteboard.setData(pngData, forType: .png)
        let wroteTIFF = pasteboard.setData(tiffData, forType: .tiff)
        return wrotePNG && wroteTIFF
    }
}
