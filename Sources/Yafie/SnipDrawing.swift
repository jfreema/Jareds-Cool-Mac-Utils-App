import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A snip as taken: its pixels, and their scale, 2 from a Retina display
struct Snip {
    let image: CGImage
    let scale: CGFloat
    let taken: Date

    init(image: CGImage, scale: CGFloat, taken: Date = Date()) {
        self.image = image
        self.scale = scale
        self.taken = taken
    }

    /// From a PNG, taking the scale from the dpi screencapture recorded (144 on a Retina display)
    init?(data: Data, taken: Date = Date()) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 72
        self.init(image: image, scale: max(1, (dpi / 72).rounded()), taken: taken)
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    /// As it was on screen, in points
    var size: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// "Snip 2026-10-04 at 14.32.05", like macOS's own screenshot names, in 24-hour time
    var name: String { Self.name(for: taken) }

    static func name(for date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'Snip' yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// One shape on a snip, in the snip's pixels: origin at the top left, y down
struct Annotation: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case box, line, arrow, highlight, blur, text }

    enum Color: String, CaseIterable, Sendable {
        case red, green, blue, yellow, black, white

        /// Fixed sRGB values, so the saved file matches the editor in light and dark mode
        var cgColor: CGColor {
            switch self {
            case .red: CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
            case .green: CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
            case .blue: CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
            case .yellow: CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
            case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            }
        }
    }

    /// Around a box, line, arrow or text, so it stands out on dark snips and light ones. Highlights and blurs have
    /// none.
    enum Outline: String, CaseIterable, Sendable {
        case none, white, red, black

        var cgColor: CGColor? {
            switch self {
            case .none: nil
            case .white: CGColor(gray: 1, alpha: 1)
            case .red: Color.red.cgColor
            case .black: CGColor(gray: 0, alpha: 1)
            }
        }
    }

    enum Thickness: String, CaseIterable, Sendable {
        case thin, thick

        /// Line width, in points
        var width: CGFloat { self == .thin ? 2 : 5 }
        /// Arrowhead length, in points. A thick head is shorter for its width, so it doesn't swamp the arrow.
        var headLength: CGFloat { self == .thin ? 10 : 18 }
    }

    /// Text sizes to choose from, in points
    static let textSizes: [CGFloat] = [10, 12, 14, 16, 20, 24]
    /// How far an outline shows past a box's, line's or arrow's edge, in points
    static let outlineWidth: CGFloat = 1.5
    /// The outline drawn along text's edges, in points. Half of it shows, the rest is under the letters: enough to set
    /// them off without filling in their holes.
    static let textOutlineWidth: CGFloat = 1.5

    struct Head: Equatable {
        var tip: CGPoint
        var left: CGPoint
        var right: CGPoint
        /// Where the shaft stops, inside the head so the tip stays sharp. Nil when the head is the whole arrow.
        var shaftEnd: CGPoint?
    }

    /// How much of the color a highlight lays down. Multiply, a real marker's look, barely shows on dark-mode
    /// screenshots, so highlights are plain translucent color.
    static let highlightOpacity: CGFloat = 0.4
    /// How far a blur spreads each pixel, in points: far enough that no word under it can be read
    static let blurRadius: CGFloat = 10

    var kind: Kind
    var color: Color
    /// Line width. Highlights and blurs are filled, and text has a size of its own.
    var thickness: Thickness
    /// A text's top left
    var start: CGPoint
    var end: CGPoint
    var text = ""
    /// In points
    var textSize: CGFloat = 16
    var outline = Outline.none

    /// A box's, highlight's or blur's rectangle
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Shift: lines and arrows at multiples of 45°, boxes, highlights and blurs square
    static func constrained(_ kind: Kind, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch kind {
        case .box, .highlight, .blur:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .text:
            return end
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            // Projected onto that direction, so a nearly level drag keeps its length
            let length = dx * cos(angle) + dy * sin(angle)
            return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
        }
    }

