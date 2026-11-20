import AppKit
import RecorteCore
import SwiftUI

struct LayersSidebarView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if model.document.layers.isEmpty {
                ContentUnavailableView {
                    Label("No Layers", systemImage: "square.3.layers.3d")
                } description: {
                    Text("Paste an image or add text, shapes, or stickers.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.document.selection },
                    set: { model.selectLayer(id: $0) }
                )) {
                    ForEach(model.displayedLayers) { layer in
                        LayerRowView(
                            layer: layer,
                            iconName: model.layerDisplayIcon(for: layer),
                            onToggleVisibility: { model.toggleVisibility(id: layer.id) },
                            onToggleLock: { model.toggleLock(id: layer.id) }
                        )
                        .tag(layer.id)
                        .contextMenu {
                            Button("Duplicate") {
                                model.duplicateLayer(id: layer.id)
                            }
                            Button(layer.isHidden ? "Show" : "Hide") {
                                model.toggleVisibility(id: layer.id)
                            }
                            Button(layer.isLocked ? "Unlock" : "Lock") {
                                model.toggleLock(id: layer.id)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                model.deleteLayer(id: layer.id)
                            }
                        }
                    }
                    .onMove { source, destination in
                        model.reorderDisplayedLayers(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            layerFooter
        }
        .navigationTitle("Layers")
    }

    @ViewBuilder
    private var layerFooter: some View {
        VStack(spacing: 8) {
            if let selected = model.selectedLayer {
                HStack(spacing: 8) {
                    Text("Opacity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { selected.opacity },
                            set: { model.setOpacity(id: selected.id, opacity: $0, continuous: true) }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                model.endContinuousEdit(actionName: "Change Opacity")
                            }
                        }
                    )
                    .controlSize(.small)
                    Text("\(Int((selected.opacity * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            HStack {
                Button {
                    model.duplicateSelectedLayer()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .labelStyle(.iconOnly)
                }
                .help("Duplicate Layer (⌘D)")
                .disabled(model.selectedLayer == nil)

                Button(role: .destructive) {
                    model.deleteSelectedLayer()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Delete Layer (⌫)")
                .disabled(model.selectedLayer == nil)

                Spacer()

                Text("\(model.document.layers.count) \(model.document.layers.count == 1 ? "layer" : "layers")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct LayerRowView: View {
    let layer: Layer
    let iconName: String
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            layerThumbnail
                .frame(width: 30, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name)
                    .font(.callout)
                    .lineLimit(1)
                    .opacity(layer.isHidden ? 0.45 : 1.0)
                if layer.opacity < 0.995 {
                    Text("\(Int((layer.opacity * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Button(action: onToggleVisibility) {
                Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(layer.isHidden ? .tertiary : .secondary)
            }
            .buttonStyle(.plain)
            .help(layer.isHidden ? "Show Layer" : "Hide Layer")
            .accessibilityLabel(layer.isHidden ? "Show \(layer.name)" : "Hide \(layer.name)")

            Button(action: onToggleLock) {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(layer.isLocked ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
            .help(layer.isLocked ? "Unlock Layer" : "Lock Layer")
            .accessibilityLabel(layer.isLocked ? "Unlock \(layer.name)" : "Lock \(layer.name)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var layerThumbnail: some View {
        switch layer.kind {
        case .image(let sendableImg):
            let thumb = ImageThumbnailCache.thumbnail(for: sendableImg.cgImage, maxDimension: 160)
            Image(decorative: thumb, scale: 1.0)
                .resizable()
                .scaledToFill()
                .background(Color(nsColor: .controlBackgroundColor))
        case .text(let spec):
            ZStack {
                (spec.background?.swiftUIColor ?? Color(nsColor: .controlBackgroundColor))
                Text("T")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(spec.color.swiftUIColor)
            }
        case .shape(let spec):
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle((spec.strokeColor ?? spec.fillColor ?? .white).swiftUIColor)
            }
        case .sticker(let spec):
            ZStack {
                (spec.background?.swiftUIColor ?? Color(nsColor: .controlBackgroundColor))
                switch spec.content {
                case .emoji(let value):
                    Text(value)
                        .font(.system(size: 14))
                case .sfSymbol(let symbol):
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(spec.tintColor.swiftUIColor)
                }
            }
        case .drawing(let spec):
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 12))
                    .foregroundStyle((spec.strokes.last?.color ?? .red).swiftUIColor)
            }
        default:
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
