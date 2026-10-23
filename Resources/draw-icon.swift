#!/usr/bin/env swift
// Draws the two art masters: ./Resources/draw-icon.swift, then ./Resources/make-icon.swift for the art built from them.
// Resources/AppIcon.png: a cool J in sunglasses on an icy sea, 1024 pixels on Apple's macOS grid, with its shadow.
// Resources/MenuIcon.png: the same J in sunglasses as the menu bar's glyph, black on clear.

import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func degrees(_ value: CGFloat) -> CGFloat { value * .pi / 180 }

// MARK: Shapes

/// Apple's macOS icon tile: an 824-pixel squircle on the 1024 grid
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile).cgPath

/// The J, as thick round-capped strokes like a balloon letter
struct Letter {
    var stemX: CGFloat
    var top: CGFloat
    /// Where the stem starts to curl
    var bend: CGFloat
    var radius: CGFloat
    var weight: CGFloat

    /// Down the stem, around the bottom and up to the left
    var spine: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: stemX, y: top))
        path.addLine(to: CGPoint(x: stemX, y: bend))
        path.addArc(center: CGPoint(x: stemX - radius, y: bend), radius: radius, startAngle: 0,
                    endAngle: degrees(-202), clockwise: true)
        return path
    }

    var outline: CGPath { spine.copy(strokingWithWidth: weight, lineCap: .round, lineJoin: .round, miterLimit: 10) }
}

/// Wayfarers: two lenses under a brow bar, wider at the top
struct Shades {
    var center: CGPoint
    var width: CGFloat
    var height: CGFloat

    private var lensWidth: CGFloat { (width - bridge) / 2 }
    private var bridge: CGFloat { width * 0.09 }

    /// One lens. Its outer top corner rises, like a wayfarer's.
    func lens(left: Bool) -> CGPath {
        let side: CGFloat = left ? -1 : 1
        let inner = center.x + side * bridge / 2, outer = center.x + side * (bridge / 2 + lensWidth)
        let top = center.y + height / 2, bottom = center.y - height / 2
        let corners = [CGPoint(x: inner, y: top - height * 0.06), CGPoint(x: outer, y: top + height * 0.08),
                       CGPoint(x: outer - side * lensWidth * 0.1, y: bottom + height * 0.08),
                       CGPoint(x: inner + side * lensWidth * 0.04, y: bottom)]
        let radii = [height * 0.1, height * 0.16, height * 0.55, height * 0.5]
        let path = CGMutablePath()
        let start = CGPoint(x: (corners[0].x + corners[3].x) / 2, y: (corners[0].y + corners[3].y) / 2)
        path.move(to: start)
        for index in 0..<4 {
            path.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % 4], radius: radii[index])
        }
        path.closeSubpath()
        return path
    }

    var lenses: CGPath { lens(left: true).union(lens(left: false)) }

    /// The frame around the lenses, and the brow bar and bridge between them
    var frame: CGPath {
        let rims = lenses.copy(strokingWithWidth: height * 0.18, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let brow = CGPath(roundedRect: CGRect(x: center.x - width / 2 - height * 0.05, y: center.y + height * 0.3,
                                              width: width + height * 0.1, height: height * 0.32),
                          cornerWidth: height * 0.14, cornerHeight: height * 0.14, transform: nil)
        return rims.union(lenses).union(brow)
    }
}

/// An open smile: flat on top, round below
func smile(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - width / 2, y: center.y + height / 2))
    path.addLine(to: CGPoint(x: center.x + width / 2, y: center.y + height / 2))
    path.addCurve(to: CGPoint(x: center.x, y: center.y - height / 2),
                  control1: CGPoint(x: center.x + width / 2, y: center.y - height * 0.15),
                  control2: CGPoint(x: center.x + width * 0.28, y: center.y - height / 2))
    path.addCurve(to: CGPoint(x: center.x - width / 2, y: center.y + height / 2),
                  control1: CGPoint(x: center.x - width * 0.28, y: center.y - height / 2),
                  control2: CGPoint(x: center.x - width / 2, y: center.y - height * 0.15))
    path.closeSubpath()
    return path
}

