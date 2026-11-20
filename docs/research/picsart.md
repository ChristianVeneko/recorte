# PicsArt Editor Feature Inventory & Mac Screenshot Editor ("Recorte") Evaluation

## Executive Summary & Product Framing

**PicsArt** is one of the most comprehensive mobile and web creative suites in existence, offering hundreds of tools spanning casual photo editing, AI generative art, social media graphic design, beauty retouching, collages, and video editing.

**Recorte**, by contrast, is envisioned as a focused, high-performance, native macOS screenshot editor (in the tradition of tools like CleanShot X, Shottr, and Apple's native Markup, but with modern visual flair and fluidity).

When evaluating PicsArt's feature set for a macOS screenshot utility, the product principles diverge sharply:
1. **Speed & Zero Friction over Expansive Creation:** A screenshot editor is fundamentally a utility. Users capture a screen artifact to communicate a bug, explain a workflow, highlight a UI change, or redact sensitive data. Time-to-destination (clipboard or file) is measured in seconds.
2. **Precision Vector Annotation over Raster Painting:** Screenshot annotations must remain crisp, editable, and movable (arrows, callout badges, text, rectangular frames), whereas PicsArt emphasizes raster manipulation, brush blending, and composite photos.
3. **Privacy & Redaction as First-Class Citizens:** PicsArt is built to reveal and stylize; a screenshot editor must frequently conceal (passwords, auth tokens, emails, financial records). Blur and pixelate tools are P0 requirements.
4. **macOS Integration:** Native pasteboard integration (Cmd+V, auto-copy), drag-and-drop between workspaces, multi-window tabbing, AirDrop, and system typography (SF Pro) take precedence over cloud sticker repositories or social media templates.

---

## Evaluation Rubric

Every PicsArt feature is cataloged and evaluated under the following classification for **Recorte's Minimum Viable Product (MVP)**:

- **`yes` (MVP):** Essential for v1.0. A screenshot editor cannot ship without this capability or a direct desktop equivalent (e.g., crop, arrow annotation, redaction blur, copy to clipboard).
- **`later` (Post-MVP / Fast Follow):** High-value enhancements that add power or aesthetic polish (e.g., magnifier loupe, window framing shadows, multi-step numbered badges, custom background padding) but are not blockers for a working v1.0 utility.
- **`no` (Out of Scope / Anti-Pattern):** Consumer photo retouching, generative social media tools, heavy artistic effects, or mobile scrapbooking features that would bloat the binary and dilute product focus.

---

## Comprehensive PicsArt Feature Inventory & MVP Matrix

| Category | PicsArt Feature / Sub-Tool | PicsArt Capability Breakdown | Mac Screenshot Editor Context & Workflow Value | MVP (Recorte) | MVP Scope & Technical Rationale |
| :--- | :--- | :--- | :--- | :---: | :--- |
| **1. Crop, Cutout & Shape Crop** | Freeform Rectangular Crop | Interactive 8-point bounding handles; pixel dimensions displayed live. | **Critical:** Trimming full-screen captures to relevant dialogs or buttons is the #1 screenshot action. | **`yes`** | Ship interactive rectangular crop with pixel grid overlay, aspect ratio lock, and enter/esc confirmation. |
| | Preset Aspect Ratios | Fixed ratios: 1:1, 16:9, 4:5, 9:16, 3:2, 2:3, plus device/social presets (Instagram, TikTok). | **Moderate:** Useful when preparing screenshots for slides (16:9) or documentation headers. | **`later`** | Start with freeform crop in MVP; add standard presets (16:9, 4:3, 1:1) in v1.1. |
| | Perspective / Skew Crop | 4-point quadrilateral corner pinning to correct lens tilt or angled photos. | **Irrelevant:** Screenshots are captured directly from digital displays; no optical keystoning occurs. | **`no`** | Omit entirely. High mathematical complexity, zero value for digital captures. |
| | Cutout (AI Object/Subject) | Automatic ML segmentation to isolate people, pets, or foreground items. | **High Delight:** Isolating a UI element, window, or app icon without background noise. | **`yes`** | Include via macOS native `VNGenerateForegroundInstanceMaskRequest`. Free, instant, on-device subject lift. |
| | Cutout (Manual Brush/Eraser) | Hardness/size brush and lasso to manually paint selection masks. | **Low:** Too tedious for fast screenshot annotation. Users will not manually paint alpha masks. | **`no`** | Out of scope. Native Vision subject lift covers 95% of use cases without brush friction. |
| | Shape Crop | Clipping base image into circles, hearts, stars, triangles, octagons. | **Niche:** Circular avatar crops or rounded rectangle badges are occasionally useful for profile captures. | **`later`** | Defer to v1.2. Rectangular crop with rounded corners covers initial needs. |
| **2. Layers** | Multi-Layer Object Stack | Separate layer items with reordering (Bring Forward / Send Backward). | **Critical:** Non-destructive vector annotation requires each text box, arrow, and shape to be an independent layer. | **`yes`** | Vector annotation layer stack above base raster image. Reorder, duplicate, and delete elements. |
| | Raster Blending Modes | Multiply, Screen, Overlay, Darken, Lighten, Color Dodge, Soft Light. | **Low:** Used for digital painting and complex composites; not needed for screenshot annotations. | **`no`** | Only standard Normal and Multiply (for highlighters) are required. Omit full blend mode picker. |
| | Layer Opacity & Visibility | Per-layer alpha slider (0-100%) and hide/show eye toggle. | **Moderate:** Useful when tuning highlighter intensity or shape callout backgrounds. | **`later`** | Fixed opacity presets in MVP (e.g. highlighter = 40%); full opacity sliders in v1.1. |
| | Merge Down / Flatten | Baking active layers into a single composite raster bitmap. | **Utility:** Useful before applying full-image filters or exporting lightweight files. | **`yes`** | Automatic composite rendering upon copy/export. Manual "Flatten Annotations" command in menu. |
| **3. Text & Fonts** | Text Box Placement | Click-to-type anywhere on canvas; multi-line wrapping and bounding box resizing. | **Critical:** Explaining bugs, labeling buttons, adding titles and notes to captures. | **`yes`** | Click-to-add text with live auto-resize, bounding box handles, and inline cursor editing. |
| | System Typography (SF Pro) | Dynamic typography, optical sizing, tracking, font weight selection. | **High:** Native Mac aesthetics require San Francisco Pro with proper system kerning. | **`yes`** | Use native SwiftUI `Font.system()` with Bold, Semibold, Regular weights. |
| | Custom / Cloud Font Library | Browsing 500+ decorative, script, graffiti, and decorative fonts from cloud. | **Irrelevant:** Screenshots need clear, legible system annotations, not decorative novelty fonts. | **`no`** | Do not bundle custom font clouds. Support installed system fonts only. |
| | Text Background Pill / Callout | Auto-padded solid or translucent background bubble behind text string. | **High:** Ensures text remains readable over complex, cluttered code or busy UI screenshots. | **`yes`** | Text callout badge: background fill (solid or translucent) with rounded corners and padding. |
| | Text Stroke / Outline & Shadow | Outer stroke border and drop shadow (blur, color, x/y offset). | **Moderate:** Useful for legibility over mixed dark/light backgrounds. | **`later`** | High-contrast background pill solves legibility in MVP. Add drop shadow/outline in v1.1. |
| | Curved / 3D / Gradient Text | Text bending along arcs, 3D extrusions, multi-stop linear gradient fills. | **Anti-Pattern:** Gimmicky creator styling that clutters clean technical communications. | **`no`** | Omit entirely. Violates clean macOS technical utility aesthetics. |
| **4. Stickers** | Built-in / Community Stickers | Searchable library of millions of illustrations, memes, clips, and clip art. | **Anti-Pattern:** Unprofessional in technical workflows and bug reports. | **`no`** | Omit third-party sticker search entirely. |
| | Emoji & SF Symbols Insertion | Inserting native system symbols, icons, and Apple emoji onto the canvas. | **High:** Thumbs up, warning signs, checkmarks, exclamation marks, cursor icons. | **`yes`** | macOS native Character Viewer integration (Cmd+Ctrl+Space) + curated SF Symbols palette. |
| | Numbered Step Counters (1, 2, 3) | Auto-incrementing circular badges placed on click to explain sequential steps. | **Very High:** The hallmark feature of elite Mac screenshot tools (CleanShot, Shottr, Skitch). | **`yes`** | Auto-incrementing numbered badge tool: click places `1`, next click places `2`, etc., with custom color. |
| | Mouse Cursor Stamps | Inserting standard macOS arrow cursors, hand pointers, or crosshairs. | **Moderate:** Re-inserting cursors that were hidden during screenshot capture. | **`later`** | High value for documentation; schedule for v1.1 fast-follow. |
| **5. Filters & Effects (FX)** | Blur / Redaction Filter | Gaussian or box blur applied over a selected rectangular region. | **Mandatory:** Hiding PII, credit card details, customer names, sensitive tokens in screenshots. | **`yes`** | Selective regional blur tool (drag rectangle to blur underlying bitmap via Core Image). |
| | Pixelate / Mosaic Filter | Downsampling pixel blocks over a selected rectangular region. | **Mandatory:** The industry-standard visual convention for redaction. | **`yes`** | Selective regional pixelate tool (Core Image `CIPixellate`) with adjustable block size. |
| | Color Filter Presets | Sepia, Vintage, Retro, Warm, Cool, Duotone artistic color lookups. | **Irrelevant:** Distorts visual truth of software UI; detrimental for technical bug reporting. | **`no`** | Omit entirely. |
| | Black & White / Grayscale | Desaturating the screenshot to emphasize a colored callout annotation. | **Moderate:** Useful for dimming screenshot background while highlighting a specific UI element. | **`later`** | "Dim/Grayscale Background" filter toggle scheduled for v1.2. |
| | Artistic & Glitch Filters | Oil painting, sketch, comic book, neon edges, CRT scanlines, chromatic aberration. | **Anti-Pattern:** Consumer social media effects with no place in screenshot productivity. | **`no`** | Omit entirely. |
| **6. Adjustments** | Brightness & Contrast | Linear exposure and contrast scaling across full image. | **Moderate:** Fixing dark screenshots captured on dimmed HDR displays or projectors. | **`later`** | Simple Brightness/Contrast sliders via `CIColorControls` in v1.1 inspector panel. |
| | Saturation & Vibrance | Color intensity adjustments. | **Low:** Rarely necessary for digital UI captures. | **`no`** | Not needed for screenshot workflows. |
| | Unsharp Mask / Sharpen | Edge enhancement convolution to increase visual crispness. | **Low-Moderate:** Can help clarify downscaled Retina screenshots. | **`later`** | Defer to post-MVP auto-enhance feature. |
| | RGB Curves & Color Balance | Advanced tonal curve editor with per-channel spline adjustment. | **Overkill:** Pro photo editing tool that introduces unnecessary complexity. | **`no`** | Omit entirely. |
| **7. Shapes & Overlays** | Rectangles & Rounded Rects | Vector outline boxes with stroke color, line width, and optional fill. | **Critical:** Framing buttons, error alerts, navigation items, or input fields. | **`yes`** | Ship stroke-only and semi-transparent filled rounded rectangles with corner radius control. |
| | Arrows (Straight & Curved) | Vector arrows with automatic arrowhead rendering and draggable anchor points. | **Critical:** Pointing directly to bugs or UI elements is core screenshot functionality. | **`yes`** | 2-point straight arrow with clean triangle head; color picker and stroke thickness options. |
| | Lines & Dividers | Solid and dashed lines for underlining or connecting items. | **Moderate:** Underlining text or separating content sections. | **`yes`** | Included as a variant of the arrow tool (toggle arrowhead on/off). |
| | Ellipses / Circles | Circular callout rings to circle words, icons, or avatars. | **High:** Circling small interface controls. | **`yes`** | Vector ellipse/circle shape tool with stroke width and color selection. |
| | Callout Speech Bubbles | Rectangular or rounded bubble with a pointing tail. | **Moderate:** Adding cartoon-style comments or user thought bubbles. | **`later`** | Speech callout bubble planned for v1.1; basic text badge handles MVP needs. |
| | Magnifier Loupe Overlay | Circular magnifying glass zooming in on a region of the screenshot. | **Very High:** Showcasing subtle UI details, pixel alignments, or fine print. | **`later`** | High-value technical feature (CleanShot/Shottr style); schedule for v1.1. |
| | Bokeh / Light Leak Overlays | Alpha-blended photo overlays simulating optical aberrations. | **Anti-Pattern:** Distracting photo effects irrelevant to software documentation. | **`no`** | Omit entirely. |
| **8. Draw** | Freehand Pen | Smooth freeform vector or raster stroke following pointer drag. | **Critical:** Quick circling, scribbling notes, or organic marking. | **`yes`** | Freehand pen tool with stroke smoothing, customizable width and color. |
| | Highlighter / Marker | Semi-transparent broad stroke that blends over text without obscuring it. | **Critical:** Highlighting log lines, code snippets, or documentation sentences. | **`yes`** | Broad marker tool with Multiply blend mode / 40% alpha and yellow/green/cyan presets. |
| | Geometric Shape Auto-Snap | Drawing a messy rough circle or box that snaps automatically to clean geometry. | **High Delight:** Converts hasty mouse scribbles into perfect vectors (iPad/iOS style). | **`later`** | Fast-follow in v1.2 using Apple Pencil / trackpad stroke recognition. |
| | Eraser | Erasing drawn strokes. | **Critical:** Correcting mistakes during freehand drawing. | **`yes`** | Stroke-based vector eraser (clicking a stroke deletes it) + Undo/Redo support. |
| | Neon / Glow / Splatter Brushes | Decorative brushes with particle emission or outer bloom shaders. | **Anti-Pattern:** Novelty effects inappropriate for crisp desktop screenshots. | **`no`** | Omit entirely. |
| **9. Borders** | Simple Stroke Border | 1px or 2px outline around screenshot perimeter. | **High:** Distinguishes white screenshots from white backgrounds in documents/Slack. | **`yes`** | Outer perimeter border toggle with color and thickness control. |
| | Window Framing Chrome | Adding macOS simulated title bar (traffic light close/min/zoom buttons) and shadow. | **Very High:** Turns raw window clips into gorgeous marketing or presentation assets. | **`later`** | "Mac Window Frame" preset with native traffic lights and customizable title in v1.1. |
| | Canvas Padding & Backgrounds | Expanding canvas around screenshot with solid color, wallpaper gradient, or blur. | **Very High:** Modern social/presentation trend (X/Twitter, blog post screenshots). | **`later`** | Canvas padding slider + macOS gradient/wallpaper background generator in v1.1. |
| | Drop Shadow Framing | Configurable gaussian drop shadow around screenshot bounds. | **High:** Lifts screenshot off the page in docs and presentations. | **`later`** | Standard macOS window shadow generator in v1.1. |
| | Decorative / Floral Frames | Heavy ornate picture frames, holiday themes, patterned borders. | **Anti-Pattern:** Consumer scrapbooking aesthetics. | **`no`** | Omit entirely. |
| **10. Collage** | Side-by-Side Comparison | Placing 2 screenshots side-by-side with divider line (Before vs After). | **High:** Showing UI before/after a feature rollout or bug fix. | **`later`** | Dedicated 2-up Side-by-Side compare canvas in v1.2. |
| | Multi-Photo Grid (3-16 images) | Auto-flowing multiple photos into mosaic puzzle grids. | **Low:** Seldom needed for screenshot editing; multi-window tabs handle multiple shots. | **`no`** | Not aligned with focused screenshot utility. |
| | Scrapbook / Freestyle Collage | Freeform pinboard canvas with overlapping, tilted, sticker-decorated photos. | **Anti-Pattern:** Casual consumer scrapbook feature. | **`no`** | Omit entirely. |
| **11. Remove Background** | 1-Click Background Removal | AI isolates primary subject and turns background fully transparent. | **High Delight:** Instant cutout of app windows, icons, or floating UI dialogs. | **`yes`** | Implement using macOS `VNGenerateForegroundInstanceMaskRequest`. |
| | Background Replace | Replacing removed background with transparent alpha, solid color, or gradient. | **High:** Clean presentation of isolated UI components. | **`yes`** | Once foreground is lifted, offer Transparent PNG, Solid White, or Solid Dark options. |
| | Edge Refining / Feathering Brush | Fine manual brush to de-fringe hair, fur, or semi-transparent pixels. | **Low:** UI elements have sharp vector boundaries, unlike hair or foliage in photos. | **`no`** | Not needed for digital UI cutouts. |
| **12. Export & Output** | Copy to Clipboard | Rendering annotated composite directly to `NSPasteboard` without saving a file. | **Absolute P0:** The single most frequent workflow on macOS (capture -> annotate -> Cmd+C -> paste in Slack/GitHub). | **`yes`** | Prominent "Copy Image" button + Cmd+C keyboard shortcut; optional auto-copy on tool close. |
| | Drag-and-Drop Out | Dragging canvas or floating thumbnail directly into Slack, Finder, or browser. | **Absolute P0:** Standard macOS ergonomic expectation for screenshot utilities. | **`yes`** | `Transferable` conformance supporting `.png` and `.tiff` drags to any app. |
| | Lossless PNG File Export | Saving 24-bit / 32-bit PNG with preserved alpha transparency. | **Critical:** Default file format for screenshots. | **`yes`** | Standard Save dialog (Cmd+S) and quick export folder preset. |
| | Lossy JPEG / WebP Export | Compression slider to reduce payload size for email or web upload. | **Moderate:** Reducing file size for web forms with strict attachment limits. | **`later`** | Add format dropdown (PNG, JPEG, WebP) with quality slider in v1.1. |
| | Direct AirDrop Sharing | Sending annotated screenshot directly to nearby Macs, iPhones, or iPads. | **High:** Sharing mobile mockups or desktop captures to colleague devices seamlessly. | **`yes`** | SwiftUI `ShareLink` and AppKit `NSSharingService(named: .sendViaAirDrop)`. |
| | Cloud Upload / Shortlink URL | Uploading screenshot to proprietary server and copying public link. | **Complex / High Cost:** Requires backend infrastructure, auth, storage, and GDPR compliance. | **`no`** | Keep Recorte 100% local, private, and serverless for MVP. No cloud dependency. |

---

## Synthesis for "Recorte" (Mac Screenshot Editor)

### 1. The P0 MVP Feature Set ("The Lean Weapon")
To be competitive immediately with established utilities, Recorte must execute a focused set of features with zero friction:

1. **Immediate Capture & Ingest:**
   - Instant paste (`Cmd+V`) from system pasteboard (`NSPasteboard.general`).
   - Drag-and-drop image file or raw image data onto the window.
   - Clean multi-window and tabbed interface via `DocumentGroup` and `NSWindow` tabbing.
2. **Core Crop & Framing:**
   - Precision 8-point rectangular crop with live pixel resolution display.
3. **P0 Annotation Toolkit (Vector Layers):**
   - **Arrow:** Straight vector arrow with clean arrowhead and anchor adjustments.
   - **Rectangle / Rounded Box:** Outline or semi-transparent fill for framing UI sections.
   - **Ellipse / Circle:** For circling buttons and icons.
   - **Text:** Native SF Pro typography with high-contrast background pill for guaranteed legibility.
   - **Numbered Step Badges:** Auto-incrementing circular badges (`1`, `2`, `3`...) on click.
   - **Freehand Pen & Highlighter:** Smooth ink strokes with semi-transparent Multiply blending.
4. **First-Class Redaction:**
   - Regional **Pixelate** tool (adjustable block size).
   - Regional **Gaussian Blur** tool (adjustable blur radius).
5. **Instant Machine Learning Subject Lift:**
   - One-click "Lift Subject / Cutout" using macOS native `VNGenerateForegroundInstanceMaskRequest`. Zero cloud latency, zero external SDKs.
6. **Frictionless Export:**
   - `Cmd+C` copy composite to pasteboard.
   - Drag-and-drop directly into Slack, Teams, GitHub, or Finder.
   - `ShareLink` / AirDrop integration.
   - Robust `UndoManager` integration (`Cmd+Z` / `Cmd+Shift+Z`) for all canvas actions.

---

### 2. Phase 2: High-Value Fast Follows (v1.1 - v1.2)
- **Magnifier Loupe:** Circular zoom lens showing fine UI details or subpixel rendering.
- **Window Frame Generator:** Adding simulated macOS window chrome with traffic lights and native drop shadow.
- **Canvas Padding & Gradient Backgrounds:** Padding screenshots with modern Apple-style mesh or solid backgrounds for social sharing.
- **Mouse Cursor Stamps:** Inserting macOS pointer, hand, and crosshair icons.
- **Side-by-Side Comparison:** 2-up canvas for before/after screenshots.
- **Preset Aspect Ratios:** 16:9, 4:3, 1:1, social card presets.

---

### 3. Explicit Non-Goals (Definitively "No")
- **No Cloud Image Hosting:** Recorte is a private, local-first utility. No mandatory user accounts, subscription logins, or third-party cloud hosting.
- **No Consumer / Beauty Retouching:** No face smoothing, eye enlargement, teeth whitening, or makeup filters.
- **No Novelty / Artistic FX:** No comic book, watercolor, oil painting, glitch, or neon bloom filters.
- **No Scrapbooking / Meme Sticker Collections:** No community sticker marketplace or clip art cluttering the UI.
- **No Complex Raster Masking:** No manual pixel-by-pixel lasso masking brushes; native Vision AI handles subject separation cleanly without user friction.
