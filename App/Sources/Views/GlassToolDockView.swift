import SwiftUI

struct GlassToolDockView: View {
    @Bindable var model: EditorModel

    private let imageTools: [EditorTool] = [.move, .crop, .lasso, .eraser, .perspective, .clone, .deform]
    private let createTools: [EditorTool] = [.text, .shapes, .stickers, .draw]

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(spacing: 4) {
                ForEach(imageTools) { tool in
                    toolButton(for: tool)
                }

                Divider()
                    .frame(width: 22)
                    .padding(.vertical, 2)

                ForEach(createTools) { tool in
                    toolButton(for: tool)
                }

                Divider()
                    .frame(width: 22)
                    .padding(.vertical, 2)

                Button {
                    Task {
                        await model.removeBackgroundFromSelectedLayer()
                    }
                } label: {
                    Group {
                        if model.isRemovingBackground {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.and.background.dotted")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(Color.clear, in: Circle())
                .disabled(!model.canRemoveBackground)
                .help("Remove Background (⇧⌘B)")
                .accessibilityLabel("Remove Background")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .background(EraserShortcutBridge(model: model))
    }

    private func toolButton(for tool: EditorTool) -> some View {
        let isSelected = model.activeTool == tool
        let helpText = if let key = tool.shortcutDisplay {
            "\(tool.label) (\(key))"
        } else {
            tool.label
        }
        let requiresImageLayer = (tool == .lasso || tool == .eraser || tool == .perspective || tool == .clone || tool == .deform)
        let isDisabled = (tool == .crop && !model.hasCanvasSurface) || (requiresImageLayer && !model.hasEditableImageLayer)

        return Button {
            switch tool {
            case .crop:
                if model.hasCanvasSurface {
                    model.beginCrop()
                }
            case .perspective:
                if model.hasEditableImageLayer {
                    model.beginPerspective()
                }
            default:
                model.activeTool = tool
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
