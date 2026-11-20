import AppKit
import RecorteCore
import RecorteIO
import SwiftUI

struct EditorWindowView: View {
    @Environment(\.undoManager) private var envUndoManager
    @Environment(\.openWindow) private var openWindow

    @State private var model: EditorModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isInspectorPresented: Bool = true
    @State private var showTray: Bool = true
    @State private var zoomFactor: CGFloat = 1.0
    @State private var hostWindow: NSWindow?

    private let workspace = Workspace.shared

    init(editorID: UUID) {
        _model = State(initialValue: Workspace.shared.resolveEditor(id: editorID))
    }

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
                onOpenFile: openImageOrProjectFile,
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
                    let editor = workspace.createEditor()
                    openWindow(id: RecorteApp.editorWindowID, value: editor.id)
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
                    Label("AirDrop", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!model.hasCanvasSurface)
                .help("Share via AirDrop")

                Button {
                    model.copyCompositeToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(!model.hasCanvasSurface)
                .help("Copy Rendered Image (⇧⌘C)")

                Menu {
                    Button("Save to Downloads") {
                        do {
                            try model.saveToDownloads(format: .png)
                        } catch {
                            model.lastErrorMessage = "Could not save to Downloads."
                        }
                    }
                    Divider()
                    Button("Export PNG…") {
                        ExportPanelController.presentExportPanel(for: model, format: .png)
                    }
                    Button("Export JPEG…") {
                        ExportPanelController.presentExportPanel(for: model, format: .jpeg(quality: 0.9))
                    }
                    Button("Export HEIC…") {
                        ExportPanelController.presentExportPanel(for: model, format: .heic(quality: 0.9))
                    }
                    Button("Export PDF…") {
                        ExportPanelController.presentExportPDFPanel(for: model)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.hasCanvasSurface)
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
        .sheet(isPresented: $model.isPresentingResizeSheet) {
            ResizeSheetView(model: model)
        }
        .sheet(isPresented: $model.isPresentingCollageSheet) {
            CollageSheetView(model: model, workspace: workspace)
        }
        .navigationTitle(model.title)
        .frame(minWidth: 800, minHeight: 600)
        .background(
            WindowTabbingBridge(editorID: model.id, title: model.title) { window in
                hostWindow = window
            }
        )
        .focusedSceneValue(\.activeEditorModel, model)
        .onAppear {
            workspace.hasAttachedWindow = true
            let openWindowAction = openWindow
            workspace.onRequestOpenTab = { id in
                openWindowAction(id: RecorteApp.editorWindowID, value: id)
            }
            if let envUndoManager {
                model.undoManager = envUndoManager
            }
            workspace.register(model)
            workspace.drainUnclaimedTabs()
        }
        .onChange(of: envUndoManager) { _, newUndo in
            if let newUndo {
                model.undoManager = newUndo
            }
        }
        .background(
            SingleKeyShortcutBridge(model: model, hostWindow: hostWindow)
        )
    }

    private func pasteFromClipboard() {
        do {
            try workspace.pasteFromPasteboard(preferredEditor: model)
        } catch {
            model.lastErrorMessage = "No image found on the clipboard."
        }
    }

    private func openImageOrProjectFile() {
        ExportPanelController.presentOpenPanel(allowProjects: true) { urls in
            _ = workspace.openFiles(at: urls, preferredEditor: model)
        }
    }
}

// MARK: - Native NSWindow Tabbing Coordinator & Bridge (S4)

@MainActor
final class WindowTabCoordinator {
    static let shared = WindowTabCoordinator()
    static let tabbingIdentifier = "dev.recorte.editor.tabgroup"

    private final class WeakWindowBox {
        weak var window: NSWindow?
        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private var windowsByEditorID: [UUID: WeakWindowBox] = [:]
    private var lastActiveEditorID: UUID?
    private var mergedWindowIDs: Set<ObjectIdentifier> = []

    func window(for editorID: UUID) -> NSWindow? {
        pruneDeadWindows()
        return windowsByEditorID[editorID]?.window
    }

    func configureForTabbing(_ window: NSWindow, title: String) {
        NSWindow.allowsAutomaticWindowTabbing = true
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.title = title
    }

