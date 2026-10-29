import AppKit
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

        /// The letters on a text's label in this color: white, or the menu's dark ink on a light color
        var labelInk: CGColor {
            switch self {
            case .red, .blue, .black: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            case .green, .yellow, .white: CGColor(srgbRed: 0.09, green: 0.12, blue: 0.24, alpha: 1)
            }
        }
    }

    enum Thickness: String, CaseIterable, Sendable {
        case thin, thick

        /// Line width, in points
        var width: CGFloat { self == .thin ? 2 : 5 }
        /// Arrowhead length, in points. A thick head is shorter for its width, so it doesn't swamp the arrow.
        var headLength: CGFloat { self == .thin ? 12 : 20 }
    }

    /// Text sizes to choose from, in points
    static let textSizes: [CGFloat] = [10, 12, 14, 16, 20, 24]
    /// A soft shadow under boxes, lines, arrows and text labels, so they stand out on any snip: how far down it falls
    /// and how far it spreads, in points, and how dark it is
    static let shadowOffset: CGFloat = 1.5
    static let shadowBlur: CGFloat = 4
    static let shadowOpacity: CGFloat = 0.35
    /// How round a box's, highlight's or blur's corners are, in points
    static let cornerRadius: CGFloat = 5
    /// How much of the color a highlight lays down. Multiply, a real marker's look, barely shows on dark-mode
    /// screenshots, so highlights are plain translucent color.
    static let highlightOpacity: CGFloat = 0.4
    /// How far a blur spreads each pixel, in points: far enough that no word under it can be read
    static let blurRadius: CGFloat = 10

    var kind: Kind
    var color: Color
    /// Line width. Highlights and blurs are filled, and text has a size of its own.
    var thickness: Thickness
    /// A text's top left, its label's
    var start: CGPoint
    var end: CGPoint
    var text = ""
    /// In points
    var textSize: CGFloat = 16

    /// A box's, highlight's or blur's rectangle
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Room around a text's letters on its label, in points
    static func labelPadding(_ textSize: CGFloat) -> CGSize {
        CGSize(width: (0.45 * textSize).rounded(), height: (0.2 * textSize).rounded())
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

    /// A tapered arrow's outline: thin at the tail, wider where the shaft meets the head, and the head out to the tip
    /// at the end. A short arrow is all head, smaller. Nil when it has no length.
    /// - Parameters:
    ///   - width: the line width, in pixels
    ///   - full: the head's length, in pixels, when there's room. It's 0.9 times as wide.
    static func arrowOutline(from start: CGPoint, to end: CGPoint, width: CGFloat,
                             headLength full: CGFloat) -> [CGPoint]? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let headLength = min(full, length)
        let headHalf = 0.45 * headLength
        // So far along the arrow, and so far to one side of it
        func point(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: start.x + (dx * along - dy * side) / length, y: start.y + (dy * along + dx * side) / length)
        }
        let base = length - headLength
        let head = [point(base, headHalf), end, point(base, -headHalf)]
        guard base > 0 else { return head }
        let neck = min(0.75 * width, 0.6 * headHalf), tail = 0.25 * width
        return [point(0, tail), point(base, neck)] + head + [point(base, -neck), point(0, -tail)]
    }

    /// Whether a click at that point, in the snip's pixels, lands on the shape: on a box's edges, along a line or an
    /// arrow, or anywhere on a highlight, blur or text label. Slop, in pixels, makes thin lines easier to hit. With
    /// edgesOnly, a highlight or a blur is only hit near its edges too, so a drag inside one can draw on it.
    func isHit(by point: CGPoint, scale: CGFloat, slop: CGFloat, edgesOnly: Bool = false) -> Bool {
        let reach = thickness.width * scale / 2 + slop
        switch kind {
        case .box:
            return Self.distance(from: point, toEdgesOf: rect) <= reach
        case .line:
            return Self.distance(from: point, toLineFrom: start, to: end) <= reach
        case .arrow:
            guard let outline = Self.arrowOutline(from: start, to: end, width: thickness.width * scale,
                                                  headLength: thickness.headLength * scale) else { return false }
            return Self.isInside(point, outline) || outline.indices.contains {
                Self.distance(from: point, toLineFrom: outline[$0], to: outline[($0 + 1) % outline.count]) <= slop
            }
        case .highlight, .blur:
            if edgesOnly { return Self.distance(from: point, toEdgesOf: rect) <= slop }
            return rect.insetBy(dx: -slop, dy: -slop).contains(point)
        case .text:
            return SnipRenderer.labelBounds(self, scale: scale).insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    /// Which shape a click at that point lands on: the one on top, as they're drawn
    static func topmost(at point: CGPoint, in shapes: [Annotation], scale: CGFloat, slop: CGFloat) -> Int? {
        SnipRenderer.drawingOrder(shapes).last { shapes[$0].isHit(by: point, scale: scale, slop: slop) }
    }

    /// What's dragged to resize it: a box's, highlight's or blur's corners, clockwise from the top left, or a line's or
    /// an arrow's ends. Text has none, since its size is the Text Size.
    var handles: [CGPoint] {
        switch kind {
        case .box, .highlight, .blur:
            let rect = rect
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case .line, .arrow:
            return [start, end]
        case .text:
            return []
        }
    }

    /// The handle within reach of that point, the nearest if more are
    func handle(near point: CGPoint, reach: CGFloat) -> Int? {
        let distances = handles.map { hypot($0.x - point.x, $0.y - point.y) }
        return distances.indices.filter { distances[$0] <= reach }.min { distances[$0] < distances[$1] }
    }

    /// With that handle dragged to the point, and the opposite corner or the other end where it was. Shift keeps it
    /// square, or at 45° steps, as when it was drawn.
    func resized(handle index: Int, to point: CGPoint, constrained: Bool) -> Annotation {
        var shape = self
        switch kind {
        case .box, .highlight, .blur:
            let opposite = handles[(index + 2) % 4]
            shape.start = opposite
            shape.end = constrained ? Self.constrained(kind, from: opposite, to: point) : point
        case .line, .arrow:
            let other = index == 0 ? end : start
            let moved = constrained ? Self.constrained(kind, from: other, to: point) : point
            if index == 0 { shape.start = moved } else { shape.end = moved }
        case .text:
            break
        }
        return shape
    }

    func moved(by offset: CGSize) -> Annotation {
        var shape = self
        shape.start = CGPoint(x: start.x + offset.width, y: start.y + offset.height)
        shape.end = CGPoint(x: end.x + offset.width, y: end.y + offset.height)
        return shape
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

    /// Whether a line from the point out to the right crosses the polygon's edges an odd number of times
    private static func isInside(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x) {
                inside.toggle()
            }
        }
        return inside
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
        let color = annotation.color.cgColor
        let width = annotation.thickness.width * scale
        let corners = Annotation.cornerRadius * scale
        context.saveGState()
        defer { context.restoreGState() }
        switch annotation.kind {
        case .blur:
            guard let blurred else { return }
            context.addPath(roundedRect(annotation.rect, radius: corners))
            context.clip()
            // Upright, since y runs down
            context.translateBy(x: 0, y: CGFloat(blurred.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(blurred, in: CGRect(x: 0, y: 0, width: blurred.width, height: blurred.height))
        case .highlight:
            context.setFillColor(color.copy(alpha: Annotation.highlightOpacity) ?? color)
            context.addPath(roundedRect(annotation.rect, radius: corners))
            context.fillPath()
        case .text:
            // Never blank once it's placed
            guard !annotation.text.isEmpty else { return }
            drawLabel(annotation, in: context, scale: scale, letters: true)
        case .box:
            castShadow(in: context, scale: scale)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.addPath(roundedRect(annotation.rect, radius: corners))
            context.strokePath()
        case .line:
            castShadow(in: context, scale: scale)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.strokeLineSegments(between: [annotation.start, annotation.end])
        case .arrow:
            guard let path = arrowPath(annotation, scale: scale) else { return }
            castShadow(in: context, scale: scale)
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        }
    }

    /// A tapered arrow with a round tail and its other corners softened
    private static func arrowPath(_ annotation: Annotation, scale: CGFloat) -> CGPath? {
        let width = annotation.thickness.width * scale
        let (start, end) = (annotation.start, annotation.end)
        guard var outline = Annotation.arrowOutline(from: start, to: end, width: width,
                                                    headLength: annotation.thickness.headLength * scale)
        else { return nil }
        // Less on a small head, and where the head meets a short shaft, so the curves fit
        let length = hypot(end.x - start.x, end.y - start.y)
        let head = min(annotation.thickness.headLength * scale, length)
        let soft = min(0.3 * width, 0.1 * head)
        guard outline.count > 3 else { return roundedPath(outline, radii: outline.map { _ in soft }) }
        let neck = min(soft, length - head)
        // Square corners just behind the tail, each rounded by the tail's half width, into a half circle
        let tail = hypot(outline[0].x - start.x, outline[0].y - start.y)
        let behind = { (point: CGPoint) in
            CGPoint(x: point.x - (end.x - start.x) / length * tail, y: point.y - (end.y - start.y) / length * tail)
        }
        outline = [behind(outline[0])] + outline + [behind(outline[outline.count - 1])]
        return roundedPath(outline, radii: [tail, 0, neck, soft, soft, soft, neck, 0, tail])
    }

    /// A text's label, rounded, in its color on a soft shadow, with the letters on it in white or dark ink. Without
    /// them, it's the label for a text being typed, which the editor's text field draws over.
    static func drawLabel(_ annotation: Annotation, in context: CGContext, scale: CGFloat, letters: Bool = false) {
        let bounds = labelBounds(annotation, scale: scale)
        context.saveGState()
        castShadow(in: context, scale: scale)
        context.setFillColor(annotation.color.cgColor)
        context.addPath(roundedRect(bounds, radius: 0.3 * bounds.height))
        context.fillPath()
        context.restoreGState()
        guard letters else { return }
        let font = textFont(size: annotation.textSize, scale: scale)
        let padding = Annotation.labelPadding(annotation.textSize)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // upright, since y runs down
        context.textPosition = CGPoint(x: bounds.minX + padding.width * scale,
                                       y: bounds.minY + padding.height * scale + CTFontGetAscent(font))
        CTLineDraw(line(annotation.text, font: font, color: annotation.color.labelInk), context)
        context.restoreGState()
    }

    /// A text's label in the snip's pixels, from its top left: its letters, with room around them
    static func labelBounds(_ annotation: Annotation, scale: CGFloat) -> CGRect {
        let font = textFont(size: annotation.textSize, scale: scale)
        let width = CGFloat(CTLineGetTypographicBounds(line(annotation.text, font: font), nil, nil, nil))
        let padding = Annotation.labelPadding(annotation.textSize)
        return CGRect(x: annotation.start.x, y: annotation.start.y, width: width + 2 * padding.width * scale,
                      height: CTFontGetAscent(font) + CTFontGetDescent(font) + 2 * padding.height * scale)
    }

    /// The system font's rounded design in bold, like the menu's, in the snip's pixels
    static func textFont(size: CGFloat, scale: CGFloat) -> CTFont {
        let bold = NSFont.systemFont(ofSize: size * scale, weight: .bold)
        let rounded = bold.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size * scale) }
        return (rounded ?? bold) as CTFont
    }

    private static func line(_ text: String, font: CTFont, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// A soft shadow under what's drawn next, until the state's restored. Shadows ignore the context's transform, so
    /// it's turned into the context's own units, for the shadow to look the same on screen as when it's saved.
    private static func castShadow(in context: CGContext, scale: CGFloat) {
        let transform = context.ctm
        let offset = CGSize(width: 0, height: Annotation.shadowOffset * scale).applying(transform)
        let blur = Annotation.shadowBlur * scale * sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        context.setShadow(offset: offset, blur: blur, color: CGColor(gray: 0, alpha: Annotation.shadowOpacity))
    }

    /// A rectangle with its corners rounded, by less when it's too small for them
    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A closed path through the points, each corner rounded by its own radius
    private static func roundedPath(_ points: [CGPoint], radii: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        let first = points[0], last = points[points.count - 1]
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for index in points.indices {
            if radii[index] > 0 {
                path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count],
                            radius: radii[index])
            } else {
                path.addLine(to: points[index])
            }
        }
        path.closeSubpath()
        return path
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
    static let minimumHeight: CGFloat = 480
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
