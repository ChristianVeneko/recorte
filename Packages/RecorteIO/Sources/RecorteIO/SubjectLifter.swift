import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

public enum SubjectLifterError: Error, Sendable, Equatable {
    case noSubjectFound
    case invalidImage
    case maskGenerationFailed
}

public enum SubjectLifter: Sendable {
    public static func liftSubject(_ image: CGImage) async throws -> CGImage {
        guard image.width > 0, image.height > 0 else {
            throw SubjectLifterError.invalidImage
        }

        // Fast-fail if the image is completely uniform or completely transparent (blank)
        if isUniformOrBlank(image) {
            throw SubjectLifterError.noSubjectFound
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw SubjectLifterError.noSubjectFound
        }

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw SubjectLifterError.noSubjectFound
        }

        let maskedBuffer: CVPixelBuffer
        do {
            maskedBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
        } catch {
            throw SubjectLifterError.maskGenerationFailed
        }

        let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
        let ciContext = CIContext(options: nil)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(maskedBuffer),
            height: CVPixelBufferGetHeight(maskedBuffer)
        )

        guard let outputImage = ciContext.createCGImage(ciImage, from: rect) else {
            throw SubjectLifterError.maskGenerationFailed
        }

        if isCompletelyTransparent(outputImage) {
            throw SubjectLifterError.noSubjectFound
        }

        return outputImage
    }

    private static func isUniformOrBlank(_ image: CGImage) -> Bool {
        let sampleWidth = min(image.width, 64)
        let sampleHeight = min(image.height, 64)
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        let r0 = pixels[0]
        let g0 = pixels[1]
        let b0 = pixels[2]
        let a0 = pixels[3]

        var hasAnyNonTransparent = a0 > 0
        var isCompletelyUniform = true

        for index in stride(from: 4, to: pixels.count, by: 4) {
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let a = pixels[index + 3]

            if a > 0 {
                hasAnyNonTransparent = true
            }
            if r != r0 || g != g0 || b != b0 || a != a0 {
                isCompletelyUniform = false
                if hasAnyNonTransparent {
                    break
                }
            }
        }

        return !hasAnyNonTransparent || isCompletelyUniform
    }

    private static func isCompletelyTransparent(_ image: CGImage) -> Bool {
        let sampleWidth = min(image.width, 64)
        let sampleHeight = min(image.height, 64)
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        for index in stride(from: 3, to: pixels.count, by: 4) {
            if pixels[index] > 0 {
                return false
            }
        }
        return true
    }
}