/// A four-pointed glint, its sides curving in toward the middle
func sparkle(at center: CGPoint, radius: CGFloat) -> CGPath {
    let tips = [CGPoint(x: center.x, y: center.y + radius), CGPoint(x: center.x + radius, y: center.y),
                CGPoint(x: center.x, y: center.y - radius), CGPoint(x: center.x - radius, y: center.y)]
    let path = CGMutablePath()
    path.move(to: tips[0])
    for index in 1...4 {
        let from = tips[index - 1], to = tips[index % 4]
        let control = CGPoint(x: center.x + (from.x + to.x - 2 * center.x) * 0.14,
                              y: center.y + (from.y + to.y - 2 * center.y) * 0.14)
        path.addQuadCurve(to: to, control: control)
    }
    path.closeSubpath()
    return path
}

// MARK: Painting

/// Fills a path with a soft blur, by drawing it far off the canvas and letting only its shadow land
func blurred(_ ctx: CGContext, _ path: CGPath, _ fill: CGColor, blur: CGFloat, offset: CGSize = .zero) {
    ctx.saveGState()
    let away: CGFloat = 4000
    ctx.setShadow(offset: CGSize(width: away + offset.width, height: offset.height), blur: blur, color: fill)
    var shift = CGAffineTransform(translationX: -away, y: 0)
    if let moved = path.copy(using: &shift) { ctx.addPath(moved) }
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
}

/// Shading just inside a shape's edges, darkest away from the light
func innerShadow(_ ctx: CGContext, _ shape: CGPath, _ shade: CGColor, blur: CGFloat, offset: CGSize) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let hole = CGMutablePath()
    hole.addRect(CGRect(x: -2000, y: -2000, width: 6000, height: 6000))
    hole.addPath(shape)
    ctx.setShadow(offset: offset, blur: blur, color: shade)
    ctx.addPath(hole)
    ctx.setFillColor(shade)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

func wave(top: CGFloat, height: CGFloat, length: CGFloat, phase: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    for x in stride(from: CGFloat(0), through: 1024, by: 4) {
        let angle: CGFloat = 2 * .pi * x / length + phase
        path.addLine(to: CGPoint(x: x, y: top + height * sin(angle)))
    }
    path.addLine(to: CGPoint(x: 1024, y: 0))
    path.closeSubpath()
    return path
}

let letter = Letter(stemX: 668, top: 732, bend: 482, radius: 165, weight: 182)
let shades = Shades(center: CGPoint(x: 648, y: 648), width: 376, height: 116)
let mouthCenter = CGPoint(x: 662, y: 538)
let mouth = smile(center: mouthCenter, width: 92, height: 54)

