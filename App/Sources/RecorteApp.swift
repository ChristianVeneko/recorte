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
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = configureWindowOpener()

        WindowGroup(id: Self.editorWindowID, for: UUID.self) { $editorID in
            EditorWindowView(editorID: editorID)
        }
        .handlesExternalEvents(matching: [])
        .commands {
            RecorteMenuCommands()
        }
    }

    private func configureWindowOpener() {
        let openWindowAction = openWindow
        Workspace.shared.onRequestOpenTab = { id in
            openWindowAction(id: Self.editorWindowID, value: id)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        // If cold-launched via `open -a Recorte file.png` and macOS suppressed the initial
        // WindowGroup window because handlesExternalEvents is empty, open tabs for any
        // unclaimed editors queued by application(_:open:).
        DispatchQueue.main.async {
            if Workspace.shared.hasUnclaimedEditors {
                Workspace.shared.drainUnclaimedTabs()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        let opened = Workspace.shared.openExternalFiles(at: urls)
        NSApp.activate()
        if let firstID = opened.first?.id,
           let window = WindowTabCoordinator.shared.window(for: firstID) {
            window.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.async {
            if Workspace.shared.hasUnclaimedEditors {
                Workspace.shared.drainUnclaimedTabs()
            }
        }
    }
}

private struct RecorteMenuCommands: Commands {
    @FocusedValue(\.activeEditorModel) private var activeModel
    @Environment(\.openWindow) private var openWindow

    private var currentModel: EditorModel? {
        activeModel ?? Workspace.shared.activeEditor
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                let editor = Workspace.shared.createEditor()
                openWindow(id: RecorteApp.editorWindowID, value: editor.id)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Collage…") {
                currentModel?.isPresentingCollageSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(currentModel == nil)

            Divider()

            Button("Open…") {
                ExportPanelController.presentOpenPanel(allowProjects: true) { urls in
                    _ = Workspace.shared.openFiles(at: urls, preferredEditor: currentModel)
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Save Project") {
                guard let model = currentModel else { return }
                ExportPanelController.saveOrPromptProject(for: model)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Save Project As…") {
                guard let model = currentModel else { return }
                ExportPanelController.presentSaveProjectPanel(for: model)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Divider()

            Button("Save to Downloads") {
                guard let model = currentModel else { return }
                do {
                    try model.saveToDownloads(format: .png)
                } catch {
                    model.lastErrorMessage = "Could not save to Downloads."
                }
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Export PNG…") {
                guard let model = currentModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .png)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Export JPEG…") {
                guard let model = currentModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .jpeg(quality: 0.9))
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Export HEIC…") {
                guard let model = currentModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .heic(quality: 0.9))
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Export PDF…") {
                guard let model = currentModel else { return }
                ExportPanelController.presentExportPDFPanel(for: model)
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))
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
                    currentModel?.copyCompositeToClipboard()
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Copy Rendered Image") {
                currentModel?.copyCompositeToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Paste") {
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else {
                    do {
                        try Workspace.shared.pasteFromPasteboard(preferredEditor: currentModel)
                    } catch {
                        currentModel?.lastErrorMessage = "No image found on the clipboard."
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
                currentModel?.isPresentingResizeSheet = true
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Divider()

            Button("Rotate 90° Left") {
                guard let model = currentModel else { return }
                do {
                    try model.rotateDocument90(direction: .left90)
                } catch {
                    model.lastErrorMessage = "Could not rotate image."
                }
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Rotate 90° Right") {
                guard let model = currentModel else { return }
                do {
                    try model.rotateDocument90(direction: .right90)
                } catch {
                    model.lastErrorMessage = "Could not rotate image."
                }
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Divider()

            Button("Flip Horizontal") {
                guard let model = currentModel else { return }
                do {
                    try model.flipDocument(axis: .horizontal)
                } catch {
                    model.lastErrorMessage = "Could not flip image."
                }
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))

            Button("Flip Vertical") {
                guard let model = currentModel else { return }
                do {
                    try model.flipDocument(axis: .vertical)
                } catch {
                    model.lastErrorMessage = "Could not flip image."
                }
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))
        }

        CommandMenu("Layer") {
            Button("Duplicate Layer") {
                currentModel?.duplicateSelectedLayer()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(currentModel?.selectedLayer == nil)

            Button("Delete Layer") {
                currentModel?.deleteSelectedLayer()
            }
            .disabled(currentModel?.selectedLayer == nil)

            Divider()

            Button("Remove Background") {
                guard let model = currentModel else { return }
                Task {
                    await model.removeBackgroundFromSelectedLayer()
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!(currentModel?.canRemoveBackground ?? false))
        }

        CommandMenu("Tools") {
            Button("Move (V)") {
                currentModel?.activeTool = .move
            }
            Button("Crop (C)") {
                if let model = currentModel, model.hasCanvasSurface {
                    model.beginCrop()
                }
            }
            .disabled(!(currentModel?.hasCanvasSurface ?? false))
            Button("Lasso Cutout (L)") {
                currentModel?.activeTool = .lasso
            }
            .disabled(!(currentModel?.hasEditableImageLayer ?? false))
            Button("Perspective (P)") {
                currentModel?.beginPerspective()
            }
            .disabled(!(currentModel?.hasEditableImageLayer ?? false))
            Button("Clone Stamp (K)") {
                currentModel?.activeTool = .clone
            }
            .disabled(!(currentModel?.hasEditableImageLayer ?? false))
            Button("Deform (W)") {
                currentModel?.activeTool = .deform
            }
            .disabled(!(currentModel?.hasEditableImageLayer ?? false))

            Divider()

            Button("Text (T)") {
                currentModel?.activeTool = .text
            }
            Button("Shapes (S)") {
                currentModel?.activeTool = .shapes
            }
            Button("Stickers") {
                currentModel?.activeTool = .stickers
            }
            Button("Draw (B)") {
                currentModel?.activeTool = .draw
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Merge All Windows into Tabs") {
                NSApp.sendAction(#selector(NSWindow.mergeAllWindows(_:)), to: nil, from: nil)
            }
        }
    }
}
