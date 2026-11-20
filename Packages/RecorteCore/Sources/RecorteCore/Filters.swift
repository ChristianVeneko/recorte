import Foundation
import CoreGraphics
import CoreImage

public enum FilterPreset: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case none
    case mono
    case noir
    case chrome
    case fade
    case instant
    case process
    case transfer
    case vivid
    case warm
    case cool
}

public struct Adjustments: Sendable, Equatable, Hashable, Codable {
    /// Brightness offset (-1.0 ... 1.0, default 0.0)
    public var brightness: Double
    /// Contrast multiplier (0.25 ... 4.0, default 1.0)
    public var contrast: Double
    /// Saturation multiplier (0.0 ... 2.0, default 1.0)
    public var saturation: Double
    /// Exposure EV (-2.0 ... 2.0, default 0.0)
    public var exposure: Double
    /// Warmth shift (-1.0 ... 1.0, default 0.0; maps to temperature delta around 6500K)
    public var warmth: Double
    /// Sharpness intensity (0.0 ... 2.0, default 0.0)
    public var sharpness: Double
    /// Vignette intensity (0.0 ... 2.0, default 0.0)
    public var vignette: Double

    public init(
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 1.0,
        exposure: Double = 0.0,
        warmth: Double = 0.0,
        sharpness: Double = 0.0,
        vignette: Double = 0.0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.exposure = exposure
        self.warmth = warmth
        self.sharpness = sharpness
        self.vignette = vignette
    }

    public var isIdentity: Bool {
        brightness == 0.0 &&
        contrast == 1.0 &&
        saturation == 1.0 &&
        exposure == 0.0 &&
        warmth == 0.0 &&
        sharpness == 0.0 &&
        vignette == 0.0
    }
}

public enum FilterError: Error, Sendable, Equatable {
    case renderFailed
}

public enum ImageFilters {
    /// Shared thread-safe `CIContext` for all Core Image operations.
    public static let sharedContext: CIContext = {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: false
        ])
    }()

    /// Applies `preset` and `adjustments` to `cgImage` using the shared `CIContext`.
    public static func apply(
        to cgImage: CGImage,
        preset: FilterPreset = .none,
        adjustments: Adjustments = Adjustments()
    ) throws -> CGImage {
        if preset == .none && adjustments.isIdentity {
            return cgImage
        }

        let extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        var current = CIImage(cgImage: cgImage)

        // 1. Apply FilterPreset
        switch preset {
        case .none:
            break
        case .mono:
            current = applyNamedFilter("CIPhotoEffectMono", to: current)
        case .noir:
            current = applyNamedFilter("CIPhotoEffectNoir", to: current)
        case .chrome:
            current = applyNamedFilter("CIPhotoEffectChrome", to: current)
        case .fade:
            current = applyNamedFilter("CIPhotoEffectFade", to: current)
        case .instant:
            current = applyNamedFilter("CIPhotoEffectInstant", to: current)
        case .process:
            current = applyNamedFilter("CIPhotoEffectProcess", to: current)
        case .transfer:
            current = applyNamedFilter("CIPhotoEffectTransfer", to: current)
        case .vivid:
            current = applyNamedFilter("CIVibrance", to: current, parameters: ["inputAmount": 0.75])
        case .warm:
            current = applyTemperature(to: current, targetNeutralX: 8000)
        case .cool:
            current = applyTemperature(to: current, targetNeutralX: 5000)
        }

        // 2. Apply Adjustments
        if adjustments.brightness != 0.0 || adjustments.contrast != 1.0 || adjustments.saturation != 1.0 {
            current = applyNamedFilter(
                "CIColorControls",
                to: current,
                parameters: [
                    kCIInputBrightnessKey: adjustments.brightness,
                    kCIInputContrastKey: adjustments.contrast,
                    kCIInputSaturationKey: adjustments.saturation
                ]
            )
        }

        if adjustments.exposure != 0.0 {
            current = applyNamedFilter(
                "CIExposureAdjust",
                to: current,
                parameters: [kCIInputEVKey: adjustments.exposure]
            )
        }

        if adjustments.warmth != 0.0 {
            // Map warmth (-1...1) to temperature shift around 6500K
            let targetTemp = 6500.0 + (adjustments.warmth * 2000.0)
            current = applyTemperature(to: current, targetNeutralX: targetTemp)
        }

        if adjustments.sharpness > 0.0 {
            current = applyNamedFilter(
                "CISharpenLuminance",
                to: current,
                parameters: [kCIInputSharpnessKey: adjustments.sharpness]
            )
        }

        if adjustments.vignette > 0.0 {
            let radius = max(extent.width, extent.height) * 0.55
            current = applyNamedFilter(
                "CIVignette",
                to: current,
                parameters: [
                    kCIInputIntensityKey: adjustments.vignette,
                    kCIInputRadiusKey: radius
                ]
            )
        }

        let cropped = current.cropped(to: extent)
        guard let output = sharedContext.createCGImage(cropped, from: extent) else {
            throw FilterError.renderFailed
        }
        return output
    }

    private static func applyNamedFilter(
        _ name: String,
        to input: CIImage,
        parameters: [String: Any] = [:]
    ) -> CIImage {
        guard let filter = CIFilter(name: name) else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        for (k, v) in parameters {
            filter.setValue(v, forKey: k)
        }
        return filter.outputImage ?? input
    }

    private static func applyTemperature(to input: CIImage, targetNeutralX: Double) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: CGFloat(targetNeutralX), y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? input
    }
}
