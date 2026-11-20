import AppKit
import Foundation
import RecorteCore
import RecorteIO
import UniformTypeIdentifiers

@MainActor
public enum ExportPanelController {

    public static func presentOpenPanel(
        allowProjects: Bool = true,
        completion: @escaping @MainActor ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = allowProjects ? "Open Image or Recorte Project" : "Choose Images"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.image, .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
        if allowProjects {
            types.insert(.recorteProject, at: 0)
        }
        panel.allowedContentTypes = types

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                completion(urls)
            }
        }
    }

    public static func presentSaveProjectPanel(for model: EditorModel) {
        let panel = NSSavePanel()
        panel.title = "Save Recorte Project"
        panel.allowedContentTypes = [.recorteProject]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let baseName = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = baseName.isEmpty ? "Untitled" : baseName
        panel.nameFieldStringValue = "\(safeBase).\(RecorteProject.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try model.saveProject(to: url)
                } catch {
                    model.lastErrorMessage = "Could not save project: \(error.localizedDescription)"
                }
            }
        }
    }

    public static func saveOrPromptProject(for model: EditorModel) {
        if let existingURL = model.projectURL {
            do {
                try model.saveProject(to: existingURL)
            } catch {
                model.lastErrorMessage = "Could not save project: \(error.localizedDescription)"
            }
        } else {
            presentSaveProjectPanel(for: model)
        }
    }

    public static func presentExportPanel(
        for model: EditorModel,
        format: ImageExportFormat
    ) {
        guard model.hasCanvasSurface else { return }

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

    public static func presentExportPDFPanel(for model: EditorModel) {
        guard model.hasCanvasSurface else { return }

        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let baseName = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = baseName.isEmpty ? "Recorte" : baseName
        panel.nameFieldStringValue = "\(safeBase).pdf"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try model.exportPDF(to: url)
                } catch {
                    model.lastErrorMessage = "PDF export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
