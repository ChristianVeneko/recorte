import Foundation

public struct EmojiCategory: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let emojis: [String]

    public init(name: String, emojis: [String]) {
        self.name = name
        self.emojis = emojis
    }
}

public enum StickerCatalog: Sendable {
    public static let emojiCategories: [EmojiCategory] = [
        EmojiCategory(
            name: "Reactions",
            emojis: ["😀", "😂", "🥹", "😍", "🤩", "😎", "🤔", "🤯", "🥳", "👀", "🔥", "💯"]
        ),
        EmojiCategory(
            name: "Gestures",
            emojis: ["👍", "👎", "👏", "🙌", "🤝", "✌️", "🤞", "🫶", "🫡", "💪", "👋", "🙏"]
        ),
        EmojiCategory(
            name: "Callouts",
            emojis: ["✅", "❌", "⚠️", "❗", "❓", "💡", "📌", "🎯", "🚀", "⭐", "⚡", "🎉"]
        ),
        EmojiCategory(
            name: "Arrows & Badges",
            emojis: ["⬆️", "↗️", "➡️", "↘️", "⬇️", "↙️", "⬅️", "↖️", "🔒", "🔓", "🏷️", "💬"]
        ),
        EmojiCategory(
            name: "Nature & Fun",
            emojis: ["🌈", "☀️", "🌙", "🌸", "🍀", "🦋", "🐱", "🐶", "🍕", "☕", "🎨", "📸"]
        )
    ]

    public static var emojisByCategory: [String: [String]] {
        Dictionary(uniqueKeysWithValues: emojiCategories.map { ($0.name, $0.emojis) })
    }

    public static var allEmojis: [String] {
        emojiCategories.flatMap(\.emojis)
    }

    public static let sfSymbols: [String] = [
        "star.fill",
        "heart.fill",
        "bolt.fill",
        "flame.fill",
        "sparkles",
        "checkmark.seal.fill",
        "Checkmark.circle.fill".lowercased(),
        "xmark.octagon.fill",
        "exclamationmark.triangle.fill",
        "questionmark.circle.fill",
        "arrow.up.right.circle.fill",
        "arrow.right.circle.fill",
        "hand.thumbsup.fill",
        "eye.fill",
        "pin.fill",
        "tag.fill",
        "flag.fill",
        "bell.fill",
        "bookmark.fill",
        "camera.fill",
        "paintbrush.fill",
        "wand.and.stars",
        "crop",
        "paperplane.fill",
        "lock.fill",
        "shield.fill",
        "crown.fill",
        "trophy.fill",
        "gift.fill",
        "bubble.left.and.bubble.right.fill"
    ]
}