    func registerAndMergeIfNeeded(window: NSWindow, editorID: UUID, title: String) {
        guard !window.isSheet, window.parent == nil, !(window is NSPanel) else { return }
        pruneDeadWindows()
        configureForTabbing(window, title: title)
        windowsByEditorID[editorID] = WeakWindowBox(window)

        let windowKey = ObjectIdentifier(window)
        guard !mergedWindowIDs.contains(windowKey) else { return }
        mergedWindowIDs.insert(windowKey)

        if let host = preferredTabHostWindow(excluding: window) {
            let targetHost = host.tabGroup?.selectedWindow ?? host
            if targetHost !== window, window.tabGroup !== targetHost.tabGroup {
                targetHost.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func windowDidBecomeActive(editorID: UUID) {
        lastActiveEditorID = editorID
        Workspace.shared.markActive(id: editorID)
    }

    func windowWillClose(_ window: NSWindow, editorID: UUID) {
        mergedWindowIDs.remove(ObjectIdentifier(window))
        windowsByEditorID.removeValue(forKey: editorID)
        if lastActiveEditorID == editorID {
            lastActiveEditorID = nil
        }
        Workspace.shared.unregister(id: editorID)
    }

    private func preferredTabHostWindow(excluding candidate: NSWindow) -> NSWindow? {
        if let lastID = lastActiveEditorID,
           let lastWindow = windowsByEditorID[lastID]?.window,
           lastWindow !== candidate,
           isEligibleTabHost(lastWindow) {
            return lastWindow
        }

        if let main = NSApp.mainWindow,
           main !== candidate,
           main.tabbingIdentifier == Self.tabbingIdentifier,
           isEligibleTabHost(main) {
            return main
        }

        for box in windowsByEditorID.values {
            if let existing = box.window,
               existing !== candidate,
               isEligibleTabHost(existing) {
                return existing
            }
        }
        return nil
    }

    private func isEligibleTabHost(_ window: NSWindow) -> Bool {
        guard !window.isSheet, window.parent == nil, !(window is NSPanel) else { return false }
        if window.isVisible { return true }
        return window.tabGroup?.windows.contains(where: { $0.isVisible }) ?? false
    }

    private func pruneDeadWindows() {
        windowsByEditorID = windowsByEditorID.filter { $0.value.window != nil }
    }
}

private struct WindowTabbingBridge: NSViewRepresentable {
    let editorID: UUID
    let title: String
    let onWindowAttached: @MainActor (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(editorID: editorID, title: title, onWindowAttached: onWindowAttached)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        let coordinator = context.coordinator
        view.onWindowChanged = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.editorID = editorID
        context.coordinator.title = title
        context.coordinator.onWindowAttached = onWindowAttached
        if let window = nsView.window {
            context.coordinator.attach(to: window)
            window.title = title
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeObservers()
    }

    @MainActor
    final class Coordinator {
        var editorID: UUID
        var title: String
        var onWindowAttached: @MainActor (NSWindow) -> Void

        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(editorID: UUID, title: String, onWindowAttached: @escaping @MainActor (NSWindow) -> Void) {
            self.editorID = editorID
            self.title = title
            self.onWindowAttached = onWindowAttached
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            WindowTabCoordinator.shared.configureForTabbing(window, title: title)

            if observedWindow !== window {
                removeObservers()
                observedWindow = window
                installObservers(for: window)
                onWindowAttached(window)

                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window else { return }
                    WindowTabCoordinator.shared.registerAndMergeIfNeeded(
                        window: window,
                        editorID: self.editorID,
                        title: self.title
                    )
                    if window.isKeyWindow || window.isMainWindow {
                        WindowTabCoordinator.shared.windowDidBecomeActive(editorID: self.editorID)
                    }
                }
            }
        }

        private func installObservers(for window: NSWindow) {
            let center = NotificationCenter.default

            let keyObserver = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    WindowTabCoordinator.shared.windowDidBecomeActive(editorID: self.editorID)
                }
            }

            let mainObserver = center.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    WindowTabCoordinator.shared.windowDidBecomeActive(editorID: self.editorID)
                }
            }

            let closeObserver = center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    WindowTabCoordinator.shared.windowWillClose(window, editorID: self.editorID)
                }
            }

            observers = [keyObserver, mainObserver, closeObserver]
        }

        func removeObservers() {
            let center = NotificationCenter.default
            for observer in observers {
                center.removeObserver(observer)
            }
            observers.removeAll()
            observedWindow = nil
        }
    }
}

private final class WindowObserverView: NSView {
    var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

// MARK: - Single-Key Shortcuts Bridge (S9 & S15)

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
            if hostWindow.firstResponder is NSTextView {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            switch event.keyCode {
            case 36, 76: // Return / Enter
                if model.activeTool == .crop && model.cropSpec != nil {
                    try? model.applyCrop()
                    return nil
                }
                if model.activeTool == .perspective && model.perspectiveQuad != nil {
                    try? model.applyPerspective()
                    return nil
                }
                if model.activeTool == .lasso && model.lassoPoints.count >= 3 {
                    try? model.applyLassoCutout(points: model.lassoPoints, cropToBounds: model.lassoCropToBounds)
                    return nil
                }
            case 53: // Escape
                if model.activeTool == .crop {
                    model.cancelCrop()
                    return nil
                }
                if model.activeTool == .perspective {
                    model.cancelPerspective()
                    return nil
                }
                if model.activeTool == .lasso && !model.lassoPoints.isEmpty {
                    model.lassoPoints = []
                    return nil
                }
            case 51, 117: // Backspace / Forward Delete
                if model.activeTool != .crop && model.activeTool != .perspective,
                   model.selectedLayer != nil {
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
                if model.hasCanvasSurface {
                    model.beginCrop()
                }
                return nil
            case "l":
                if model.hasEditableImageLayer {
                    model.activeTool = .lasso
                }
                return nil
            case "p":
                if model.hasEditableImageLayer {
                    model.beginPerspective()
                }
                return nil
            case "k":
                if model.hasEditableImageLayer {
                    model.activeTool = .clone
                }
                return nil
            case "w":
                if model.hasEditableImageLayer {
                    model.activeTool = .deform
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
