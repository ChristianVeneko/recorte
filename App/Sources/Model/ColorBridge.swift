import AppKit
import RecorteCore
import SwiftUI

extension RGBAColor {
    public var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    public init(swiftUIColor: Color) {
        if let nsColor = NSColor(swiftUIColor).usingColorSpace(.sRGB) {
            var red: CGFloat = 1
            var green: CGFloat = 1
            var blue: CGFloat = 1
            var alpha: CGFloat = 1
            nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            self.init(
                r: min(max(Double(red), 0.0), 1.0),
                g: min(max(Double(green), 0.0), 1.0),
                b: min(max(Double(blue), 0.0), 1.0),
                a: min(max(Double(alpha), 0.0), 1.0)
            )
            return
        }

        let resolved = swiftUIColor.resolve(in: EnvironmentValues())
        self.init(
            r: min(max(Double(resolved.red), 0.0), 1.0),
            g: min(max(Double(resolved.green), 0.0), 1.0),
            b: min(max(Double(resolved.blue), 0.0), 1.0),
            a: min(max(Double(resolved.opacity), 0.0), 1.0)
        )
    }
}
