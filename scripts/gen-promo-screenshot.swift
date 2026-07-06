#!/usr/bin/env xcrun swift
//
// gen-promo-screenshot.swift
//
// PLACEHOLDER PROMO IMAGES — original artwork generated offscreen with
// AppKit/CoreGraphics. Stand-ins for the App Store detail page until real
// product screenshots are captured; replace screenshots/terminal-{1,2,3}.png
// with actual screenshots of AinkradTerminal when available.
//
// Run headlessly (no window / run loop needed):
//   xcrun swift scripts/gen-promo-screenshot.swift
//
// Renders three ~1440x900 PNGs, each a stylized dark terminal window card on
// a subtle dark gradient background with a traffic-light title strip:
//   terminal-1.png — launch scene (single pane, boot output)
//   terminal-2.png — split panes scene (two panes side by side)
//   terminal-3.png — theme showcase scene (purple accent, theme list)

import AppKit
import CoreGraphics
import Foundation

let width = 1440
let height = 900

// MARK: - Shared drawing vocabulary

struct Palette {
    let glow: NSColor          // radial accent behind the card
    let dots: [NSColor]        // traffic-light dots
    let accent: NSColor        // scene accent (prompt arrows, highlights)
}

struct Line {
    let segments: [(String, NSColor, NSFont)]
}

let bodyFontSize: CGFloat = 20
let promptFont = NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .semibold)
let bodyFont = NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular)

let green = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.55, alpha: 1.0)
let cyan = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.90, alpha: 1.0)
let blue = NSColor(calibratedRed: 0.40, green: 0.62, blue: 0.98, alpha: 1.0)
let purple = NSColor(calibratedRed: 0.66, green: 0.52, blue: 0.96, alpha: 1.0)
let pink = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.70, alpha: 1.0)
let amber = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.35, alpha: 1.0)
let dim = NSColor.white.withAlphaComponent(0.55)
let bright = NSColor.white.withAlphaComponent(0.92)

let bluePalette = Palette(
    glow: NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.55, alpha: 0.28),
    dots: [blue, cyan, purple],
    accent: cyan
)
let purplePalette = Palette(
    glow: NSColor(calibratedRed: 0.38, green: 0.24, blue: 0.55, alpha: 0.30),
    dots: [purple, pink, blue],
    accent: purple
)

