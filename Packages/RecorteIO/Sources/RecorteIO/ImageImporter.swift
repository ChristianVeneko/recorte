import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImportedImage: Sendable {
    public let image: CGImage
    public let suggestedName: String

    public init(image: CGImage, suggestedName: String) {
        self.image = image
        self.suggestedName = suggestedName
    }
}

public enum ImageImportError: Error, Sendable, Equatable {
    case noImageOnPasteboard
    case unreadableFile(URL)
    case unsupportedProvider
    case decodingFailed
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

public enum ImageImporter: Sendable {
    public static func importFromPasteboard(_ pasteboard: NSPasteboard = .general) throws -> ImportedImage {
        // 1. File URLs of images copied in Finder or dragged to pasteboard
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            for url in urls {
                if let imported = try? importFromURL(url) {
                    return imported
                }
            }
        }

        // 2. Direct PNG data (screenshots, web images, Clipboard.copy)
        if let pngData = pasteboard.data(forType: .png),
           let imported = try? importFromData(pngData, suggestedName: "Clipboard") {
            return imported
        }

        // 3. Direct TIFF data (macOS Cmd+Ctrl+Shift+4 screenshots, AppKit copies)
        if let tiffData = pasteboard.data(forType: .tiff),
           let imported = try? importFromData(tiffData, suggestedName: "Screenshot") {
            return imported
        }

        // 4. Any other image UTType present on pasteboard items
        if let items = pasteboard.pasteboardItems {
            for item in items {
                for type in item.types {
                    if let utType = UTType(type.rawValue),
                       utType.conforms(to: .image),
                       let data = item.data(forType: type),
                       let imported = try? importFromData(data, suggestedName: "Clipboard") {
                        return imported
                    }
                }
            }
        }

        throw ImageImportError.noImageOnPasteboard
    }

    public static func importFromURL(_ url: URL) throws -> ImportedImage {
        guard url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImageImportError.unreadableFile(url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImageImportError.unreadableFile(url)
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let suggestedName = baseName.isEmpty ? "Image" : baseName
        return try importFromData(data, suggestedName: suggestedName)
    }

    public static func importFromData(_ data: Data, suggestedName: String = "Image") throws -> ImportedImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw ImageImportError.decodingFailed
        }

        let cleanName = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportedImage(
            image: cgImage,
            suggestedName: cleanName.isEmpty ? "Image" : cleanName
        )
    }

    public static func importFromItemProvider(_ provider: NSItemProvider) async throws -> ImportedImage {
        let fallbackName = provider.suggestedName ?? "Dropped Image"
        let boxedProvider = UncheckedSendableBox(value: provider)

        // Check if provider offers a concrete image type directly
        let registeredTypes = provider.registeredTypeIdentifiers
        let imageTypeIdentifier = registeredTypes.first { identifier in
            guard let utType = UTType(identifier) else { return false }
            return utType.conforms(to: .image)
        } ?? (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? UTType.image.identifier : nil)

        if let imageTypeIdentifier {
            let data = try await loadData(from: boxedProvider, typeIdentifier: imageTypeIdentifier)
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
               let imported = try? importFromURL(url) {
                return imported
            }
            let cleanSuggested = (fallbackName as NSString).deletingPathExtension
            return try importFromData(data, suggestedName: cleanSuggested.isEmpty ? fallbackName : cleanSuggested)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let data = try await loadData(from: boxedProvider, typeIdentifier: UTType.fileURL.identifier)
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                throw ImageImportError.unsupportedProvider
            }
            return try importFromURL(url)
        }

        throw ImageImportError.unsupportedProvider
    }

    private static func loadData(
        from boxedProvider: UncheckedSendableBox<NSItemProvider>,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            boxedProvider.value.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else if error != nil {
                    continuation.resume(throwing: ImageImportError.decodingFailed)
                } else {
                    continuation.resume(throwing: ImageImportError.unsupportedProvider)
                }
            }
        }
    }
}
