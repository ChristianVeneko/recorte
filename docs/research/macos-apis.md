# Modern macOS SwiftUI & AppKit API Guide for "Recorte"

This document provides concrete, production-ready Swift code samples, architectural best practices, and official Apple Developer documentation references for building a high-performance, native macOS screenshot editor (**Recorte**).

---

## 1. Liquid Glass & Contemporary macOS Materials

### Architectural Overview
macOS has evolved from traditional `NSVisualEffectView` materials (`.behindWindow`, `.sidebar`, `.headerView`) toward dynamic, physics-informed **Liquid Glass** surfaces. Liquid Glass introduces real-time optical refraction, specular highlights that respond to pointer movement, and fluid morphing between adjacent interactive elements.

In SwiftUI, the system surfaces these aesthetics through:
1. `.glassEffect(_:in:)`: Transforms any view into an optically refractive glass element.
2. `GlassEffectContainer`: Combines adjacent glass elements into a continuous, morphing surface where boundaries fluidly blend.
3. `.buttonStyle(.glass)` & `.buttonStyle(.glassProminent)`: Built-in control styles that automatically handle glass borders, dynamic lighting, and pressed states.
4. Native Toolbar Integration: Blending translucent materials seamlessly across window titlebars and content areas using `.toolbarBackground(.visible, for: .windowToolbar)`.

### Concrete Code Sample

```swift
import SwiftUI
import AppKit

// MARK: - Modern Liquid Glass Floating Annotation HUD
struct GlassAnnotationToolbar: View {
    @Binding var selectedTool: AnnotationTool
    @Namespace private var glassHUDNamespace

    var body: some View {
        // Grouping related glass controls in a GlassEffectContainer allows
        // their surfaces to smoothly blend and share refractive physics
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                // Standard Liquid Glass Button
                Button {
                    selectedTool = .arrow
                } label: {
                    Label("Arrow", systemImage: "arrow.up.right")
                }
                .buttonStyle(.glass)
                .glassEffectUnion(id: "tool-arrow", namespace: glassHUDNamespace)

                Button {
                    selectedTool = .rectangle
                } label: {
                    Label("Box", systemImage: "rectangle")
                }
                .buttonStyle(.glass)
                .glassEffectUnion(id: "tool-rect", namespace: glassHUDNamespace)

                Button {
                    selectedTool = .blur
                } label: {
                    Label("Blur", systemImage: "checkerboard.rectangle")
                }
                .buttonStyle(.glass)
                .glassEffectUnion(id: "tool-blur", namespace: glassHUDNamespace)

                Divider()
                    .frame(height: 20)

                // High-emphasis Action Button using .glassProminent
                Button {
                    // Export / Copy Action
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                .glassEffectUnion(id: "action-copy", namespace: glassHUDNamespace)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // General custom glass background modifier bound to a rounded capsule
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
        }
    }
}

// MARK: - AppKit Fallback Bridge (NSVisualEffectView)
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

enum AnnotationTool: String, CaseIterable {
    case arrow, rectangle, blur, text, pen
}
```

### Source URLs
- **SwiftUI `glassEffect(_:in:)`**: [https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- **SwiftUI `GlassEffectContainer`**: [https://developer.apple.com/documentation/swiftui/glasseffectcontainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- **Apple Human Interface Guidelines – Materials**: [https://developer.apple.com/design/human-interface-guidelines/materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- **AppKit `NSVisualEffectView`**: [https://developer.apple.com/documentation/appkit/nsvisualeffectview](https://developer.apple.com/documentation/appkit/nsvisualeffectview)

---

## 2. Document Tabs (`DocumentGroup` / `NSWindow` Tabbing)

### Architectural Overview
A native macOS screenshot editor shines when it respects the system windowing model:
1. **SwiftUI `DocumentGroup`:** Provides multi-document architecture out of the box, automatic dirty state tracking, file saving, and document-level undo stacks.
2. **`NSWindow` Tabbing:** macOS automatically clusters open document windows into tabs when configured or when user settings dictate (`NSWindow.userTabbingPreference`). To guarantee all screenshots open as tabs in a single unified window (like Safari or Preview), developers set `tabbingMode = .preferred` and unify the `tabbingIdentifier`.

### Concrete Code Sample

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 1. Document Definition conforming to FileDocument
struct ScreenshotDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .tiff, .jpeg] }
    static var writableContentTypes: [UTType] { [.png] }

    var image: NSImage?

    init(image: NSImage? = nil) {
        self.image = image
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let loadedImage = NSImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.image = loadedImage
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let image = image,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: pngData)
    }
}

