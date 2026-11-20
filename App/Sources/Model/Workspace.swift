import Foundation
import Observation
import RecorteCore

@MainActor
@Observable
public final class Workspace {
    public static let shared = Workspace()

    public var editors: [EditorModel] = []
    public var activeEditorID: UUID?

    public init() {}

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

    public func register(_ editor: EditorModel) {
        if !editors.contains(where: { $0.id == editor.id }) {
            editors.append(editor)
        }
        activeEditorID = editor.id
    }

    public func unregister(id: UUID) {
        editors.removeAll { $0.id == id }
        if activeEditorID == id {
            activeEditorID = editors.last?.id
        }
    }

    public func editor(id: UUID) -> EditorModel? {
        editors.first { $0.id == id }
    }

    private func nextUntitledTitle() -> String {
        let existingCount = editors.filter { $0.title.hasPrefix("Untitled") }.count
        return existingCount == 0 ? "Untitled" : "Untitled \(existingCount + 1)"
    }
}
