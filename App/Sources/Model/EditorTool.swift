import Foundation

public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case move
    case crop
    case text
    case shapes
    case stickers
    case draw

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .move: "Move"
        case .crop: "Crop"
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
        case .text: "T"
        case .shapes: "S"
        case .stickers: nil
        case .draw: "B"
        }
    }
}
