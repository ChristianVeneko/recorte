import AppKit
import RecorteCore
import RecorteIO
import SwiftUI

private struct ActiveEditorModelKey: FocusedValueKey {
    typealias Value = EditorModel
}

extension FocusedValues {
    var activeEditorModel: EditorModel? {
        get { self[ActiveEditorModelKey.self] }
        set { self[ActiveEditorModelKey.self] = newValue }
    }
}

@main
struct RecorteApp: App {
    static let editorWindowID = "editor"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: Self.editorWindowID) {
            EditorWindowView()
        }
        .commands {
            RecorteMenuCommands()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }
}

private struct RecorteMenuCommands: Commands {
    @FocusedValue(\.activeEditorModel) private var activeModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                openWindow(id: RecorteApp.editorWindowID)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Collage…") {
                activeModel?.isPresentingCollageSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(activeModel == nil)

            Divider()

            Button("Open…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentOpenPanel(allowProjects: true) { urls in
                    for url in urls {
                        do {
                            try model.openFile(from: url)
                        } catch {
                            model.lastErrorMessage = "Could not open \(url.lastPathComponent)."
                        }
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Save Project") {
                guard let model = activeModel else { return }
                ExportPanelController.saveOrPromptProject(for: model)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Save Project As…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentSaveProjectPanel(for: model)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Divider()

            Button("Save to Downloads") {
                guard let model = activeModel else { return }
                do {
                    try model.saveToDownloads(format: .png)
                } catch {
                    model.lastErrorMessage = "Could not save to Downloads."
                }
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Export PNG…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .png)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Export JPEG…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .jpeg(quality: 0.9))
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Export HEIC…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .heic(quality: 0.9))
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Export PDF…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPDFPanel(for: model)
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Copy") {
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else {
                    activeModel?.copyCompositeToClipboard()
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Copy Rendered Image") {
                activeModel?.copyCompositeToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Paste") {
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if let model = activeModel {
                    do {
                        try model.pasteFromPasteboard()
                    } catch {
                        model.lastErrorMessage = "No image found on the clipboard."
                    }
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Button("Select All") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("a", modifiers: .command)
        }

        CommandMenu("Image") {
            Button("Resize…") {
                activeModel?.isPresentingResizeSheet = true
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Divider()

            Button("Rotate 90° Left") {
                guard let model = activeModel else { return }
                do {
                    try model.rotateDocument90(direction: .left90)
                } catch {
                    model.lastErrorMessage = "Could not rotate image."
                }
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Rotate 90° Right") {
                guard let model = activeModel else { return }
                do {
                    try model.rotateDocument90(direction: .right90)
                } catch {
                    model.lastErrorMessage = "Could not rotate image."
                }
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Divider()

            Button("Flip Horizontal") {
                guard let model = activeModel else { return }
                do {
                    try model.flipDocument(axis: .horizontal)
                } catch {
                    model.lastErrorMessage = "Could not flip image."
                }
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))

            Button("Flip Vertical") {
                guard let model = activeModel else { return }
                do {
                    try model.flipDocument(axis: .vertical)
                } catch {
                    model.lastErrorMessage = "Could not flip image."
                }
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))
        }

        CommandMenu("Layer") {
            Button("Duplicate Layer") {
                activeModel?.duplicateSelectedLayer()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(activeModel?.selectedLayer == nil)

            Button("Delete Layer") {
                activeModel?.deleteSelectedLayer()
            }
            .disabled(activeModel?.selectedLayer == nil)

            Divider()

            Button("Remove Background") {
                guard let model = activeModel else { return }
                Task {
                    await model.removeBackgroundFromSelectedLayer()
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!(activeModel?.canRemoveBackground ?? false))
        }

        CommandMenu("Tools") {
            Button("Move (V)") {
                activeModel?.activeTool = .move
            }
            Button("Crop (C)") {
                if let model = activeModel, model.hasCanvasSurface {
                    model.beginCrop()
                }
            }
            .disabled(!(activeModel?.hasCanvasSurface ?? false))
            Button("Lasso Cutout (L)") {
                activeModel?.activeTool = .lasso
            }
            .disabled(!(activeModel?.hasEditableImageLayer ?? false))
            Button("Perspective (P)") {
                activeModel?.beginPerspective()
            }
            .disabled(!(activeModel?.hasEditableImageLayer ?? false))
            Button("Clone Stamp (K)") {
                activeModel?.activeTool = .clone
            }
            .disabled(!(activeModel?.hasEditableImageLayer ?? false))
            Button("Deform (W)") {
                activeModel?.activeTool = .deform
            }
            .disabled(!(activeModel?.hasEditableImageLayer ?? false))

            Divider()

            Button("Text (T)") {
                activeModel?.activeTool = .text
            }
            Button("Shapes (S)") {
                activeModel?.activeTool = .shapes
            }
            Button("Stickers") {
                activeModel?.activeTool = .stickers
            }
            Button("Draw (B)") {
                activeModel?.activeTool = .draw
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Merge All Windows into Tabs") {
                NSApp.sendAction(#selector(NSWindow.mergeAllWindows(_:)), to: nil, from: nil)
            }
        }
    }
}
