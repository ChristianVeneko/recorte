import AppKit
import Foundation
import RecorteIO
import UniformTypeIdentifiers

@MainActor
public enum ExportPanelController {

    public static func presentOpenPanel(completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                completion(urls)
            }
        }
    }

    public static func presentExportPanel(
        for model: EditorModel,
        format: ImageExportFormat
    ) {
        guard !model.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export \(format.fileExtension.uppercased())"
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let baseName = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = baseName.isEmpty ? "Recorte" : baseName
        panel.nameFieldStringValue = "\(safeBase).\(format.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try model.exportImage(format: format, to: url)
                } catch {
                    model.lastErrorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
