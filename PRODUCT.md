# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Stack

Native macOS app: Swift 6, SwiftUI with AppKit where SwiftUI falls short, Core Image, Vision. Project generated with XcodeGen. Assumption: minimum macOS 26 (Tahoe), required for Liquid Glass.

## Users

Primary user: the owner, a developer who takes screenshots and photos daily and wants to mark them up and make quick edits without opening a heavy editor. Assumption: personal use first; App Store distribution is undecided.

## Product Purpose

A simple Mac photo and screenshot editor in the spirit of PicsArt, not Photoshop. Take a screenshot, paste it, crop it, add text, stickers, shapes, overlays and filters, and share or export it. Success: from Cmd+V to a finished, shared image in seconds.

## Positioning

Cropping is the core job: precise, fast, and flexible cropping (free, aspect ratios, shapes), plus moving cropped pieces between images open in tabs.

## Operating Context

- Input: Cmd+V from the clipboard (macOS screenshots), drag and drop, open file.
- Several images open as tabs; pieces move between tabs (copy/paste or drag) as new layers.
- Output: AirDrop, share sheet, copy to clipboard, export PNG/JPEG/HEIC.
- Heavy keyboard shortcut use.

## Capabilities and Constraints

- Must have: crop (free, ratios, shapes), layers, tabs with cross-tab copy, text with fonts, stickers, shapes/overlays, filters and adjustments, undo/redo, AirDrop, keyboard shortcuts.
- Out of scope: Photoshop-class tools (channels, masks with brushes, RAW development, plugins).
- Must feel native and stay fast on large Retina screenshots.

## Brand Commitments

- Apple Human Interface Guidelines for macOS: standard menus, toolbars, inspectors, SF Symbols, system controls.
- Liquid Glass on selected elements (toolbar, floating tool palettes), using system APIs only.
- Working name "Recorte" (assumption; the owner may rename it).

## Product Principles

1. Cropping first: every image interaction should make cropping and moving pieces easy.
2. Simple over powerful: when a feature needs a manual, cut it.
3. Native first: system controls and shortcuts before custom ones.
4. Instant: paste-to-share in seconds, no waiting on renders.

## Accessibility & Inclusion

Follow macOS defaults: full keyboard access, VoiceOver labels on tools, respect Reduce Motion, Reduce Transparency and Increase Contrast (Liquid Glass falls back correctly).
