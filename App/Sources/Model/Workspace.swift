import AppKit
import Foundation
import Observation
import RecorteCore
import RecorteIO

@MainActor
@Observable
public final class Workspace {
    public static let shared = Workspace()

    public var editors: [EditorModel] = []
    public var activeEditorID: UUID?

    /// Invoked when Workspace needs the app shell to open a new editor tab for an editor ID.
    @ObservationIgnored
    public var onRequestOpenTab: (@MainActor (UUID) -> Void)?

    /// Becomes true once at least one editor window has attached in the current session.
    @ObservationIgnored
    public var hasAttachedWindow: Bool = false

    @ObservationIgnored
    private var unclaimedEditorIDs: [UUID] = []

    public init() {}

    public var activeEditor: EditorModel? {
        if let activeEditorID, let match = editor(id: activeEditorID) {
            return match
        }
        return editors.last
    }

    public var hasUnclaimedEditors: Bool {
        !unclaimedEditorIDs.isEmpty
    }

    @discardableResult
    public func createEditor(
        title: String? = nil,
        document: EditorDocument = EditorDocument(),
        undoManager: UndoManager = UndoManager()
    ) -> EditorModel {
        let resolvedTitle = title ?? nextUntitledTitle()
        let model = EditorModel(
            title: resolvedTitle,
            document: document,
            undoManager: undoManager
        )
        register(model)
        return model
    }

    @discardableResult
    public func openNewTab() -> EditorModel {
        let model = createEditor()
        requestTabOrQueue(for: model.id, forceOpen: true)
        return model
    }

    public func register(_ editor: EditorModel) {
        if !editors.contains(where: { $0.id == editor.id }) {
            editors.append(editor)
        }
        activeEditorID = editor.id
    }

    public func markActive(id: UUID) {
        if editors.contains(where: { $0.id == id }) {
            activeEditorID = id
        }
    }

    public func unregister(id: UUID) {
        unclaimedEditorIDs.removeAll { $0 == id }
        editors.removeAll { $0.id == id }
        if activeEditorID == id {
            activeEditorID = editors.last?.id
        }
    }

    public func editor(id: UUID) -> EditorModel? {
        editors.first { $0.id == id }
    }

    /// Resolves an editor by ID for a SwiftUI WindowGroup scene, creating one if needed (e.g. window restoration).
    public func resolveEditor(id: UUID) -> EditorModel {
        unclaimedEditorIDs.removeAll { $0 == id }
        if let existing = editor(id: id) {
            activeEditorID = existing.id
            return existing
        }
        let created = EditorModel(id: id, title: nextUntitledTitle())
        register(created)
        return created
    }

    /// Claims the next unclaimed editor (e.g. from cold-launch file open) or creates a new empty Untitled editor.
    public func claimOrCreateEditorID() -> UUID {
        while let nextID = unclaimedEditorIDs.first {
            unclaimedEditorIDs.removeFirst()
            if let existing = editor(id: nextID) {
                activeEditorID = existing.id
                return existing.id
            }
        }
        return createEditor().id
    }

    /// Opens tabs for any remaining unclaimed editors (e.g. multiple files passed on cold launch).
    public func drainUnclaimedTabs() {
        guard let openTab = onRequestOpenTab else { return }
        let pending = unclaimedEditorIDs
        unclaimedEditorIDs.removeAll()
        for id in pending where editor(id: id) != nil {
            openTab(id)
        }
    }

    // MARK: - Paste & File Open Routing

    @discardableResult
    public func pasteImage(
        _ imported: ImportedImage,
        preferredEditor: EditorModel? = nil
    ) -> EditorModel {
        if let target = preferredEditor ?? activeEditor {
            target.pasteImage(imported)
            activeEditorID = target.id
            return target
        }

        let created = createEditor()
        created.pasteImage(imported)
        requestTabOrQueue(for: created.id)
        return created
    }

    @discardableResult
    public func pasteFromPasteboard(
        _ pasteboard: NSPasteboard = .general,
        preferredEditor: EditorModel? = nil
    ) throws -> EditorModel {
        let imported = try ImageImporter.importFromPasteboard(pasteboard)
        return pasteImage(imported, preferredEditor: preferredEditor)
    }

    @discardableResult
    public func openFile(
        from url: URL,
        preferredEditor: EditorModel? = nil
    ) throws -> EditorModel {
        if let current = preferredEditor ?? activeEditor, !current.hasCanvasSurface {
            try current.openFile(from: url)
            activeEditorID = current.id
            return current
        }

        let newEditor = EditorModel(title: nextUntitledTitle())
        try newEditor.openFile(from: url)
        register(newEditor)
        requestTabOrQueue(for: newEditor.id)
        return newEditor
    }

    @discardableResult
    public func openFiles(
        at urls: [URL],
        preferredEditor: EditorModel? = nil
    ) -> [EditorModel] {
        var opened: [EditorModel] = []
        for (index, url) in urls.enumerated() {
            do {
                let targetPreferred = (index == 0) ? preferredEditor : nil
                let editor = try openFile(from: url, preferredEditor: targetPreferred)
                opened.append(editor)
            } catch {
                (preferredEditor ?? activeEditor)?.lastErrorMessage = "Could not open \(url.lastPathComponent)."
            }
        }
        return opened
    }

    private func requestTabOrQueue(for id: UUID, forceOpen: Bool = false) {
        if forceOpen || hasAttachedWindow {
            if let openTab = onRequestOpenTab {
                openTab(id)
            } else if !unclaimedEditorIDs.contains(id) {
                unclaimedEditorIDs.append(id)
            }
        } else {
            if editors.count > 1, let openTab = onRequestOpenTab {
                openTab(id)
            } else if !unclaimedEditorIDs.contains(id) {
                unclaimedEditorIDs.append(id)
            }
        }
    }

    private func nextUntitledTitle() -> String {
        let existingTitles = Set(editors.map(\.title))
        if !existingTitles.contains("Untitled") {
            return "Untitled"
        }
        var number = 2
        while existingTitles.contains("Untitled \(number)") {
            number += 1
        }
        return "Untitled \(number)"
    }
}