    /// A triangle 0.9 times as wide as it's long, shrunk to fit a shorter arrow
    static func head(from start: CGPoint, to end: CGPoint, length full: CGFloat) -> Head? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let headLength = min(full, length)
        let halfWidth = 0.45 * headLength
        let (ux, uy) = (dx / length, dy / length)
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let middle = CGPoint(x: end.x - ux * headLength / 2, y: end.y - uy * headLength / 2)
        return Head(tip: end,
                    left: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth),
                    right: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth),
                    shaftEnd: length > headLength ? middle : nil)
    }

    /// Whether a click at that point, in the snip's pixels, lands on the shape: on a box's edges, along a line or an
    /// arrow, or anywhere on a highlight, blur or text. Slop, in pixels, makes thin lines easier to hit.
    func isHit(by point: CGPoint, scale: CGFloat, slop: CGFloat) -> Bool {
        let edge = outline == .none ? 0 : Self.outlineWidth * scale
        let reach = thickness.width * scale / 2 + edge + slop
        switch kind {
        case .box:
            return Self.distance(from: point, toEdgesOf: rect) <= reach
        case .line:
            return Self.distance(from: point, toLineFrom: start, to: end) <= reach
        case .arrow:
            if Self.distance(from: point, toLineFrom: start, to: end) <= reach { return true }
            guard let head = Self.head(from: start, to: end, length: thickness.headLength * scale) else { return false }
            let corners = [head.tip, head.left, head.right]
            return Self.isInside(point, corners) || corners.indices.contains {
                Self.distance(from: point, toLineFrom: corners[$0], to: corners[($0 + 1) % 3]) <= edge + slop
            }
        case .highlight, .blur:
            return rect.insetBy(dx: -slop, dy: -slop).contains(point)
        case .text:
            return SnipRenderer.textBounds(self, scale: scale).insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    /// Which shape a click at that point lands on: the one on top, as they're drawn
    static func topmost(at point: CGPoint, in shapes: [Annotation], scale: CGFloat, slop: CGFloat) -> Int? {
        SnipRenderer.drawingOrder(shapes).last { shapes[$0].isHit(by: point, scale: scale, slop: slop) }
    }

    /// To the nearest edge, from inside the rectangle or out
    private static func distance(from point: CGPoint, toEdgesOf rect: CGRect) -> CGFloat {
        if rect.contains(point) {
            return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
        }
        return hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    private static func distance(from point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let squared = dx * dx + dy * dy
        // How far along the line the nearest point is, from 0 at the start to 1 at the end
        let along = squared > 0 ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squared, 0), 1) : 0
        return hypot(point.x - (start.x + along * dx), point.y - (start.y + along * dy))
    }

    private static func isInside(_ point: CGPoint, _ triangle: [CGPoint]) -> Bool {
        let sides = triangle.indices.map { index in
            let (a, b) = (triangle[index], triangle[(index + 1) % 3])
            return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
        }
        return sides.allSatisfy { $0 >= 0 } || sides.allSatisfy { $0 <= 0 }
    }
}

enum SnipRenderer {
    /// How much of a shape shows while the eraser points at it
    static let fadedOpacity: CGFloat = 0.3

