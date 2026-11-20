import AppKit
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

            Button("Open Image…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentOpenPanel { urls in
                    for url in urls {
                        do {
                            try model.openImage(from: url)
                        } catch {
                            model.lastErrorMessage = "Could not open \(url.lastPathComponent)."
                        }
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Export PNG…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .png)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(activeModel?.isEmpty ?? true)

            Button("Export JPEG…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .jpeg(quality: 0.9))
            }
            .disabled(activeModel?.isEmpty ?? true)

            Button("Export HEIC…") {
                guard let model = activeModel else { return }
                ExportPanelController.presentExportPanel(for: model, format: .heic(quality: 0.9))
            }
            .disabled(activeModel?.isEmpty ?? true)
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
            .disabled(activeModel?.isEmpty ?? true)

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
                if let model = activeModel, !model.isEmpty {
                    model.beginCrop()
                }
            }
            .disabled(activeModel?.isEmpty ?? true)
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