/// Draws the shared backdrop + window card + title strip, then hands the
/// content rect to `drawContent`, and writes the PNG.
func renderScene(named fileName: String, title: String, palette: Palette,
                 drawContent: (NSRect) -> Void) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        FileHandle.standardError.write("Failed to create bitmap for \(fileName)\n".data(using: .utf8)!)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let fullRect = NSRect(x: 0, y: 0, width: width, height: height)

    // Background: subtle dark gradient + faint radial accent glow for depth.
    let bgTop = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1.0)
    let bgBottom = NSColor(calibratedRed: 0.04, green: 0.045, blue: 0.06, alpha: 1.0)
    NSGradient(starting: bgTop, ending: bgBottom)?.draw(in: fullRect, angle: -90)
    if let glow = NSGradient(starting: palette.glow, ending: palette.glow.withAlphaComponent(0)) {
        let center = NSPoint(x: CGFloat(width) * 0.5, y: CGFloat(height) * 0.62)
        glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 620, options: [])
    }

    // Terminal window card with soft drop shadow.
    let cardWidth: CGFloat = 1120
    let cardHeight: CGFloat = 660
    let cardRect = NSRect(x: (CGFloat(width) - cardWidth) / 2, y: (CGFloat(height) - cardHeight) / 2,
                          width: cardWidth, height: cardHeight)
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 20, yRadius: 20)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.078, green: 0.086, blue: 0.11, alpha: 1.0).setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.06).setStroke()
    cardPath.lineWidth = 1
    cardPath.stroke()

    // Title strip (clipped to keep the top corners rounded) + hairline.
    let stripHeight: CGFloat = 44
    let stripRect = NSRect(x: cardRect.minX, y: cardRect.maxY - stripHeight,
                           width: cardRect.width, height: stripHeight)
    NSGraphicsContext.saveGraphicsState()
    cardPath.addClip()
    NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0).setFill()
    stripRect.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.08).setStroke()
    let sep = NSBezierPath()
    sep.move(to: NSPoint(x: cardRect.minX, y: stripRect.minY))
    sep.line(to: NSPoint(x: cardRect.maxX, y: stripRect.minY))
    sep.lineWidth = 1
    sep.stroke()

    // Traffic-light dots in the palette's colors (original styling).
    var dotX = cardRect.minX + 24
    for color in palette.dots {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX - 6, y: stripRect.midY - 6, width: 12, height: 12)).fill()
        dotX += 22
    }

    // Centered title label.
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.75),
    ]
    let titleString = title as NSString
    let titleSize = titleString.size(withAttributes: titleAttrs)
    titleString.draw(at: NSPoint(x: stripRect.midX - titleSize.width / 2,
                                 y: stripRect.midY - titleSize.height / 2),
                     withAttributes: titleAttrs)

    // Scene-specific content below the strip.
    drawContent(NSRect(x: cardRect.minX, y: cardRect.minY,
                       width: cardRect.width, height: cardRect.height - stripHeight))

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode \(fileName)\n".data(using: .utf8)!)
        exit(1)
    }
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let outputURL = scriptDir.deletingLastPathComponent().appendingPathComponent("screenshots/\(fileName)")
    do {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData.write(to: outputURL)
        print("Wrote \(outputURL.path) (\(width)x\(height))")
    } catch {
        FileHandle.standardError.write("Failed to write \(fileName): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// Draws `lines` top-down starting near the top of `rect`, returning the end
/// point of the last line so a cursor block can follow it.
@discardableResult
func drawLines(_ lines: [Line], in rect: NSRect, inset: CGFloat = 32,
               lineHeight: CGFloat = 40, topPadding: CGFloat = 56) -> NSPoint {
    let startX = rect.minX + inset
    var startY = rect.maxY - topPadding
    var endPoint = NSPoint(x: startX, y: startY)
    for line in lines {
        var x = startX
        let maxAscent = line.segments.map { $0.2.ascender }.max() ?? bodyFont.ascender
        let y = startY - maxAscent
        for (text, color, font) in line.segments {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let nsText = text as NSString
            nsText.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            x += nsText.size(withAttributes: attrs).width
        }
        endPoint = NSPoint(x: x, y: y)
        startY -= lineHeight
    }
    return endPoint
}

func drawCursor(after point: NSPoint) {
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSRect(x: point.x + 4, y: point.y, width: 11, height: promptFont.ascender * 0.9).fill()
}

// MARK: - Scene 1 — launch (single pane, boot output)

renderScene(named: "terminal-1.png", title: "Terminal — Ainkrad", palette: bluePalette) { content in
    let end = drawLines([
        Line(segments: [("ahmed@ainkrad ", green, promptFont), ("~ % ", blue, promptFont), ("ainkrad terminal --launch", bright, bodyFont)]),
        Line(segments: [("→ Loading workspace…", cyan, bodyFont)]),
        Line(segments: [("→ Theme: ", dim, bodyFont), ("Dracula", purple, bodyFont)]),
        Line(segments: [("→ Panes: ", dim, bodyFont), ("2 split, 1 active", bright, bodyFont)]),
        Line(segments: [("✓ Ready", green, promptFont)]),
        Line(segments: [("ahmed@ainkrad ", green, promptFont), ("~ % ", blue, promptFont)]),
    ], in: content)
    drawCursor(after: end)
}

// MARK: - Scene 2 — split panes (two panes side by side)

renderScene(named: "terminal-2.png", title: "Terminal — Split Panes", palette: bluePalette) { content in
    // Divider between the two panes.
    let midX = content.midX
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: midX, y: content.minY + 16))
    divider.line(to: NSPoint(x: midX, y: content.maxY - 16))
    divider.lineWidth = 1
    divider.stroke()

    let leftPane = NSRect(x: content.minX, y: content.minY, width: content.width / 2, height: content.height)
    let rightPane = NSRect(x: midX, y: content.minY, width: content.width / 2, height: content.height)

    let end = drawLines([
        Line(segments: [("ahmed@ainkrad ", green, promptFont), ("~ % ", blue, promptFont), ("make test", bright, bodyFont)]),
        Line(segments: [("→ Building…", cyan, bodyFont)]),
        Line(segments: [("→ Running 307 tests", dim, bodyFont)]),
        Line(segments: [("✓ All tests passed", green, promptFont)]),
        Line(segments: [("ahmed@ainkrad ", green, promptFont), ("~ % ", blue, promptFont)]),
    ], in: leftPane)
    drawCursor(after: end)

    drawLines([
        Line(segments: [("ahmed@ainkrad ", green, promptFont), ("~ % ", blue, promptFont), ("tail -f app.log", bright, bodyFont)]),
        Line(segments: [("12:01 ", dim, bodyFont), ("INFO ", cyan, bodyFont), ("workspace loaded", bright, bodyFont)]),
        Line(segments: [("12:01 ", dim, bodyFont), ("INFO ", cyan, bodyFont), ("theme applied", bright, bodyFont)]),
        Line(segments: [("12:02 ", dim, bodyFont), ("WARN ", amber, bodyFont), ("slow frame (18ms)", bright, bodyFont)]),
        Line(segments: [("12:02 ", dim, bodyFont), ("INFO ", cyan, bodyFont), ("pane resized", bright, bodyFont)]),
    ], in: rightPane)
}

// MARK: - Scene 3 — theme showcase (purple accent, theme list)

renderScene(named: "terminal-3.png", title: "Terminal — Themes", palette: purplePalette) { content in
    let end = drawLines([
        Line(segments: [("ahmed@ainkrad ", pink, promptFont), ("~ % ", purple, promptFont), ("ainkrad theme --list", bright, bodyFont)]),
        Line(segments: [("● Neon Blue", blue, bodyFont), ("     — host default", dim, bodyFont)]),
        Line(segments: [("● Dracula", purple, bodyFont), ("       — active", pink, bodyFont)]),
        Line(segments: [("● Solar Amber", amber, bodyFont)]),
        Line(segments: [("● Mint", green, bodyFont)]),
        Line(segments: [("✓ Colors follow the host's DesignTokens", purple, promptFont)]),
        Line(segments: [("ahmed@ainkrad ", pink, promptFont), ("~ % ", purple, promptFont)]),
    ], in: content)
    drawCursor(after: end)
}
