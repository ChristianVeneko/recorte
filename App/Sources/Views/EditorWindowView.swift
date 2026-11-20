import AppKit
import RecorteCore
import RecorteIO
import SwiftUI

struct EditorWindowView: View {
    @Environment(\.undoManager) private var envUndoManager
    @Environment(\.openWindow) private var openWindow

    @State private var model = EditorModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isInspectorPresented: Bool = true
    @State private var showTray: Bool = true
    @State private var zoomFactor: CGFloat = 1.0
    @State private var hostWindow: NSWindow?

    private let workspace = Workspace.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LayersSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            CanvasStageView(
                model: model,
                workspace: workspace,
                zoomFactor: $zoomFactor,
                showTray: $showTray,
                onOpenFile: openImageFile,
                onPaste: pasteFromClipboard
            )
        }
        .inspector(isPresented: $isInspectorPresented) {
            ContextualInspectorView(model: model)
                .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    openWindow(id: RecorteApp.editorWindowID)
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .help("New Tab (⌘T)")
            }

            ToolbarItemGroup(placement: .principal) {
                Button {
                    zoomFactor = max(0.25, zoomFactor / 1.25)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out")

                Button {
                    zoomFactor = 1.0
                } label: {
                    Text("\(Int((zoomFactor * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 38)
                }
                .help("Zoom to Fit")

                Button {
                    zoomFactor = min(4.0, zoomFactor * 1.25)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if let shareItem = model.shareableImage() {
                    ShareLink(
                        item: shareItem,
                        preview: SharePreview(model.title, image: Image(decorative: shareItem.image, scale: 1.0))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share Image")
                } else {
                    Button {} label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(true)
                }

                Button {
                    model.shareViaAirDrop()
                } label: {
                    Label("AirDrop", systemImage: "airdrop")
                }
                .disabled(model.isEmpty)
                .help("Share via AirDrop")

                Button {
                    model.copyCompositeToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.isEmpty)
                .help("Copy Rendered Image (⇧⌘C)")

                Menu {
                    Button("Export PNG…") {
                        ExportPanelController.presentExportPanel(for: model, format: .png)
                    }
                    Button("Export JPEG…") {
                        ExportPanelController.presentExportPanel(for: model, format: .jpeg(quality: 0.9))
                    }
                    Button("Export HEIC…") {
                        ExportPanelController.presentExportPanel(for: model, format: .heic(quality: 0.9))
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isEmpty)
                .help("Export Image (⌘E)")

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showTray.toggle()
                    }
                } label: {
                    Label("Tray", systemImage: showTray ? "rectangle.bottomthird.inset.filled" : "rectangle.inset.bottomleading.filled")
                }
                .help(showTray ? "Hide Open Images Tray" : "Show Open Images Tray")

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle Inspector")
            }
        }
        .navigationTitle(model.title)
        .frame(minWidth: 960, minHeight: 620)
        .background(
            WindowTabbingBridge(title: model.title) { window in
                hostWindow = window
            }
        )
        .focusedSceneValue(\.activeEditorModel, model)
        .onAppear {
            if let envUndoManager {
                model.undoManager = envUndoManager
            }
            workspace.register(model)
        }
        .onChange(of: envUndoManager) { _, newUndo in
            if let newUndo {
                model.undoManager = newUndo
            }
        }
        .onDisappear {
            workspace.unregister(id: model.id)
        }
        .background(
            SingleKeyShortcutBridge(model: model, hostWindow: hostWindow)
        )
    }

    private func pasteFromClipboard() {
        do {
            try model.pasteFromPasteboard()
        } catch {
            model.lastErrorMessage = "No image found on the clipboard."
        }
    }

    private func openImageFile() {
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
}

// MARK: - Native NSWindow Tabbing Bridge (S4)

private struct WindowTabbingBridge: NSViewRepresentable {
    static let tabbingIdentifier = "dev.recorte.editor.tabgroup"

    let title: String
    let onWindowAttached: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            attach(view: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            attach(view: nsView)
            nsView.window?.title = title
        }
    }

    @MainActor
    private func attach(view: NSView) {
        guard let window = view.window else { return }
        NSWindow.allowsAutomaticWindowTabbing = true
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.title = title
        onWindowAttached(window)
    }
}

// MARK: - Single-Key Shortcuts Bridge (S9)

private struct SingleKeyShortcutBridge: NSViewRepresentable {
    let model: EditorModel
    let hostWindow: NSWindow?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, hostWindow: hostWindow)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.hostWindow = hostWindow ?? nsView.window
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var model: EditorModel
        weak var hostWindow: NSWindow?
        private var monitor: Any?

        init(model: EditorModel, hostWindow: NSWindow?) {
            self.model = model
            self.hostWindow = hostWindow
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyEvent(event)
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
            guard let hostWindow, event.window === hostWindow else { return event }
            // Do not intercept while typing inside any text field or text view
            if hostWindow.firstResponder is NSTextView {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            // Special keys: Return (36 / 76), Escape (53), Delete / Forward Delete (51 / 117)
            switch event.keyCode {
            case 36, 76: // Return / Enter
                if model.activeTool == .crop && model.cropSpec != nil {
                    try? model.applyCrop()
                    return nil
                }
            case 53: // Escape
                if model.activeTool == .crop {
                    model.cancelCrop()
                    return nil
                }
            case 51, 117: // Backspace / Forward Delete
                if model.activeTool != .crop, model.selectedLayer != nil {
                    model.deleteSelectedLayer()
                    return nil
                }
            default:
                break
            }

            guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch chars {
            case "v":
                model.activeTool = .move
                return nil
            case "c":
                if !model.isEmpty {
                    model.beginCrop()
                }
                return nil
            case "t":
                model.activeTool = .text
                return nil
            case "s":
                model.activeTool = .shapes
                return nil
            case "b":
                model.activeTool = .draw
                return nil
            default:
                return event
            }
        }
    }
}
