import Foundation

public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case move
    case crop
    case lasso
    case perspective
    case clone
    case deform
    case text
    case shapes
    case stickers
    case draw

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .move: "Move"
        case .crop: "Crop"
        case .lasso: "Lasso Cutout"
        case .perspective: "Perspective"
        case .clone: "Clone Stamp"
        case .deform: "Deform"
        case .text: "Text"
        case .shapes: "Shapes"
        case .stickers: "Stickers"
        case .draw: "Draw"
        }
    }

    public var systemImage: String {
        switch self {
        case .move: "cursorarrow"
        case .crop: "crop"
        case .lasso: "lasso"
        case .perspective: "perspective"
        case .clone: "seal"
        case .deform: "hurricane"
        case .text: "textformat"
        case .shapes: "square.on.circle"
        case .stickers: "face.smiling"
        case .draw: "paintbrush.pointed"
        }
    }

    public var shortcutDisplay: String? {
        switch self {
        case .move: "V"
        case .crop: "C"
        case .lasso: "L"
        case .perspective: "P"
        case .clone: "K"
        case .deform: "W"
        case .text: "T"
        case .shapes: "S"
        case .stickers: nil
        case .draw: "B"
        }
    }
}
