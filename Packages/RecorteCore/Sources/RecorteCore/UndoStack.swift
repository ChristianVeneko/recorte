import Foundation

/// A generic value-type Undo/Redo history stack as a clean fallback or backing store for `UndoManager`.
public struct UndoStack<State: Sendable>: Sendable {
    private var past: [State] = []
    public private(set) var current: State
    private var future: [State] = []
    public let maxDepth: Int

    public init(initial: State, maxDepth: Int = 100) {
        self.current = initial
        self.maxDepth = max(1, maxDepth)
    }

    public var canUndo: Bool {
        !past.isEmpty
    }

    public var canRedo: Bool {
        !future.isEmpty
    }

    public var undoCount: Int {
        past.count
    }

    public var redoCount: Int {
        future.count
    }

    /// Pushes a new state onto the undo stack and clears redo history.
    public mutating func push(_ newState: State) {
        past.append(current)
        if past.count > maxDepth {
            past.removeFirst(past.count - maxDepth)
        }
        current = newState
        future.removeAll()
    }

    /// Steps backward to the previous state, if available.
    @discardableResult
    public mutating func undo() -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        return current
    }

    /// Steps forward to the next state, if available.
    @discardableResult
    public mutating func redo() -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        return current
    }
}
