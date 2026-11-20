# RecorteIO Public API (`import RecorteIO`)

- `ImportedImage`: `Sendable` struct with `image: CGImage`, `suggestedName: String`.
- `ImageImportError`: `noImageOnPasteboard`, `unreadableFile(URL)`, `unsupportedProvider`, `decodingFailed`.
- `ImageImporter.importFromPasteboard(_ pasteboard: NSPasteboard = .general) throws -> ImportedImage` (reads file URLs, PNG, TIFF screenshots, image UTTypes).
- `ImageImporter.importFromURL(_ url: URL) throws -> ImportedImage` & `importFromData(_ data: Data, suggestedName: String = "Image") throws -> ImportedImage`.
- `ImageImporter.importFromItemProvider(_ provider: NSItemProvider) async throws -> ImportedImage`.
- `ImageExportFormat`: `.png`, `.jpeg(quality: Double = 0.9)`, `.heic(quality: Double = 0.9)` (`utType`, `fileExtension`).
- `ImageExportError`: `destinationCreationFailed`, `encodingFailed`, `writeFailed(URL)`.
- `ImageExporter.encode(_ image: CGImage, format: ImageExportFormat) throws -> Data` & `encodeTIFF(_ image: CGImage) throws -> Data`.
- `ImageExporter.export(_ image: CGImage, to url: URL, format: ImageExportFormat) throws` (also overloaded `(image, format:to:)`).
- `Clipboard.copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> Bool` (writes PNG + TIFF).
- `ShareableImage(image: CGImage, suggestedName: String = "Recorte")`: `Transferable`, exports `.png`.
- `ShareService`: `writeTemporaryPNG(_ image: CGImage, name: String = "Recorte") throws -> URL`, `@MainActor airDropService() -> NSSharingService?`, `@MainActor shareViaAirDrop(_ image: CGImage, name: String = "Recorte") throws -> URL`.
- `SubjectLifter.liftSubject(_ image: CGImage) async throws -> CGImage` (throws `SubjectLifterError.noSubjectFound`, `.invalidImage`, `.maskGenerationFailed`) & `StickerCatalog` (`emojiCategories: [EmojiCategory]`, `emojisByCategory`, `allEmojis`, `sfSymbols: [String]`).
