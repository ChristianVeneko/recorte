import AppKit
import RecorteCore
import SwiftUI

extension RGBAColor {
    public var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    public init(swiftUIColor: Color) {
        let nsColor = NSColor(swiftUIColor).usingColorSpace(.sRGB) ?? NSColor.white
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha))
    }
}