func drawIcon(_ ctx: CGContext) {
    // The tile, lifted off the desktop
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.42))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1E5FE6))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // Icy light from the top right, deep blue below
    ctx.drawLinearGradient(gradient([(0, color(0x7DEBFF)), (0.42, color(0x2E8DFF)), (1, color(0x1230C4))]),
                           start: CGPoint(x: 900, y: 940), end: CGPoint(x: 160, y: 90), options: [])
    let glow = CGPoint(x: 820, y: 870)
    ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.5)), (1, color(0xFFFFFF, 0))]), startCenter: glow,
                           startRadius: 0, endCenter: glow, endRadius: 460, options: [])
    // Swells, each catching the light along its crest
    let swells: [(top: CGFloat, height: CGFloat, length: CGFloat, phase: CGFloat)] =
        [(590, 36, 980, 0.6), (450, 42, 860, 2.2), (310, 32, 1100, 4.0)]
    for swell in swells {
        let shape = wave(top: swell.top, height: swell.height, length: swell.length, phase: swell.phase)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.26)), (0.35, color(0x2F7BFF, 0.12)),
                                         (1, color(0x061C7A, 0.34))]),
                               start: CGPoint(x: 0, y: swell.top + swell.height), end: CGPoint(x: 0, y: 100),
                               options: [])
        ctx.addPath(shape)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(color(0xFFFFFF, 0.3))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The J's shadow on the sea, then its body
    let body = letter.outline
    blurred(ctx, body, color(0x04155E, 0.55), blur: 34, offset: CGSize(width: 14, height: -26))
    var down = CGAffineTransform(translationX: 0, y: -16)
    let side = body.copy(using: &down)!
    ctx.saveGState()
    ctx.addPath(side)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x9CC2F5)), (1, color(0x5F86D8))]), start: CGPoint(x: 0, y: 820),
                           end: CGPoint(x: 0, y: 200), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF)), (0.55, color(0xF1F7FF)), (1, color(0xCFE2FF))]),
                           start: CGPoint(x: 0, y: 820), end: CGPoint(x: 0, y: 210), options: [])
    ctx.restoreGState()
    innerShadow(ctx, body, color(0x2E62C9, 0.45), blur: 30, offset: CGSize(width: -14, height: 18))
    // Gloss along the upper left of the stroke
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    var gloss = CGAffineTransform(translationX: -letter.weight * 0.2, y: letter.weight * 0.1)
    let shine = letter.spine.copy(using: &gloss)!
        .copy(strokingWithWidth: letter.weight * 0.2, lineCap: .round, lineJoin: .round, miterLimit: 10)
    blurred(ctx, shine, color(0xFFFFFF, 0.9), blur: 16)
    ctx.restoreGState()

    // The shades, with their shadow on the face
    blurred(ctx, shades.frame, color(0x0B2A6B, 0.45), blur: 14, offset: CGSize(width: 4, height: -12))
    ctx.addPath(shades.frame)
    ctx.setFillColor(color(0x0A0C12))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(shades.lenses)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x3A4150)), (0.5, color(0x11141B)), (1, color(0x020305))]),
                           start: CGPoint(x: 0, y: shades.center.y + shades.height / 2),
                           end: CGPoint(x: 0, y: shades.center.y - shades.height / 2), options: [])
    // A streak of reflected sky across each lens
    let streak = CGMutablePath()
    streak.move(to: CGPoint(x: shades.center.x - 230, y: shades.center.y + 20))
    streak.addLine(to: CGPoint(x: shades.center.x - 120, y: shades.center.y + 90))
    streak.addLine(to: CGPoint(x: shades.center.x + 260, y: shades.center.y + 90))
    streak.addLine(to: CGPoint(x: shades.center.x + 150, y: shades.center.y + 20))
    streak.closeSubpath()
    ctx.addPath(streak)
    ctx.setFillColor(color(0xFFFFFF, 0.2))
    ctx.fillPath()
    ctx.restoreGState()
    // The brow bar catches the light
    ctx.saveGState()
    ctx.addPath(shades.frame)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.28)), (0.18, color(0xFFFFFF, 0))]),
                           start: CGPoint(x: 0, y: shades.center.y + shades.height * 0.66),
                           end: CGPoint(x: 0, y: shades.center.y), options: [])
    ctx.restoreGState()
    // Hinge studs
    for x in [shades.center.x - shades.width / 2 + 16, shades.center.x + shades.width / 2 - 16] {
        ctx.addEllipse(in: CGRect(x: x - 7, y: shades.center.y + shades.height * 0.42 - 7, width: 14, height: 14))
        ctx.setFillColor(color(0xC9D3E3))
        ctx.fillPath()
    }

    // A grin
    ctx.addPath(mouth)
    ctx.setFillColor(color(0x10204F))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(mouth)
    ctx.clip()
    ctx.addEllipse(in: CGRect(x: mouthCenter.x - 30, y: mouthCenter.y - 44, width: 60, height: 38))
    ctx.setFillColor(color(0x3C8DFF))
    ctx.fillPath()
    ctx.restoreGState()

    // A glint off the shades
    let glint = sparkle(at: CGPoint(x: 778, y: 688), radius: 34)
    blurred(ctx, glint, color(0xFFFFFF, 0.9), blur: 12)
    ctx.addPath(glint)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // A thin bright rim along the tile's top
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.addPath(tilePath)
    ctx.setLineWidth(6)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: Menu bar glyph

/// The J in black, with a clear gap around the shades and a clear smile, since the menu bar draws only the shape
func drawMenuGlyph(_ ctx: CGContext, size: CGSize) {
    let ink = letter.outline.union(shades.frame)
    let gap = shades.frame.copy(strokingWithWidth: 26, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let glyph = ink.subtracting(gap).union(shades.frame).subtracting(mouth)
    let bounds = glyph.boundingBoxOfPath
    let scale = min(size.width / bounds.width, size.height / bounds.height)
    ctx.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
    ctx.addPath(glyph)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
}

// MARK: Output

func render(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = root.appendingPathComponent(path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

writePNG(render(1024, 1024, drawIcon), to: "Resources/AppIcon.png")
let glyphBounds = letter.outline.union(shades.frame).boundingBoxOfPath
let glyphHeight = 800
writePNG(render(Int((CGFloat(glyphHeight) * glyphBounds.width / glyphBounds.height).rounded()), glyphHeight) { ctx in
    drawMenuGlyph(ctx, size: CGSize(width: CGFloat(ctx.width), height: CGFloat(ctx.height)))
}, to: "Resources/MenuIcon.png")
print("Wrote Resources/AppIcon.png and Resources/MenuIcon.png. Now run ./Resources/make-icon.swift.")