    /// Draws the shapes into a context whose units are the snip's pixels, origin at the top left. The editor's canvas
    /// and the export both use this, so what's saved is what was on screen.
    /// - Parameters:
    ///   - scale: the snip's pixels per point, 2 from a Retina display
    ///   - blurred: the snip blurred all over, from blur(_:scale:), which shows through blurs
    ///   - faded: the shape the eraser points at, drawn faint
    static func draw(_ annotations: [Annotation], in context: CGContext, scale: CGFloat, blurred: CGImage? = nil,
                     faded: Int? = nil) {
        for index in drawingOrder(annotations) {
            if index == faded {
                context.saveGState()
                context.setAlpha(fadedOpacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            draw(annotations[index], in: context, scale: scale, blurred: blurred)
            if index == faded {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
    }

    /// Blurs first, then highlights, so they change the snip but never the other shapes. Then the rest in order.
    static func drawingOrder(_ annotations: [Annotation]) -> [Int] {
        let layer: (Annotation.Kind) -> Int = { $0 == .blur ? 0 : $0 == .highlight ? 1 : 2 }
        return (0...2).flatMap { level in annotations.indices.filter { layer(annotations[$0].kind) == level } }
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, scale: CGFloat, blurred: CGImage?) {
        switch annotation.kind {
        case .blur:
            guard let blurred else { return }
            context.saveGState()
            context.clip(to: annotation.rect)
            // Upright, since y runs down
            context.translateBy(x: 0, y: CGFloat(blurred.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(blurred, in: CGRect(x: 0, y: 0, width: blurred.width, height: blurred.height))
            context.restoreGState()
        case .highlight:
            let color = annotation.color.cgColor
            context.setFillColor(color.copy(alpha: Annotation.highlightOpacity) ?? color)
            context.fill(annotation.rect)
        case .text:
            drawText(annotation, in: context, scale: scale)
        case .box, .line, .arrow:
            // With its outline right under it, so a later shape's outline sets it off from earlier ones
            if let outline = annotation.outline.cgColor {
                drawShape(annotation, color: outline, widenedBy: Annotation.outlineWidth * scale, in: context,
                          scale: scale)
            }
            drawShape(annotation, color: annotation.color.cgColor, widenedBy: 0, in: context, scale: scale)
        }
    }

    /// A box, line or arrow in one color. Widened on every side, it's the outline that goes under it.
    private static func drawShape(_ annotation: Annotation, color: CGColor, widenedBy extra: CGFloat,
                                  in context: CGContext, scale: CGFloat) {
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(annotation.thickness.width * scale + 2 * extra)
        context.setLineCap(.round)
        context.setLineJoin(.miter)
        let (start, end) = (annotation.start, annotation.end)
        switch annotation.kind {
        case .box:
            context.stroke(annotation.rect)
        case .line:
            context.strokeLineSegments(between: [start, end])
        case .arrow:
            guard let head = Annotation.head(from: start, to: end, length: annotation.thickness.headLength * scale)
            else { return }
            if let shaftEnd = head.shaftEnd { context.strokeLineSegments(between: [start, shaftEnd]) }
            context.addLines(between: [head.tip, head.left, head.right])
            context.closePath()
            if extra > 0 {
                context.setLineWidth(2 * extra)
                context.drawPath(using: .fillStroke)
            } else {
                context.fillPath()
            }
        case .text, .highlight, .blur:
            break
        }
    }

    /// Bold, in the color, with its outline behind it, its top left at the start point
    private static func drawText(_ annotation: Annotation, in context: CGContext, scale: CGFloat) {
        let font = textFont(size: annotation.textSize, scale: scale)
        func line(_ attributes: [CFString: Any]) -> CTLine {
            var all = attributes
            all[kCTFontAttributeName] = font
            let keyed = Dictionary(uniqueKeysWithValues: all.map { (NSAttributedString.Key($0.key as String), $0.value) })
            return CTLineCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: keyed))
        }
        var lines = [line([kCTForegroundColorAttributeName: annotation.color.cgColor])]
        if let outline = annotation.outline.cgColor {
            // As a percentage of the size, centered on the letters' edges
            let width = Annotation.textOutlineWidth / annotation.textSize * 100
            lines.insert(line([kCTStrokeWidthAttributeName: width, kCTStrokeColorAttributeName: outline]), at: 0)
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // upright, since y runs down
        context.setLineJoin(.round)
        let baseline = CGPoint(x: annotation.start.x, y: annotation.start.y + CTFontGetAscent(font))
        for line in lines {
            context.textPosition = baseline
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    /// The system font in bold, in the snip's pixels
    static func textFont(size: CGFloat, scale: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size * scale, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size * scale, nil)
    }

    /// Where a text's letters go, in the snip's pixels: from its top left, as wide as its line and as tall as its font
    static func textBounds(_ annotation: Annotation, scale: CGFloat) -> CGRect {
        let font = textFont(size: annotation.textSize, scale: scale)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGRect(x: annotation.start.x, y: annotation.start.y, width: CGFloat(width),
                      height: CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    /// The snip blurred all over, which blurs show through, so overlapping ones match. Its edges blur with copies of
    /// themselves, so they don't fade.
    static func blur(_ snip: CGImage, scale: CGFloat) -> CGImage? {
        let image = CIImage(cgImage: snip)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: Annotation.blurRadius * scale,
        ]), let blurred = filter.outputImage else { return nil }
        return CIContext().createCGImage(blurred, from: image.extent, format: .RGBA8, colorSpace: colorSpace(of: snip))
    }

    /// The snip with its shapes at full resolution, in the snip's own color space so nothing shifts
    /// - Parameter blurred: the snip blurred all over, if it's been blurred already
    static func render(_ snip: CGImage, _ annotations: [Annotation], scale: CGFloat,
                       blurred: CGImage? = nil) -> CGImage? {
        guard let context = CGContext(data: nil, width: snip.width, height: snip.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace(of: snip),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let height = CGFloat(snip.height)
        context.draw(snip, in: CGRect(x: 0, y: 0, width: CGFloat(snip.width), height: height))
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        let blurs = annotations.contains { $0.kind == .blur }
        draw(annotations, in: context, scale: scale, blurred: blurred ?? (blurs ? blur(snip, scale: scale) : nil))
        return context.makeImage()
    }

    /// The snip's own, or sRGB for a snip that isn't in color
    private static func colorSpace(of snip: CGImage) -> CGColorSpace {
        snip.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// A PNG, or a TIFF for the clipboard, that keeps the dpi, so apps that read it show the snip at its on-screen size
    static func data(_ image: CGImage, scale: CGFloat, type: UTType = .png) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if type == .tiff { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }  // LZW
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Where the editor shows a snip: at actual size, or smaller to fit, centered. In the canvas's points, origin at the
/// top left.
struct SnipFit: Equatable {
    let frame: CGRect
    /// Snip pixels per canvas point
    let pixelsPerPoint: CGFloat

    init(_ pixels: CGSize, scale: CGFloat, in canvas: CGSize) {
        let natural = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let fit = canvas.width > 0 && canvas.height > 0
            ? min(1, canvas.width / natural.width, canvas.height / natural.height) : 1
        let size = CGSize(width: natural.width * fit, height: natural.height * fit)
        frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(.down),
                       y: ((canvas.height - size.height) / 2).rounded(.down), width: size.width, height: size.height)
        pixelsPerPoint = scale / fit
    }

    /// A point on the canvas in snip pixels, kept on the snip
    func pixel(for point: CGPoint) -> CGPoint {
        let x = min(max(point.x, frame.minX), frame.maxX), y = min(max(point.y, frame.minY), frame.maxY)
        return CGPoint(x: (x - frame.minX) * pixelsPerPoint, y: (y - frame.minY) * pixelsPerPoint)
    }

    func point(for pixel: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + pixel.x / pixelsPerPoint, y: frame.minY + pixel.y / pixelsPerPoint)
    }
}

/// The editor window's measurements under its title bar, in points: the sidebar, then the snip, with blue around both
enum SnipEditorLayout {
    /// Blue around the sidebar and the snip, with room for their outlines and shadows
    static let margin: CGFloat = 14
    /// Under the title bar, which is blue too
    static let topMargin: CGFloat = 4
    static let sidebarWidth: CGFloat = 148
    /// Room for all of the sidebar
    static let minimumHeight: CGFloat = 570
    static let minimumCanvasWidth: CGFloat = 200

    /// Beside and above and below the snip at actual size
    static let chrome = CGSize(width: 3 * margin + sidebarWidth, height: topMargin + margin)
    static let minimumWidth = chrome.width + minimumCanvasWidth

    /// The window's content size for a snip: actual size beside the sidebar, shrunk to fit 90% of the display's
    /// visible area, and never shorter than the sidebar
    static func contentSize(for snip: CGSize, on visible: CGRect) -> CGSize {
        let room = CGSize(width: visible.width * 0.9 - chrome.width, height: visible.height * 0.9 - chrome.height)
        let fit = min(1, room.width / snip.width, room.height / snip.height)
        return CGSize(width: chrome.width + max((snip.width * fit).rounded(), minimumCanvasWidth),
                      height: max(chrome.height + (snip.height * fit).rounded(), minimumHeight))
    }
}
