import SwiftUI

struct GlassToolDockView: View {
    @Bindable var model: EditorModel

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(EditorTool.allCases) { tool in
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
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .frame(width: 34, height: 34)
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
    }

    private func toolButton(for tool: EditorTool) -> some View {
        let isSelected = model.activeTool == tool
        let helpText = if let key = tool.shortcutDisplay {
            "\(tool.label) (\(key))"
        } else {
            tool.label
        }

        return Button {
            if tool == .crop {
                if !model.isEmpty {
                    model.beginCrop()
                }
            } else {
                model.activeTool = tool
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(tool == .crop && model.isEmpty)
        .help(helpText)
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
