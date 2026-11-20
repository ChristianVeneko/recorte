import SwiftUI

struct GlassDocumentTrayView: View {
    let currentModel: EditorModel
    let workspace: Workspace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.editors) { editor in
                            trayThumbnail(for: editor)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: 460)

                if workspace.editors.count > 1 {
                    Divider()
                        .frame(height: 28)
                    Text("Drag to canvas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Divider()
                        .frame(height: 28)
                    Text("Open tabs (⌘T) appear here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    private func trayThumbnail(for editor: EditorModel) -> some View {
        let isCurrent = editor.id == currentModel.id

        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let cgImage = editor.renderedImage {
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(nsColor: .controlBackgroundColor)
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 64, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isCurrent ? Color.accentColor : Color.primary.opacity(0.18),
                            lineWidth: isCurrent ? 2 : 1
                        )
                )

                if !isCurrent && !editor.isEmpty {
                    Button {
                        currentModel.dropImageFromTray(sourceEditorID: editor.id, from: workspace)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                    .help("Add \"\(editor.title)\" as layer")
                }
            }

            Text(editor.title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 64)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .draggable(TrayDocumentTransfer(editorID: editor.id)) {
            Group {
                if let cgImage = editor.renderedImage {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Label(editor.title, systemImage: "photo")
                        .padding(6)
                }
            }
        }
        .help(isCurrent ? "Current document: \(editor.title)" : "Drag onto canvas to add \"\(editor.title)\" as a layer")
    }
}
