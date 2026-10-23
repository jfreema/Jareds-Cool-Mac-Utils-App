#!/usr/bin/env swift
// Draws the two art masters: ./Resources/draw-icon.swift, then ./Resources/make-icon.swift for the art built from them.
// Resources/AppIcon.png: a cool J in sunglasses in the menu's bubble pop style, 1024 pixels on Apple's macOS grid,
// with its shadow.
// Resources/MenuIcon.png: the same J in sunglasses as the menu bar's glyph, black on clear.

import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The menu's colors, from BubbleStyle.swift
enum Bubble {
    static let blue = CGColor(srgbRed: 0.17, green: 0.37, blue: 0.94, alpha: 1)
    static let ink = CGColor(srgbRed: 0.09, green: 0.12, blue: 0.24, alpha: 1)
    static let hover = CGColor(srgbRed: 0.85, green: 0.90, blue: 1.0, alpha: 1)
    static let yellow = CGColor(srgbRed: 0.98, green: 0.85, blue: 0.27, alpha: 1)
    static let green = CGColor(srgbRed: 0.32, green: 0.79, blue: 0.43, alpha: 1)
    static let orange = CGColor(srgbRed: 0.97, green: 0.53, blue: 0.22, alpha: 1)
    static let red = CGColor(srgbRed: 0.91, green: 0.25, blue: 0.25, alpha: 1)
}

func degrees(_ value: CGFloat) -> CGFloat { value * .pi / 180 }

// MARK: Shapes

/// Apple's macOS icon tile: an 824-pixel squircle on the 1024 grid
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile).cgPath
/// The tile's blue face, inside a thick ink rim like the menu's
let rim: CGFloat = 24
let facePath = RoundedRectangle(cornerRadius: 185 - rim, style: .continuous).path(in: tile.insetBy(dx: rim, dy: rim))
    .cgPath

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

    /// A streak of light slanting up across each lens
    var shine: CGPath {
        let path = CGMutablePath()
        for x in [center.x - 140, center.x - 140 + lensWidth + bridge] {
            path.addLines(between: [CGPoint(x: x, y: center.y - 80), CGPoint(x: x + 40, y: center.y - 80),
                                    CGPoint(x: x + 150, y: center.y + 80), CGPoint(x: x + 110, y: center.y + 80)])
            path.closeSubpath()
        }
        return path
    }

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

/// A chubby four-pointed sparkle, its sides curving in toward the middle
func sparkle(at center: CGPoint, radius: CGFloat) -> CGPath {
    let tips = [CGPoint(x: center.x, y: center.y + radius), CGPoint(x: center.x + radius, y: center.y),
                CGPoint(x: center.x, y: center.y - radius), CGPoint(x: center.x - radius, y: center.y)]
    let path = CGMutablePath()
    path.move(to: tips[0])
    for index in 1...4 {
        let from = tips[index - 1], to = tips[index % 4]
        let control = CGPoint(x: center.x + (from.x + to.x - 2 * center.x) * 0.22,
                              y: center.y + (from.y + to.y - 2 * center.y) * 0.22)
        path.addQuadCurve(to: to, control: control)
    }
    path.closeSubpath()
    return path
}

// MARK: Painting

func dot(_ center: CGPoint, radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
           transform: nil)
}

func moved(_ path: CGPath, _ x: CGFloat, _ y: CGFloat) -> CGPath {
    var shift = CGAffineTransform(translationX: x, y: y)
    return path.copy(using: &shift)!
}

func fill(_ ctx: CGContext, _ path: CGPath, _ fill: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
}

/// A shape the bubble pop way, like the menu's cards: an ink outline around it, on a hard ink shadow down and to the
/// right. Returns the shape with its outline.
@discardableResult
func sticker(_ ctx: CGContext, _ shape: CGPath, _ face: CGColor, outline: CGFloat, lift: CGFloat) -> CGPath {
    let ring = shape.copy(strokingWithWidth: outline * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let body = shape.union(ring)
    fill(ctx, moved(body, lift * 0.6, -lift), Bubble.ink)
    fill(ctx, body, Bubble.ink)
    fill(ctx, shape, face)
    return body
}

let letter = Letter(stemX: 668, top: 732, bend: 482, radius: 165, weight: 182)
let shades = Shades(center: CGPoint(x: 648, y: 648), width: 376, height: 116)
let mouthCenter = CGPoint(x: 662, y: 538)
let mouth = smile(center: mouthCenter, width: 92, height: 54)

func drawIcon(_ ctx: CGContext) {
    // The tile, lifted off the desktop, in the menu's blue inside its ink rim
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.42))
    fill(ctx, tilePath, Bubble.ink)
    ctx.restoreGState()
    fill(ctx, facePath, Bubble.blue)

    ctx.saveGState()
    ctx.addPath(facePath)
    ctx.clip()
    // Confetti in the tools' colors
    sticker(ctx, sparkle(at: CGPoint(x: 280, y: 770), radius: 66), color(0xFFFFFF), outline: 12, lift: 12)
    sticker(ctx, dot(CGPoint(x: 404, y: 846), radius: 22), Bubble.orange, outline: 12, lift: 12)
    sticker(ctx, dot(CGPoint(x: 200, y: 640), radius: 20), Bubble.green, outline: 12, lift: 12)

    // The J as a white sticker, shaded along its lower right
    let body = letter.outline
    sticker(ctx, body, color(0xFFFFFF), outline: 18, lift: 34)
    let shading: CGFloat = 28
    fill(ctx, body.subtracting(moved(body, -shading * 0.6, shading)), Bubble.hover)

    // The shades, with a hard shadow on the face
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    fill(ctx, moved(shades.frame, 8, -14), Bubble.ink.copy(alpha: 0.22)!)
    ctx.restoreGState()
    fill(ctx, shades.frame, Bubble.ink)
    ctx.saveGState()
    ctx.addPath(shades.lenses)
    ctx.clip()
    fill(ctx, shades.shine, color(0xFFFFFF, 0.9))
    ctx.restoreGState()

    // A grin
    fill(ctx, mouth, Bubble.ink)
    ctx.saveGState()
    ctx.addPath(mouth)
    ctx.clip()
    ctx.addEllipse(in: CGRect(x: mouthCenter.x - 30, y: mouthCenter.y - 44, width: 60, height: 38))
    ctx.setFillColor(Bubble.red)
    ctx.fillPath()
    ctx.restoreGState()

    // A glint off the shades
    sticker(ctx, sparkle(at: CGPoint(x: 806, y: 730), radius: 50), Bubble.yellow, outline: 12, lift: 12)
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
