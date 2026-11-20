import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExportFormat: Sendable, Equatable {
    case png
    case jpeg(quality: Double = 0.9)
    case heic(quality: Double = 0.9)

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

public enum ImageExportError: Error, Sendable, Equatable {
    case destinationCreationFailed
    case encodingFailed
    case writeFailed(URL)
}

public enum ImageExporter: Sendable {
    public static func encode(_ image: CGImage, format: ImageExportFormat) throws -> Data {
        let normalized = normalizeColorSpaceIfNeeded(image)
        return try encode(normalized, utType: format.utType, quality: compressionQuality(for: format))
    }

    public static func encodeTIFF(_ image: CGImage) throws -> Data {
        let normalized = normalizeColorSpaceIfNeeded(image)
        return try encode(normalized, utType: .tiff, quality: nil)
    }

    public static func export(_ image: CGImage, to url: URL, format: ImageExportFormat) throws {
        let data = try encode(image, format: format)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImageExportError.writeFailed(url)
        }
    }

    public static func export(_ image: CGImage, format: ImageExportFormat, to url: URL) throws {
        try export(image, to: url, format: format)
    }

    private static func compressionQuality(for format: ImageExportFormat) -> Double? {
        switch format {
        case .png:
            return nil
        case .jpeg(let quality), .heic(let quality):
            return max(0.0, min(1.0, quality))
        }
    }

    private static func encode(_ image: CGImage, utType: UTType, quality: Double?) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageExportError.destinationCreationFailed
        }

        var options: [CFString: Any] = [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.encodingFailed
        }

        return mutableData as Data
    }

    private static func normalizeColorSpaceIfNeeded(_ image: CGImage) -> CGImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            return image
        }
        if image.colorSpace?.name == CGColorSpace.sRGB {
            return image
        }
        return image.copy(colorSpace: sRGB) ?? image
    }
}