// MARK: - 2. Window Tabbing Customizer via NSViewRepresentable
struct WindowTabbingBridge: NSViewRepresentable {
    let tabbingIdentifier = "RecorteDocumentWindowGroup"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Force window into tabbed mode and set uniform group ID
            window.tabbingMode = .preferred
            window.tabbingIdentifier = self.tabbingIdentifier
            NSWindow.allowsAutomaticWindowTabbing = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 3. SwiftUI App Scene
@main
struct RecorteApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: ScreenshotDocument()) { file in
            ContentView(document: file.$document)
                .background(WindowTabbingBridge())
        }
        .commands {
            // Native Window tabbing menu items (Show Next Tab, Merge All Windows)
            CommandGroup(after: .windowArrangement) {
                Button("Merge All Windows into Tabs") {
                    NSApp.sendAction(Selector(("mergeAllWindows:")), to: nil, from: nil)
                }
            }
        }
    }
}

struct ContentView: View {
    @Binding var document: ScreenshotDocument

    var body: some View {
        VStack {
            if let image = document.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("No Image Loaded", systemImage: "photo")
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
```

### Source URLs
- **SwiftUI `DocumentGroup`**: [https://developer.apple.com/documentation/swiftui/documentgroup](https://developer.apple.com/documentation/swiftui/documentgroup)
- **SwiftUI `FileDocument`**: [https://developer.apple.com/documentation/swiftui/filedocument](https://developer.apple.com/documentation/swiftui/filedocument)
- **AppKit `NSWindow.tabbingMode`**: [https://developer.apple.com/documentation/appkit/nswindow/tabbingmode](https://developer.apple.com/documentation/appkit/nswindow/tabbingmode)
- **AppKit `NSWindow.addTabbedWindow(_:ordered:)`**: [https://developer.apple.com/documentation/appkit/nswindow/1644704-addtabbedwindow](https://developer.apple.com/documentation/appkit/nswindow/1644704-addtabbedwindow)
- **AppKit `NSWindow.tabbingIdentifier`**: [https://developer.apple.com/documentation/appkit/nswindow/tabbingidentifier](https://developer.apple.com/documentation/appkit/nswindow/tabbingidentifier)

---

## 3. Pasting Images from `NSPasteboard` (Cmd+V Screenshots)

### Architectural Overview
Users frequently capture screenshots to the clipboard via `Cmd+Ctrl+Shift+4` or copy image files from Finder. A Mac screenshot editor must handle two distinct clipboard payloads on `Cmd+V`:
1. **Raw in-memory raster data:** Bitmaps stored as `.tiff` or `public.png`.
2. **File URLs (`NSURL`):** Image files copied directly from Finder (`kUTTypeFileURL`).

### Concrete Code Sample

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class PasteboardService {
    static let shared = PasteboardService()

    /// Reads an image from the general pasteboard, checking both raw image data and file URLs
    func readImageFromPasteboard() -> NSImage? {
        let pasteboard = NSPasteboard.general

        // 1. Check for directly instantiated NSImage objects (handles TIFF, PNG in clipboard)
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return image
        }

        // 2. Check for copied image file URLs from Finder
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        // 3. Fallback: inspect raw PNG or TIFF data directly
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return NSImage(data: data)
        }

        return nil
    }

    /// Writes an image to the system pasteboard (Cmd+C export workflow)
    func copyImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            pasteboard.writeObjects([image])
            return
        }

        pasteboard.setData(pngData, forType: .png)
        pasteboard.setData(tiffData, forType: .tiff)
    }
}

// MARK: - SwiftUI Paste Integration
struct CanvasPasteView: View {
    @State private var canvasImage: NSImage?

    var body: some View {
        ZStack {
            if let canvasImage {
                Image(nsImage: canvasImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("Press ⌘V to Paste Screenshot")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 500, minHeight: 350)
        // Hidden button bound to Cmd+V shortcut
        .background {
            Button("Paste") {
                if let image = PasteboardService.shared.readImageFromPasteboard() {
                    self.canvasImage = image
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0)
        }
        // Modern declarative SwiftUI paste destination
        .pasteDestination(for: Data.self) { items in
            guard let firstData = items.first, let image = NSImage(data: firstData) else {
                return
            }
            self.canvasImage = image
        }
    }
}
```

### Source URLs
- **AppKit `NSPasteboard`**: [https://developer.apple.com/documentation/appkit/nspasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
- **AppKit `NSPasteboard.readObjects(forClasses:options:)`**: [https://developer.apple.com/documentation/appkit/nspasteboard/1533599-readobjects](https://developer.apple.com/documentation/appkit/nspasteboard/1533599-readobjects)
- **SwiftUI `pasteDestination(for:action:validator:)`**: [https://developer.apple.com/documentation/swiftui/view/pastedestination(for:action:validator:)](https://developer.apple.com/documentation/swiftui/view/pastedestination(for:action:validator:))
- **SwiftUI `onPasteCommand(of:perform:)`**: [https://developer.apple.com/documentation/swiftui/view/onpastecommand(of:perform:)](https://developer.apple.com/documentation/swiftui/view/onpastecommand(of:perform:))

---

## 4. Drag and Drop Between Windows and Tabs (`Transferable`)

### Architectural Overview
In modern macOS SwiftUI, inter-window and cross-app drag-and-drop is powered by Apple's **`CoreTransferable`** framework:
- **`Transferable` Protocol:** Models declare how data is encoded and exported.
- **`.draggable(_:)`:** Marks a view or image as draggable.
- **`.dropDestination(for:action:isTargeted:)`:** Declares an accept zone that responds to incoming typed drops and hover state feedback.

### Concrete Code Sample

```swift
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - 1. Transferable Wrapper for Image Data
struct TransferableScreenshot: Transferable {
    let image: NSImage

    static var transferRepresentation: some TransferRepresentation {
        // Export as PNG data so external apps (Slack, Messages, Finder) accept the drop
        DataRepresentation(exportedContentType: .png) { screenshot in
            guard let tiffData = screenshot.image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return pngData
        }
        // Import raw image data dropped from other windows or tabs
        DataRepresentation(importedContentType: .image) { data in
            guard let image = NSImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return TransferableScreenshot(image: image)
        }
    }
}

// MARK: - 2. Drag & Drop Canvas View
struct DragDropEditorView: View {
    @State private var activeImage: NSImage?
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack {
            if let activeImage {
                Image(nsImage: activeImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Enable dragging current image OUT to other windows/tabs/apps
                    .draggable(TransferableScreenshot(image: activeImage)) {
                        // Drag preview thumbnail
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 80)
                            .cornerRadius(6)
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Drag image here from another tab or window")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        // Enable dropping images IN from other windows/tabs
        .dropDestination(for: TransferableScreenshot.self) { items, location in
            guard let dropped = items.first else { return false }
            withAnimation(.spring(response: 0.35, dampingRatio: 0.8)) {
                self.activeImage = dropped.image
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isDropTargeted = targeted
            }
        }
    }
}
```

### Source URLs
- **CoreTransferable `Transferable`**: [https://developer.apple.com/documentation/coretransferable/transferable](https://developer.apple.com/documentation/coretransferable/transferable)
- **SwiftUI `draggable(_:)`**: [https://developer.apple.com/documentation/swiftui/view/draggable(_:)](https://developer.apple.com/documentation/swiftui/view/draggable(_:))
- **SwiftUI `dropDestination(for:action:istargeted:)`**: [https://developer.apple.com/documentation/swiftui/view/dropdestination(for:action:istargeted:)](https://developer.apple.com/documentation/swiftui/view/dropdestination(for:action:istargeted:))

---

## 5. AirDrop Sharing (`ShareLink` & `NSSharingService`)

### Architectural Overview
macOS offers two distinct patterns for AirDrop sharing:
1. **SwiftUI `ShareLink`:** The system standard share sheet popover. It presents AirDrop, Mail, Messages, and third-party extensions.
2. **AppKit `NSSharingService(named: .sendViaAirDrop)`:** Direct invocation of the dedicated AirDrop transfer sheet, bypassing the general picker for a one-click AirDrop workflow.

### Concrete Code Sample

```swift
import SwiftUI
import AppKit

struct AirDropExportBar: View {
    let screenshot: NSImage

    var body: some View {
        HStack(spacing: 12) {
            // 1. Modern Declarative ShareLink (macOS standard share popover)
            ShareLink(
                item: Image(nsImage: screenshot),
                preview: SharePreview("Recorte Screenshot", image: Image(nsImage: screenshot))
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glass)

            // 2. Direct One-Click AirDrop Button (AppKit direct service)
            Button {
                directAirDrop(image: screenshot)
            } label: {
                Label("AirDrop", systemImage: "airdrop")
            }
            .buttonStyle(.glassProminent)
        }
    }

    /// Invokes the native macOS AirDrop service directly
    private func directAirDrop(image: NSImage) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            NSSound.beep()
            return
        }

        // Pass temporary file URL or NSImage directly
        let itemsToShare: [Any] = [image]

        if service.canPerform(withItems: itemsToShare) {
            service.perform(withItems: itemsToShare)
        } else {
            NSSound.beep()
        }
    }
}
```

### Source URLs
- **SwiftUI `ShareLink`**: [https://developer.apple.com/documentation/swiftui/sharelink](https://developer.apple.com/documentation/swiftui/sharelink)
- **AppKit `NSSharingService`**: [https://developer.apple.com/documentation/appkit/nssharingservice](https://developer.apple.com/documentation/appkit/nssharingservice)
- **AppKit `NSSharingService.Name.sendViaAirDrop`**: [https://developer.apple.com/documentation/appkit/nssharingservice/name/1531238-sendviaairdrop](https://developer.apple.com/documentation/appkit/nssharingservice/name/1531238-sendviaairdrop)

---

## 6. Core Image Filters (`CIFilterBuiltins`, `CIContext`)

### Architectural Overview
Core Image provides hardware-accelerated, GPU-bound image processing. For a screenshot editor:
- **Redaction is essential:** Selective `gaussianBlur` and `pixellate` over user-selected bounding boxes.
- **Performance rule:** Allocate a single `CIContext` backed by the default Metal device and reuse it across render passes. Creating `CIContext` repeatedly causes high memory churn and frame drops.
- **Coordinate Space:** Core Image uses bottom-left origin `(0, 0)`, whereas SwiftUI and AppKit use top-left origin. Rectangles must be inverted vertically before filtering.

### Concrete Code Sample

```swift
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

final class ScreenshotFilterEngine {
    static let shared = ScreenshotFilterEngine()

    // Persistent Metal-accelerated CIContext (never recreate in render loops)
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Applies regional pixelation redaction over a specific rectangle on an NSImage
    func applyRedaction(
        to sourceImage: NSImage,
        redactRect: CGRect,
        mode: RedactionMode = .pixelate(blockSize: 16.0)
    ) -> NSImage? {
        guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let inputCIImage = CIImage(cgImage: cgImage)
        let imageExtent = inputCIImage.extent

        // Convert AppKit top-left coordinate system to Core Image bottom-left
        let ciTargetRect = CGRect(
            x: redactRect.origin.x,
            y: imageExtent.height - redactRect.origin.y - redactRect.height,
            width: redactRect.width,
            height: redactRect.height
        )

        // 1. Generate the redacted image
        let redactedCIImage: CIImage
        switch mode {
        case .pixelate(let blockSize):
            let filter = CIFilter.pixellate()
            filter.inputImage = inputCIImage
            filter.scale = Float(blockSize)
            filter.center = CGPoint(x: ciTargetRect.midX, y: ciTargetRect.midY)
            redactedCIImage = filter.outputImage ?? inputCIImage

        case .blur(let radius):
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = inputCIImage.clampedToExtent()
            filter.radius = Float(radius)
            redactedCIImage = (filter.outputImage ?? inputCIImage).cropped(to: imageExtent)
        }

        // 2. Crop redacted result to target rect, then composite over original image
        let croppedRedaction = redactedCIImage.cropped(to: ciTargetRect)
        let compositeFilter = CIFilter.sourceOverCompositing()
        compositeFilter.inputImage = croppedRedaction
        compositeFilter.backgroundImage = inputCIImage

        guard let outputCI = compositeFilter.outputImage,
              let outputCG = context.createCGImage(outputCI, from: imageExtent) else {
            return nil
        }

        return NSImage(cgImage: outputCG, size: sourceImage.size)
    }

    enum RedactionMode {
        case pixelate(blockSize: Float)
        case blur(radius: Float)
    }
}
```

### Source URLs
- **Core Image Framework**: [https://developer.apple.com/documentation/coreimage](https://developer.apple.com/documentation/coreimage)
- **Core Image `CIFilterBuiltins`**: [https://developer.apple.com/documentation/coreimage/cifilterbuiltins](https://developer.apple.com/documentation/coreimage/cifilterbuiltins)
- **Core Image `CIContext`**: [https://developer.apple.com/documentation/coreimage/cicontext](https://developer.apple.com/documentation/coreimage/cicontext)

---

## 7. Vision Subject Lift (`VNGenerateForegroundInstanceMaskRequest`)

### Architectural Overview
Introduced in macOS 14 Sonoma (and enhanced in macOS 15+), `VNGenerateForegroundInstanceMaskRequest` executes Apple's machine learning foreground segmentation on the Apple Neural Engine:
1. Detects salient foreground objects (windows, people, products, icons).
2. Generates a `VNInstanceMaskObservation`.
3. Directly outputs an isolated cutout image with a transparent background via `generateMaskedImage(ofInstances:from:croppedToInstancesExtent:)`.

### Concrete Code Sample

```swift
import Vision
import CoreImage
import AppKit

final class SubjectLiftService {
    static let shared = SubjectLiftService()
    private let ciContext = CIContext()

    /// Lifts the foreground subject from an NSImage and returns a transparent cutout
    func liftSubject(from image: NSImage) async throws -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "SubjectLift", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid CGImage"])
        }

        // 1. Create the Vision Request Handler
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        // 2. Configure Foreground Instance Mask Request
        let request = VNGenerateForegroundInstanceMaskRequest()

        // 3. Perform Vision Request asynchronously
        try requestHandler.perform([request])

        guard let observation = request.results?.first else {
            throw NSError(domain: "SubjectLift", code: -2, userInfo: [NSLocalizedDescriptionKey: "No subject detected"])
        }

        // 4. Extract all detected foreground instances into an isolated masked pixel buffer
        let maskedPixelBuffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: requestHandler,
            croppedToInstancesExtent: false
        )

        // 5. Convert CVPixelBuffer to CIImage -> CGImage -> NSImage
        let ciImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
        guard let outputCG = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw NSError(domain: "SubjectLift", code: -3, userInfo: [NSLocalizedDescriptionKey: "Render failed"])
        }

        return NSImage(cgImage: outputCG, size: image.size)
    }
}
```

### Source URLs
- **Vision `VNGenerateForegroundInstanceMaskRequest`**: [https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- **Vision `VNInstanceMaskObservation`**: [https://developer.apple.com/documentation/vision/vninstancemaskobservation](https://developer.apple.com/documentation/vision/vninstancemaskobservation)
- **Vision `VNImageRequestHandler`**: [https://developer.apple.com/documentation/vision/vnimagerequesthandler](https://developer.apple.com/documentation/vision/vnimagerequesthandler)

---

## 8. Keyboard Shortcuts & Menu Commands

### Architectural Overview
Power users navigate screenshot tools through single-key shortcuts (`C` for Crop, `A` for Arrow, `T` for Text, `B` for Blur) and system modifiers (`Cmd+C` copy, `Cmd+S` save, `Cmd+Z` undo).
- SwiftUI `.keyboardShortcut(_:modifiers:)` attaches triggers to buttons and menu items.
- Empty modifiers `modifiers: []` enables single-key tool switching.
- `.commands { CommandMenu(...) }` attaches shortcuts to the macOS system menu bar.

### Concrete Code Sample

```swift
import SwiftUI

struct ToolSelectorToolbar: View {
    @Binding var currentTool: Tool

    var body: some View {
        HStack(spacing: 4) {
            // Single-key shortcut: 'C' triggers Crop
            Button {
                currentTool = .crop
            } label: {
                Label("Crop (C)", systemImage: "crop")
            }
            .keyboardShortcut("c", modifiers: [])
            .buttonStyle(.glass)

            // Single-key shortcut: 'A' triggers Arrow
            Button {
                currentTool = .arrow
            } label: {
                Label("Arrow (A)", systemImage: "arrow.up.right")
            }
            .keyboardShortcut("a", modifiers: [])
            .buttonStyle(.glass)

            // Single-key shortcut: 'R' triggers Rectangle
            Button {
                currentTool = .rectangle
            } label: {
                Label("Rect (R)", systemImage: "rectangle")
            }
            .keyboardShortcut("r", modifiers: [])
            .buttonStyle(.glass)

            // Single-key shortcut: 'B' triggers Blur/Redact
            Button {
                currentTool = .redact
            } label: {
                Label("Redact (B)", systemImage: "checkerboard.rectangle")
            }
            .keyboardShortcut("b", modifiers: [])
            .buttonStyle(.glass)
        }
    }

    enum Tool {
        case select, crop, arrow, rectangle, redact
    }
}

// MARK: - App Commands Structure (System Menu Bar)
struct RecorteCommands: Commands {
    var body: some Commands {
        CommandMenu("Tools") {
            Button("Crop Tool") { }
                .keyboardShortcut("c", modifiers: [])

            Button("Arrow Tool") { }
                .keyboardShortcut("a", modifiers: [])

            Button("Redaction Tool") { }
                .keyboardShortcut("b", modifiers: [])
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy Composite Image") { }
                .keyboardShortcut("c", modifiers: .command)

            Button("Paste Image") { }
                .keyboardShortcut("v", modifiers: .command)
        }
    }
}
```

### Source URLs
- **SwiftUI `keyboardShortcut(_:modifiers:)`**: [https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:)](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:))
- **SwiftUI `KeyboardShortcut`**: [https://developer.apple.com/documentation/swiftui/keyboardshortcut](https://developer.apple.com/documentation/swiftui/keyboardshortcut)
- **SwiftUI `Commands` & `CommandMenu`**: [https://developer.apple.com/documentation/swiftui/commands](https://developer.apple.com/documentation/swiftui/commands)

---

## 9. UndoManager Integration

### Architectural Overview
A non-destructive screenshot annotation tool must maintain an undo/redo stack for adding, modifying, moving, and removing vector shapes.
- SwiftUI provides the current window's undo manager via `@Environment(\.undoManager)`.
- Operations are registered symmetrically via `undoManager.registerUndo(withTarget:handler:)`.
- Explicit action naming via `undoManager.setActionName(_:)` ensures the macOS Edit menu displays descriptive titles like **"Undo Add Arrow"** or **"Redo Redaction"**.

### Concrete Code Sample

```swift
import SwiftUI
import Foundation

// MARK: - Canvas View Model with Undo Management
@Observable
final class CanvasViewModel {
    var annotations: [AnnotationItem] = []
    weak var undoManager: UndoManager?

    func addAnnotation(_ item: AnnotationItem) {
        let index = annotations.count
        annotations.append(item)

        // Register symmetric undo operation
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAnnotation(at: index)
        }
        undoManager?.setActionName("Add \(item.toolType.capitalized)")
    }

    func removeAnnotation(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        let removedItem = annotations.remove(at: index)

        // Register redo operation
        undoManager?.registerUndo(withTarget: self) { target in
            target.insertAnnotation(removedItem, at: index)
        }
        undoManager?.setActionName("Delete \(removedItem.toolType.capitalized)")
    }

    private func insertAnnotation(_ item: AnnotationItem, at index: Int) {
        annotations.insert(item, at: min(index, annotations.count))
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAnnotation(at: index)
        }
    }
}

struct AnnotationItem: Identifiable, Equatable {
    let id = UUID()
    let toolType: String
    var frame: CGRect
    var color: Color
}

// MARK: - SwiftUI View binding to UndoManager Environment
struct CanvasEditorView: View {
    @Environment(\.undoManager) private var undoManager
    @State private var viewModel = CanvasViewModel()

    var body: some View {
        VStack {
            HStack {
                Button("Add Arrow") {
                    viewModel.addAnnotation(
                        AnnotationItem(toolType: "Arrow", frame: CGRect(x: 50, y: 50, width: 100, height: 2), color: .red)
                    )
                }

                Spacer()

                Button("Undo") {
                    undoManager?.undo()
                }
                .disabled(undoManager?.canUndo == false)
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    undoManager?.redo()
                }
                .disabled(undoManager?.canRedo == false)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .padding()

            Text("Active Annotations: \(viewModel.annotations.count)")
                .font(.headline)
        }
        .onAppear {
            // Inject environment UndoManager into view model
            viewModel.undoManager = undoManager
        }
    }
}
```

### Source URLs
- **Foundation `UndoManager`**: [https://developer.apple.com/documentation/foundation/undomanager](https://developer.apple.com/documentation/foundation/undomanager)
- **SwiftUI `EnvironmentValues.undoManager`**: [https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager](https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager)
- **AppKit `NSResponder.undoManager`**: [https://developer.apple.com/documentation/appkit/nsresponder/1528246-undomanager](https://developer.apple.com/documentation/appkit/nsresponder/1528246-undomanager)

---

## 10. Master API & Documentation Index

| Feature Domain | Framework | Key Types & Methods | Official Apple Documentation URL |
| :--- | :--- | :--- | :--- |
| **Liquid Glass** | SwiftUI | `glassEffect(_:in:)`, `GlassEffectContainer` | [apple.com/.../glasseffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) |
| **Glass Buttons** | SwiftUI | `buttonStyle(.glass)`, `buttonStyle(.glassProminent)` | [apple.com/.../materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| **Document Tabs** | SwiftUI | `DocumentGroup`, `FileDocument` | [apple.com/.../documentgroup](https://developer.apple.com/documentation/swiftui/documentgroup) |
| **Window Tabbing** | AppKit | `NSWindow.tabbingMode`, `addTabbedWindow(_:ordered:)` | [apple.com/.../tabbingmode](https://developer.apple.com/documentation/appkit/nswindow/tabbingmode) |
| **Pasteboard** | AppKit | `NSPasteboard.general`, `readObjects(forClasses:options:)` | [apple.com/.../nspasteboard](https://developer.apple.com/documentation/appkit/nspasteboard) |
| **Paste Destination** | SwiftUI | `pasteDestination(for:action:validator:)` | [apple.com/.../pastedestination](https://developer.apple.com/documentation/swiftui/view/pastedestination(for:action:validator:)) |
| **Drag and Drop** | CoreTransferable | `Transferable`, `draggable(_:)`, `dropDestination` | [apple.com/.../transferable](https://developer.apple.com/documentation/coretransferable/transferable) |
| **AirDrop Sharing** | SwiftUI | `ShareLink(item:preview:)` | [apple.com/.../sharelink](https://developer.apple.com/documentation/swiftui/sharelink) |
| **Direct AirDrop** | AppKit | `NSSharingService(named: .sendViaAirDrop)` | [apple.com/.../nssharingservice](https://developer.apple.com/documentation/appkit/nssharingservice) |
| **Core Image Filters** | Core Image | `CIFilterBuiltins`, `CIContext`, `CIImage` | [apple.com/.../coreimage](https://developer.apple.com/documentation/coreimage) |
| **Vision Subject Lift** | Vision | `VNGenerateForegroundInstanceMaskRequest` | [apple.com/.../vngenerateforegroundinstancemaskrequest](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest) |
| **Subject Mask Obs.** | Vision | `VNInstanceMaskObservation` | [apple.com/.../vninstancemaskobservation](https://developer.apple.com/documentation/vision/vninstancemaskobservation) |
| **Shortcuts & Menus** | SwiftUI | `keyboardShortcut(_:modifiers:)`, `CommandMenu` | [apple.com/.../keyboardshortcut](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:)) |
| **Undo / Redo** | Foundation | `UndoManager`, `@Environment(\.undoManager)` | [apple.com/.../undomanager](https://developer.apple.com/documentation/foundation/undomanager) |
