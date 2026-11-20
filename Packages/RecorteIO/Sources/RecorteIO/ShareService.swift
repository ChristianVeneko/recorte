import AppKit
import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public struct ShareableImage: Transferable, Sendable {
    public let image: CGImage
    public let suggestedName: String

    public init(image: CGImage, suggestedName: String = "Recorte") {
        self.image = image
        self.suggestedName = suggestedName
    }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try ImageExporter.encode(item.image, format: .png)
        }
        .suggestedFileName { item in
            let base = ShareService.sanitizeFileName(item.suggestedName)
            return base.hasSuffix(".png") ? base : "\(base).png"
        }
    }
}

public enum ShareServiceError: Error, Sendable, Equatable {
    case airDropUnavailable
    case temporaryFileCreationFailed
}

public enum ShareService: Sendable {
    public static func writeTemporaryPNG(_ image: CGImage, name: String = "Recorte") throws -> URL {
        let baseName = sanitizeFileName(name)
        let fileName = baseName.hasSuffix(".png") ? baseName : "\(baseName).png"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorteShare-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent(fileName)
            try ImageExporter.export(image, to: fileURL, format: .png)
            return fileURL
        } catch {
            throw ShareServiceError.temporaryFileCreationFailed
        }
    }

    @MainActor
    public static func airDropService() -> NSSharingService? {
        NSSharingService(named: .sendViaAirDrop)
    }

    @MainActor
    @discardableResult
    public static func shareViaAirDrop(_ image: CGImage, name: String = "Recorte") throws -> URL {
        let tempURL = try writeTemporaryPNG(image, name: name)
        guard let service = airDropService() else {
            throw ShareServiceError.airDropUnavailable
        }
        service.perform(withItems: [tempURL])
        return tempURL
    }

    internal static func sanitizeFileName(_ rawName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = rawName
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recorte" : cleaned
    }
}
