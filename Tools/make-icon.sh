#!/usr/bin/env bash
# Régénère l'icône de l'app : un « A » serif blanc sur fond bleu encre, 1024 px.
# Xcode décline seul toutes les tailles à partir de ce seul fichier.
#
# À lancer sur le Mac ; utilise la fonte serif du système (New York).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Atelier/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

swift - "$OUT" <<'SWIFT'
import AppKit

let output = CommandLine.arguments[1]
let side = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap impossible") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// Bleu encre, la même valeur que AccentColor en mode clair.
NSColor(srgbRed: 0x1F / 255.0, green: 0x3A / 255.0, blue: 0x5F / 255.0, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()

let base = NSFont.systemFont(ofSize: 640, weight: .medium)
let serif = base.fontDescriptor.withDesign(.serif)
    .flatMap { NSFont(descriptor: $0, size: 640) } ?? base

let letter = "A" as NSString
let attributes: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: NSColor.white]
let bounds = letter.boundingRect(with: NSSize(width: side, height: side), options: [], attributes: attributes)
letter.draw(
    at: NSPoint(
        x: (CGFloat(side) - bounds.width) / 2 - bounds.origin.x,
        y: (CGFloat(side) - bounds.height) / 2 - bounds.origin.y
    ),
    withAttributes: attributes
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("encodage impossible") }
try png.write(to: URL(fileURLWithPath: output))
print("icône écrite : \(output)")
SWIFT
