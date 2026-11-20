# RecorteCore API Summary

- `EditorDocument`: Value type `{canvasSize, background: .transparent|.solid(RGBAColor), layers: [Layer], selection: UUID?}`.
- `EditorDocument` mutating ops: `add(_:)`, `remove(id:)`, `duplicate(id:)`, `reorder(from:to:)`, `move(id:to:)`, `setVisibility(id:isHidden:)`, `setLock(id:isLocked:)`, `setOpacity(id:opacity:)`.
- `Layer`: `{id: UUID, name, kind: LayerKind, transform: LayerTransform(position, scale, rotation/rotationDegrees), opacity, isHidden, isLocked}`.
- `LayerKind`: `.image(SendableImage)` | `.text(TextSpec)` | `.shape(ShapeSpec)` | `.sticker(StickerSpec)`.
- `SendableImage`: `@unchecked Sendable` wrapper around immutable `CGImage` + `filterPreset: FilterPreset` + `adjustments: Adjustments`.
- `TextSpec`: `{string, fontName, size, color, alignment: .left|.center|.right, stroke: TextStrokeSpec?, background: RGBAColor?}`.
- `ShapeSpec`: `{kind: .rect|.roundedRect(cornerRadius)|.ellipse|.line|.arrow, size, strokeColor, fillColor, lineWidth}`.
- `StickerSpec`: `{content: .emoji(String)|.sfSymbol(String), pointSize, tintColor}` (helpers: `.emoji(_:pointSize:)`, `.sfSymbol(_:pointSize:tintColor:)`).
- `CropSpec`: `{rect, aspect: .free|.original|.ratio1x1|.ratio4x3|.ratio3x4|.ratio16x9|.ratio9x16, shape: .rectangle|.roundedRect(radius)|.ellipse|.star|.heart, rotationDegrees, flipH, flipV}`.
- `Cropper`: `constrainRect(_:aspect:in:) -> CGRect`, `maskPath(for:in:) -> CGPath`, `crop(_:spec:) throws -> CGImage` (and `crop(_:_:)`) with transparent pixels outside non-rectangular shapes.
- `FilterPreset` & `Adjustments`: Presets (`none, mono, noir, chrome, fade, instant, process, transfer, vivid, warm, cool`) & `{brightness, contrast, saturation, exposure, warmth, sharpness, vignette}` via `ImageFilters.apply(to:preset:adjustments:)` using `ImageFilters.sharedContext`.
- `Renderer`: `Renderer.render(_:scale:) throws -> CGImage` (and `render(_:_:)`) compositing visible layers with transforms/opacity via CoreGraphics + CoreText.
- `UndoStack<State>`: Generic value stack `{current, canUndo, canRedo, push(_:), undo() -> State?, redo() -> State?}`.
