#!/usr/bin/env swift
//
// Erzeugt das App-Icon und legt es als Sources/Resources/AppIcon.icns ab.
//
//   swift scripts/make-icon.swift
//
// Das Icon wird gezeichnet statt als Binaerdatei eingecheckt: so laesst sich
// die Gestaltung nachvollziehen und aendern, ohne ein Grafikprogramm zu oeffnen.

import AppKit
import Foundation

// MARK: - Gestaltung

/// Drei Schieberegler auf unterschiedlicher Hoehe — dasselbe Motiv wie in der
/// Menueleiste, damit App und Symbol als zusammengehoerig erkennbar sind.
let sliderPositions: [CGFloat] = [0.62, 0.34, 0.78]  // Knopfhoehe von oben

let backgroundTop = NSColor(srgbRed: 0.36, green: 0.49, blue: 0.98, alpha: 1)
let backgroundBottom = NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1)

func drawIcon(size: CGFloat, into context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS-Icons sitzen nicht randfuellend, sondern auf einer eingerueckten Flaeche.
    let inset = size * 0.09
    let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = plate.width * 0.2237  // entspricht der macOS-Squircle-Rundung

    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
    context.saveGState()
    context.addPath(platePath)
    context.clip()

    let colors = [backgroundTop.cgColor, backgroundBottom.cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    // --- Schieberegler ---
    let area = plate.insetBy(dx: plate.width * 0.24, dy: plate.height * 0.20)
    let trackWidth = plate.width * 0.070
    let knobRadius = trackWidth * 1.05
    let count = sliderPositions.count

    for (index, position) in sliderPositions.enumerated() {
        // Gleichmaessig ueber die Breite verteilen.
        let fraction = (CGFloat(index) + 0.5) / CGFloat(count)
        let centerX = area.minX + area.width * fraction

        // Bahn
        let track = CGRect(x: centerX - trackWidth / 2, y: area.minY,
                           width: trackWidth, height: area.height)
        context.setFillColor(NSColor(white: 1, alpha: 0.34).cgColor)
        context.addPath(CGPath(roundedRect: track, cornerWidth: trackWidth / 2,
                               cornerHeight: trackWidth / 2, transform: nil))
        context.fillPath()

        // Gefuellter Teil unterhalb des Knopfes
        let knobY = area.maxY - area.height * position
        let filled = CGRect(x: track.minX, y: area.minY,
                            width: trackWidth, height: knobY - area.minY)
        context.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
        context.addPath(CGPath(roundedRect: filled, cornerWidth: trackWidth / 2,
                               cornerHeight: trackWidth / 2, transform: nil))
        context.fillPath()

        // Knopf
        let knob = CGRect(x: centerX - knobRadius, y: knobY - knobRadius,
                          width: knobRadius * 2, height: knobRadius * 2)
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                          blur: size * 0.012,
                          color: NSColor(white: 0, alpha: 0.30).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: knob)
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
}

// MARK: - Ausgabe

func renderPNG(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    drawIcon(size: CGFloat(size), into: nsContext.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = projectRoot.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Die Groessen, die macOS in einem .icns erwartet.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = renderPNG(size: variant.pixels) else {
        FileHandle.standardError.write("Konnte \(variant.name) nicht zeichnen\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let destination = projectRoot.appendingPathComponent("Sources/Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil fehlgeschlagen\n".data(using: .utf8)!)
    exit(1)
}
print("Geschrieben: \(destination.path)")
