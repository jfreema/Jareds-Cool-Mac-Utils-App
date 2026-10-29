import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Yafie

struct AnnotationTests {
    @Test func shiftLevelsANearlyLevelLineAndKeepsItsLength() {
        let end = Annotation.constrained(.line, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 14))
        #expect(abs(end.x - 110) < 1e-9)
        #expect(abs(end.y - 10) < 1e-9)
    }

    @Test func shiftSnaps30DegreesTo45() {
        let thirty = CGFloat.pi / 6
        let end = Annotation.constrained(.arrow, from: .zero, to: CGPoint(x: 100 * cos(thirty), y: 100 * sin(thirty)))
        #expect(end.x > 0)
        #expect(abs(end.x - end.y) < 1e-9)
    }

    @Test(arguments: zip([1.0, -1, 1, -1], [1.0, 1, -1, -1]))
    func shiftMakesBoxesHighlightsAndBlursSquare(signX: CGFloat, signY: CGFloat) {
        for kind in [Annotation.Kind.box, .highlight, .blur] {
            let end = Annotation.constrained(kind, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50 + 30 * signX, y: 50 + 80 * signY))
            #expect(end == CGPoint(x: 50 + 80 * signX, y: 50 + 80 * signY))
        }
    }

    @Test func anArrowsTipIsItsEndAndItsHeadIsSquareToIt() throws {
        let outline = try #require(Annotation.arrowOutline(from: .zero, to: CGPoint(x: 300, y: 400), width: 10,
                                                           headLength: 20))
        #expect(outline.count == 7 && outline[3] == CGPoint(x: 300, y: 400))
        let (left, right) = (outline[2], outline[4])
        let base = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        #expect(abs(hypot(300 - base.x, 400 - base.y) - 20) < 1e-9)
        // The arrow runs along (0.6, 0.8)
        #expect(abs((left.x - right.x) * 0.6 + (left.y - right.y) * 0.8) < 1e-9)
        #expect(abs(hypot(left.x - right.x, left.y - right.y) - 0.9 * 20) < 1e-9)
    }

    @Test func anArrowWidensFromItsTailToItsHead() throws {
        let outline = try #require(Annotation.arrowOutline(from: .zero, to: CGPoint(x: 200, y: 0), width: 10,
                                                           headLength: 40))
        let across = { (a: CGPoint, b: CGPoint) in hypot(a.x - b.x, a.y - b.y) }
        let tail = across(outline[0], outline[6]), neck = across(outline[1], outline[5])
        let head = across(outline[2], outline[4])
        #expect(tail == 5 && neck == 15 && head == 36)
        #expect(outline[0].x == 0 && outline[1].x == 160)
    }

    @Test func thickArrowheadsAreShorterForTheirWidth() {
        #expect(Annotation.Thickness.thin.headLength == 12)
        #expect(Annotation.Thickness.thin.headLength == 6 * Annotation.Thickness.thin.width)
        #expect(Annotation.Thickness.thick.headLength == 20)
        #expect(Annotation.Thickness.thick.headLength < 6 * Annotation.Thickness.thick.width)
    }

    @Test func aShortArrowIsAllHeadAndSmaller() throws {
        let outline = try #require(Annotation.arrowOutline(from: .zero, to: CGPoint(x: 8, y: 0), width: 4,
                                                           headLength: 20))
        #expect(outline.count == 3)
        #expect(outline[0].x == 0 && outline[2].x == 0)
    }

    @Test func aZeroLengthArrowDrawsNothing() {
        #expect(Annotation.arrowOutline(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), width: 4,
                                        headLength: 20) == nil)
    }

    @Test func aClickNearALineHitsIt() {
        let line = Annotation(kind: .line, color: .red, thickness: .thin, start: .zero, end: CGPoint(x: 100, y: 0))
        // A 2-point line is 4 pixels wide at 2 pixels a point, so it reaches 2 pixels each way, and the slop 4 more
        #expect(line.isHit(by: CGPoint(x: 50, y: 6), scale: 2, slop: 4))
        #expect(!line.isHit(by: CGPoint(x: 50, y: 7), scale: 2, slop: 4))
        #expect(!line.isHit(by: CGPoint(x: 107, y: 0), scale: 2, slop: 4))
    }

    @Test func anArrowIsHitOnItsHeadAndItsTaperedShaft() {
        let arrow = Annotation(kind: .arrow, color: .red, thickness: .thick, start: .zero, end: CGPoint(x: 200, y: 0))
        // At 2 pixels a point, its head is 40 pixels long and 36 across where it starts, at 160. Its shaft is 5 pixels
        // across at the tail and 15 at the head.
        #expect(arrow.isHit(by: CGPoint(x: 170, y: 12), scale: 2, slop: 0))
        #expect(!arrow.isHit(by: CGPoint(x: 170, y: 15), scale: 2, slop: 0))
        #expect(!arrow.isHit(by: CGPoint(x: 100, y: 12), scale: 2, slop: 0))
        #expect(arrow.isHit(by: CGPoint(x: 150, y: 4), scale: 2, slop: 0))
        #expect(!arrow.isHit(by: CGPoint(x: 10, y: 4), scale: 2, slop: 0))
        #expect(arrow.isHit(by: CGPoint(x: 10, y: 4), scale: 2, slop: 2))
    }

    @Test func boxesAreHitOnTheirEdgesAndHighlightsAndBlursAnywhere() {
        let box = Annotation(kind: .box, color: .red, thickness: .thin, start: CGPoint(x: 100, y: 100),
                             end: CGPoint(x: 200, y: 200))
        #expect(box.isHit(by: CGPoint(x: 104, y: 150), scale: 2, slop: 2))
        #expect(box.isHit(by: CGPoint(x: 96, y: 150), scale: 2, slop: 2))
        #expect(!box.isHit(by: CGPoint(x: 150, y: 150), scale: 2, slop: 2))
        for kind in [Annotation.Kind.highlight, .blur] {
            var filled = box
            filled.kind = kind
            #expect(filled.isHit(by: CGPoint(x: 150, y: 150), scale: 2, slop: 2))
            #expect(filled.isHit(by: CGPoint(x: 201, y: 150), scale: 2, slop: 2))
            #expect(!filled.isHit(by: CGPoint(x: 210, y: 150), scale: 2, slop: 2))
        }
    }

    @Test func highlightsAndBlursCanBeHitOnlyOnTheirEdges() {
        for kind in [Annotation.Kind.highlight, .blur] {
            let shape = Annotation(kind: kind, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                                   end: CGPoint(x: 300, y: 250))
            #expect(shape.isHit(by: CGPoint(x: 200, y: 150), scale: 2, slop: 4))
            #expect(!shape.isHit(by: CGPoint(x: 200, y: 150), scale: 2, slop: 4, edgesOnly: true))
            #expect(shape.isHit(by: CGPoint(x: 297, y: 150), scale: 2, slop: 4, edgesOnly: true))
            #expect(shape.isHit(by: CGPoint(x: 200, y: 47), scale: 2, slop: 4, edgesOnly: true))
            #expect(!shape.isHit(by: CGPoint(x: 200, y: 45), scale: 2, slop: 4, edgesOnly: true))
        }
    }

    @Test func textIsHitAnywhereOnItsLabel() {
        let text = Annotation(kind: .text, color: .red, thickness: .thin, start: CGPoint(x: 100, y: 60),
                              end: CGPoint(x: 100, y: 60), text: "Look here", textSize: 16)
        let bounds = SnipRenderer.labelBounds(text, scale: 2)
        // With 7 points of room either side of the letters, and 3 above and below, at 2 pixels a point
        #expect(Annotation.labelPadding(16) == CGSize(width: 7, height: 3))
        #expect(bounds.minX == 100 && bounds.minY == 60 && bounds.width > 128 && bounds.height > 42)
        #expect(text.isHit(by: CGPoint(x: 102, y: 62), scale: 2, slop: 0))
        #expect(text.isHit(by: CGPoint(x: bounds.midX, y: bounds.midY), scale: 2, slop: 0))
        #expect(!text.isHit(by: CGPoint(x: bounds.maxX + 5, y: bounds.midY), scale: 2, slop: 0))
    }

    @Test func theShapeOnTopIsTheOneDrawnLast() {
        let line = Annotation(kind: .line, color: .red, thickness: .thin, start: CGPoint(x: 0, y: 50),
                              end: CGPoint(x: 100, y: 50))
        let highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: .zero,
                                   end: CGPoint(x: 100, y: 100))
        let box = Annotation(kind: .box, color: .blue, thickness: .thin, start: CGPoint(x: 50, y: 0),
                             end: CGPoint(x: 150, y: 100))
        // The highlight came after the line, but highlights go under everything else
        #expect(Annotation.topmost(at: CGPoint(x: 20, y: 50), in: [line, highlight, box], scale: 2, slop: 0) == 0)
        #expect(Annotation.topmost(at: CGPoint(x: 20, y: 80), in: [line, highlight, box], scale: 2, slop: 0) == 1)
        #expect(Annotation.topmost(at: CGPoint(x: 50, y: 50), in: [line, highlight, box], scale: 2, slop: 0) == 2)
        #expect(Annotation.topmost(at: CGPoint(x: 200, y: 80), in: [line, highlight, box], scale: 2, slop: 0) == nil)
    }

    @Test func handlesAreTheCornersOrTheEnds() {
        let box = Annotation(kind: .box, color: .red, thickness: .thin, start: CGPoint(x: 300, y: 250),
                             end: CGPoint(x: 100, y: 50))
        #expect(box.handles == [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 50), CGPoint(x: 300, y: 250),
                                CGPoint(x: 100, y: 250)])
        var line = box
        line.kind = .line
        #expect(line.handles == [CGPoint(x: 300, y: 250), CGPoint(x: 100, y: 50)])
        var text = box
        text.kind = .text
        #expect(text.handles.isEmpty)
        #expect(box.handle(near: CGPoint(x: 296, y: 246), reach: 8) == 2)
        #expect(box.handle(near: CGPoint(x: 290, y: 240), reach: 8) == nil)
    }

    @Test func resizingKeepsTheOppositeCorner() {
        let box = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        #expect(box.resized(handle: 2, to: CGPoint(x: 350, y: 280), constrained: false).rect
                == CGRect(x: 100, y: 50, width: 250, height: 230))
        // Past the opposite corner, it turns over
        #expect(box.resized(handle: 0, to: CGPoint(x: 320, y: 270), constrained: false).rect
                == CGRect(x: 300, y: 250, width: 20, height: 20))
        // Shift keeps it square
        #expect(box.resized(handle: 2, to: CGPoint(x: 360, y: 270), constrained: true).rect
                == CGRect(x: 100, y: 50, width: 260, height: 260))
    }

    @Test func resizingALineMovesOneEnd() {
        let line = Annotation(kind: .arrow, color: .red, thickness: .thin, start: CGPoint(x: 20, y: 280),
                              end: CGPoint(x: 380, y: 280))
        let longer = line.resized(handle: 1, to: CGPoint(x: 300, y: 200), constrained: false)
        #expect(longer.start == CGPoint(x: 20, y: 280) && longer.end == CGPoint(x: 300, y: 200))
        // Shift keeps it level, from the end that stays
        let level = line.resized(handle: 0, to: CGPoint(x: 60, y: 284), constrained: true)
        #expect(abs(level.start.y - 280) < 1e-9 && level.end == CGPoint(x: 380, y: 280))
    }

    @Test func movingMovesBothEnds() {
        let arrow = Annotation(kind: .arrow, color: .red, thickness: .thin, start: CGPoint(x: 20, y: 30),
                               end: CGPoint(x: 120, y: 80))
        let moved = arrow.moved(by: CGSize(width: 15, height: -10))
        #expect(moved.start == CGPoint(x: 35, y: 20) && moved.end == CGPoint(x: 135, y: 70))
    }
}

struct SnipRendererTests {
    @Test func drawsTheBoxWhereItIsAndLeavesTheRestAlone() {
        let snip = SnipImages.plain()
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        let image = SnipRenderer.render(snip, [box], scale: 2)!
        #expect(image.width == 400 && image.height == 300)
        #expect(SnipImages.isRed(SnipImages.pixel(image, 100, 150)))
        #expect(SnipImages.isRed(SnipImages.pixel(image, 200, 50)))
        #expect(SnipImages.pixel(image, 200, 150) == SnipImages.pixel(snip, 200, 150))
        #expect(SnipImages.pixel(image, 20, 20) == SnipImages.pixel(snip, 20, 20))
    }

    @Test func aHighlightTintsWithoutCovering() {
        let snip = SnipImages.plain()
        let highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                                   end: CGPoint(x: 300, y: 250))
        let image = SnipRenderer.render(snip, [highlight], scale: 2)!
        // 40% of the way from the gray to yellow, so the gray still shows through
        let inside = SnipImages.pixel(image, 200, 150), gray = SnipImages.pixel(snip, 200, 150)
        #expect(abs(inside[0] - (0.4 * 1 + 0.6 * gray[0])) < 0.03)
        #expect(abs(inside[1] - (0.4 * 0.8 + 0.6 * gray[1])) < 0.03)
        #expect(inside[2] < gray[2])
        #expect(SnipImages.pixel(image, 20, 20) == SnipImages.pixel(snip, 20, 20))
    }

    @Test func highlightsGoUnderTheOtherShapes() {
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        let highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 50, y: 100),
                                   end: CGPoint(x: 350, y: 200))
        let image = SnipRenderer.render(SnipImages.plain(), [box, highlight], scale: 2)!
        #expect(SnipImages.isRed(SnipImages.pixel(image, 100, 150)))
    }

    @Test func thicknessDoesntChangeAHighlight() {
        let thin = Annotation(kind: .highlight, color: .green, thickness: .thin, start: CGPoint(x: 100, y: 50),
                              end: CGPoint(x: 300, y: 250))
        var thick = thin
        thick.thickness = .thick
        let a = SnipRenderer.render(SnipImages.plain(), [thin], scale: 2)!
        let b = SnipRenderer.render(SnipImages.plain(), [thick], scale: 2)!
        for (x, y) in [(99, 150), (100, 150), (200, 150), (300, 150), (301, 150)] {
            #expect(SnipImages.pixel(a, x, y) == SnipImages.pixel(b, x, y))
        }
    }

    @Test func linesCastASoftShadowDownward() {
        let snip = SnipImages.plain()
        // 10 pixels thick, from 145 to 155
        let line = Annotation(kind: .line, color: .red, thickness: .thick, start: CGPoint(x: 50, y: 150),
                              end: CGPoint(x: 350, y: 150))
        let image = SnipRenderer.render(snip, [line], scale: 2)!
        let gray = SnipImages.pixel(snip, 200, 159)[0]
        let below = SnipImages.pixel(image, 200, 159)[0], above = SnipImages.pixel(image, 200, 141)[0]
        #expect(below < gray - 0.04 && below < above - 0.03)
        #expect(SnipImages.isRed(SnipImages.pixel(image, 200, 150)))
        #expect(SnipImages.pixel(image, 200, 190) == SnipImages.pixel(snip, 200, 190))
    }

    @Test func highlightsCastNoShadow() {
        let snip = SnipImages.plain()
        let highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                                   end: CGPoint(x: 300, y: 250))
        let image = SnipRenderer.render(snip, [highlight], scale: 2)!
        for (x, y) in [(96, 150), (200, 253), (304, 150)] {
            #expect(SnipImages.pixel(image, x, y) == SnipImages.pixel(snip, x, y))
        }
    }

    @Test func boxesHighlightsAndBlursHaveRoundCorners() {
        let snip = SnipImages.plain()
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        let boxed = SnipRenderer.render(snip, [box], scale: 2)!
        // A square corner's outside, which a 10-pixel round corner leaves out
        #expect(!SnipImages.isRed(SnipImages.pixel(boxed, 96, 46)))
        #expect(SnipImages.isRed(SnipImages.pixel(boxed, 96, 150)))
        #expect(SnipImages.isRed(SnipImages.pixel(boxed, 200, 46)))
        // Near the sharp edge down the middle, where a blur would show
        let halves = SnipImages.halves()
        for kind in [Annotation.Kind.highlight, .blur] {
            let filled = Annotation(kind: kind, color: .yellow, thickness: .thin, start: CGPoint(x: 190, y: 50),
                                    end: CGPoint(x: 300, y: 250))
            let image = SnipRenderer.render(halves, [filled], scale: 2)!
            #expect(SnipImages.pixel(image, 191, 51) == SnipImages.pixel(halves, 191, 51))
            #expect(SnipImages.pixel(image, 195, 150) != SnipImages.pixel(halves, 195, 150))
        }
    }

    @Test func aSeeThroughShapeFadesWithItsShadow() {
        let snip = SnipImages.plain()
        var line = Annotation(kind: .line, color: .red, thickness: .thick, start: CGPoint(x: 50, y: 150),
                              end: CGPoint(x: 350, y: 150))
        let solid = SnipRenderer.render(snip, [line], scale: 2)!
        line.opacity = 0.5
        let half = SnipRenderer.render(snip, [line], scale: 2)!
        // Half way between the red and the snip, with no shadow showing through it
        let gray = SnipImages.pixel(snip, 200, 150), red = SnipImages.pixel(solid, 200, 150)
        let mixed = SnipImages.pixel(half, 200, 150)
        for channel in 0..<3 { #expect(abs(mixed[channel] - (red[channel] + gray[channel]) / 2) < 0.04) }
        // And its shadow half as dark
        let shade = gray[0] - SnipImages.pixel(solid, 200, 159)[0]
        let halfShade = gray[0] - SnipImages.pixel(half, 200, 159)[0]
        #expect(shade > 0.04 && abs(halfShade - shade / 2) < 0.03)
    }

    @Test func aSeeThroughHighlightIsFainterStill() {
        let snip = SnipImages.plain()
        var highlight = Annotation(kind: .highlight, color: .yellow, thickness: .thin, start: CGPoint(x: 100, y: 50),
                                   end: CGPoint(x: 300, y: 250))
        let usual = SnipRenderer.render(snip, [highlight], scale: 2)!
        highlight.opacity = 0.5
        let faint = SnipRenderer.render(snip, [highlight], scale: 2)!
        let gray = SnipImages.pixel(snip, 200, 150)[2]
        // Yellow takes away blue: half as much of it
        let usualTint = gray - SnipImages.pixel(usual, 200, 150)[2]
        let faintTint = gray - SnipImages.pixel(faint, 200, 150)[2]
        #expect(usualTint > 0.1 && abs(faintTint - usualTint / 2) < 0.03)
    }

    @Test func arrowsAreThinAtTheTail() {
        let arrow = Annotation(kind: .arrow, color: .red, thickness: .thick, start: CGPoint(x: 50, y: 150),
                               end: CGPoint(x: 350, y: 150))
        let image = SnipRenderer.render(SnipImages.plain(), [arrow], scale: 2)!
        #expect(SnipImages.isRed(SnipImages.pixel(image, 60, 150)))
        #expect(!SnipImages.isRed(SnipImages.pixel(image, 60, 155)))
        #expect(SnipImages.isRed(SnipImages.pixel(image, 300, 155)))
        // And wider again at the head
        #expect(SnipImages.isRed(SnipImages.pixel(image, 320, 159)))
    }

    @Test func blackAndWhiteAreBlackAndWhite() {
        for (color, value) in [(Annotation.Color.black, 0.0), (.white, 1.0)] {
            let line = Annotation(kind: .line, color: color, thickness: .thick, start: CGPoint(x: 100, y: 50),
                                  end: CGPoint(x: 100, y: 250))
            let image = SnipRenderer.render(SnipImages.plain(), [line], scale: 2)!
            #expect(SnipImages.pixel(image, 100, 150).allSatisfy { abs($0 - value) < 0.02 })
        }
    }

    @Test func aBlurSoftensWhatsUnderItAndNothingElse() {
        let snip = SnipImages.halves()
        let blur = Annotation(kind: .blur, color: .red, thickness: .thin, start: CGPoint(x: 150, y: 100),
                              end: CGPoint(x: 250, y: 200))
        let image = SnipRenderer.render(snip, [blur], scale: 2)!
        // The sharp edge down the middle turns gray on both sides
        let left = SnipImages.pixel(image, 195, 150)[0], right = SnipImages.pixel(image, 205, 150)[0]
        #expect(left > 0.1 && left < right && right < 0.95)
        // Just outside the blur, it's as sharp as ever
        #expect(SnipImages.pixel(image, 195, 97) == SnipImages.pixel(snip, 195, 97))
        #expect(SnipImages.pixel(image, 205, 203) == SnipImages.pixel(snip, 205, 203))
        #expect(SnipImages.pixel(image, 147, 150) == SnipImages.pixel(snip, 147, 150))
    }

    @Test func aBlurAtTheSnipsEdgeDoesntFade() {
        let snip = SnipImages.plain()
        let blur = Annotation(kind: .blur, color: .red, thickness: .thin, start: .zero, end: CGPoint(x: 60, y: 60))
        let image = SnipRenderer.render(snip, [blur], scale: 2)!
        for (blurred, plain) in zip(SnipImages.pixel(image, 1, 30), SnipImages.pixel(snip, 1, 30)) {
            #expect(abs(blurred - plain) < 0.02)
        }
    }

    @Test func blursGoUnderTheOtherShapes() {
        let box = Annotation(kind: .box, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                             end: CGPoint(x: 300, y: 250))
        let blur = Annotation(kind: .blur, color: .red, thickness: .thin, start: CGPoint(x: 50, y: 100),
                              end: CGPoint(x: 350, y: 200))
        let image = SnipRenderer.render(SnipImages.halves(), [box, blur], scale: 2)!
        #expect(SnipImages.isRed(SnipImages.pixel(image, 100, 150)))
    }

    @Test func theShapeTheEraserPointsAtIsFaint() {
        let snip = SnipImages.plain()
        let line = Annotation(kind: .line, color: .red, thickness: .thick, start: CGPoint(x: 100, y: 50),
                              end: CGPoint(x: 100, y: 250))
        // As the editor's canvas draws it
        let context = CGContext(data: nil, width: snip.width, height: snip.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: snip.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(snip, in: CGRect(x: 0, y: 0, width: snip.width, height: snip.height))
        context.translateBy(x: 0, y: CGFloat(snip.height))
        context.scaleBy(x: 1, y: -1)
        SnipRenderer.draw([line], in: context, scale: 2, faded: 0)
        let faint = SnipImages.pixel(context.makeImage()!, 100, 150)
        #expect(!SnipImages.isRed(faint) && faint[0] > faint[1] + 0.1)
    }

    @Test func keepsTheSnipsColorSpace() {
        let image = SnipRenderer.render(SnipImages.plain(), [], scale: 2)!
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test(arguments: zip([Annotation.Thickness.thin, .thick], [4, 10]))
    func linesAreTheirThicknessInPixels(thickness: Annotation.Thickness, pixels: Int) {
        let line = Annotation(kind: .line, color: .red, thickness: thickness, start: CGPoint(x: 100, y: 50),
                              end: CGPoint(x: 100, y: 250))
        let image = SnipRenderer.render(SnipImages.plain(), [line], scale: 2)!
        #expect((80..<120).filter { SnipImages.isRed(SnipImages.pixel(image, $0, 150)) }.count == pixels)
    }

    @Test(arguments: zip([2.0, 1], [144.0, 72]))
    func keepsTheDPI(scale: CGFloat, dpi: Double) {
        let data = SnipRenderer.data(SnipImages.plain(), scale: scale)!
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyDPIWidth] as? Double == dpi)
        #expect(Snip(data: data)?.scale == scale)
    }

    @Test func makesTIFFForTheClipboard() {
        let data = SnipRenderer.data(SnipImages.plain(), scale: 2, type: .tiff)!
        let snip = Snip(data: data)
        #expect(snip?.pixelSize == CGSize(width: 400, height: 300))
        #expect(snip?.scale == 2)
    }
}

struct SnipTests {
    @Test func namedForWhenItWasTaken() {
        let utc = TimeZone(identifier: "UTC")!
        var components = DateComponents(year: 2026, month: 10, day: 4, hour: 14, minute: 32, second: 5)
        components.timeZone = utc
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(Snip.name(for: date, in: utc) == "Snip 2026-10-04 at 14.32.05")
    }

    @Test func sizeIsInPoints() {
        #expect(Snip(image: SnipImages.plain(width: 616, height: 430), scale: 2).size == CGSize(width: 308, height: 215))
    }

    @Test func noDPIMeansStandardScale() {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, SnipImages.plain(), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(Snip(data: data as Data)?.scale == 1)
    }

    @Test func garbageIsntASnip() {
        #expect(Snip(data: Data("nonsense".utf8)) == nil)
    }
}

struct SnipFitTests {
    @Test func aRetinaSnipInALargeCanvasShowsAtActualSizeCentered() {
        let fit = SnipFit(CGSize(width: 616, height: 430), scale: 2, in: CGSize(width: 600, height: 400))
        #expect(fit.frame == CGRect(x: 146, y: 92, width: 308, height: 215))
        #expect(fit.pixelsPerPoint == 2)
    }

    @Test func aSmallCanvasScalesItDown() {
        let fit = SnipFit(CGSize(width: 2000, height: 1000), scale: 2, in: CGSize(width: 500, height: 500))
        #expect(fit.frame == CGRect(x: 0, y: 125, width: 500, height: 250))
        #expect(fit.pixelsPerPoint == 4)
    }

    @Test func pointerToPixelsAndBack() {
        let fit = SnipFit(CGSize(width: 2000, height: 1000), scale: 2, in: CGSize(width: 500, height: 500))
        let pixel = fit.pixel(for: CGPoint(x: 100, y: 200))
        #expect(pixel == CGPoint(x: 400, y: 300))
        #expect(fit.point(for: pixel) == CGPoint(x: 100, y: 200))
    }

    @Test func pointsOffTheSnipAreKeptOnIt() {
        let fit = SnipFit(CGSize(width: 2000, height: 1000), scale: 2, in: CGSize(width: 500, height: 500))
        #expect(fit.pixel(for: CGPoint(x: -50, y: 20)) == .zero)
        #expect(fit.pixel(for: CGPoint(x: 900, y: 900)) == CGPoint(x: 2000, y: 1000))
    }
}

struct SnipEditorLayoutTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func actualSizeWhenItFits() {
        // Beside the 148-point sidebar, with 14 points of blue between and around them, and 4 under the title bar
        #expect(SnipEditorLayout.contentSize(for: CGSize(width: 1000, height: 600), on: display)
                == CGSize(width: 1190, height: 618))
    }

    @Test func shrunkToFitNinetyPercentOfTheDisplay() {
        let size = SnipEditorLayout.contentSize(for: CGSize(width: 2000, height: 1200), on: display)
        #expect(size == CGSize(width: 1296, height: 682))
        // Same shape as the snip
        let chrome = SnipEditorLayout.chrome
        #expect(abs((size.width - chrome.width) / (size.height - chrome.height) - 2000 / 1200) < 0.01)
    }

    @Test func neverShorterThanTheSidebar() {
        #expect(SnipEditorLayout.contentSize(for: CGSize(width: 100, height: 50), on: display)
                == CGSize(width: SnipEditorLayout.minimumWidth, height: SnipEditorLayout.minimumHeight))
    }
}

struct SnipTextTests {
    private let isWhite: ([Double]) -> Bool = { $0.allSatisfy { $0 > 0.95 } }
    /// The menu's dark ink, not black
    private let isInk: ([Double]) -> Bool = {
        abs($0[0] - 0.09) < 0.05 && abs($0[1] - 0.12) < 0.05 && abs($0[2] - 0.24) < 0.06
    }

    /// Where pixels that match are, in a region
    private func box(_ image: CGImage, in region: CGRect, where match: ([Double]) -> Bool) -> CGRect? {
        var found: CGRect?
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) where match(SnipImages.pixel(image, x, y)) {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                found = found?.union(pixel) ?? pixel
            }
        }
        return found
    }

    private func text(_ string: String, color: Annotation.Color = .red, at start: CGPoint = CGPoint(x: 100, y: 60),
                      size: CGFloat = 16) -> Annotation {
        Annotation(kind: .text, color: color, thickness: .thin, start: start, end: start, text: string, textSize: size)
    }

    @Test func itsLabelsTopLeftIsTheStartPoint() throws {
        let hi = text("Hi")
        let image = SnipRenderer.render(SnipImages.plain(), [hi], scale: 2)!
        let label = try #require(box(image, in: CGRect(x: 80, y: 40, width: 200, height: 100), where: SnipImages.isRed))
        let bounds = SnipRenderer.labelBounds(hi, scale: 2)
        #expect(label.minX == 100 && label.minY == 60)
        #expect(abs(label.maxX - bounds.maxX) <= 1 && abs(label.maxY - bounds.maxY) <= 1)
    }

    @Test func itsLettersArePastTheRoomOnTheLabel() throws {
        let image = SnipRenderer.render(SnipImages.plain(), [text("Hi")], scale: 2)!
        let letters = try #require(box(image, in: CGRect(x: 80, y: 40, width: 200, height: 100), where: isWhite))
        let font = SnipRenderer.textFont(size: 16, scale: 2)
        // 7 points in and 3 down, at 2 pixels a point, and capitals come up to their cap height
        #expect(letters.minX >= 114 && letters.minX <= 120)
        let capTop = 60 + 6 + CTFontGetAscent(font) - CTFontGetCapHeight(font)
        #expect(abs(letters.minY - capTop) <= 2)
        #expect(letters.height > CTFontGetCapHeight(font) - 3)
    }

    @Test func itsLettersAreWhiteOnADarkLabelAndInkOnALightOne() {
        let region = CGRect(x: 80, y: 40, width: 200, height: 100)
        for color in Annotation.Color.allCases {
            let image = SnipRenderer.render(SnipImages.plain(), [text("Hi", color: color)], scale: 2)!
            let light = [Annotation.Color.green, .yellow, .white].contains(color)
            #expect((box(image, in: region, where: isInk) != nil) == light)
            if color != .white { #expect((box(image, in: region, where: isWhite) != nil) == !light) }
        }
    }

    @Test func itsLabelCastsASoftShadow() {
        let snip = SnipImages.plain()
        let hi = text("Hi")
        let image = SnipRenderer.render(snip, [hi], scale: 2)!
        let bounds = SnipRenderer.labelBounds(hi, scale: 2)
        let below = SnipImages.pixel(image, Int(bounds.midX), Int(bounds.maxY) + 2)[0]
        #expect(below < SnipImages.pixel(snip, Int(bounds.midX), Int(bounds.maxY) + 2)[0] - 0.04)
    }

    @Test(arguments: Annotation.textSizes)
    func itsSizeIsInPoints(size: CGFloat) throws {
        let image = SnipRenderer.render(SnipImages.plain(), [text("H", size: size)], scale: 2)!
        let letter = try #require(box(image, in: CGRect(x: 90, y: 50, width: 160, height: 110), where: isWhite))
        // A capital's height, at 2 pixels a point
        #expect(abs(letter.height - CTFontGetCapHeight(SnipRenderer.textFont(size: size, scale: 2))) <= 2)
    }

    @Test func aSeeThroughTextFadesAsOne() throws {
        let snip = SnipImages.plain()
        var letter = text("H")
        let solid = SnipRenderer.render(snip, [letter], scale: 2)!
        letter.opacity = 0.5
        let half = SnipRenderer.render(snip, [letter], scale: 2)!
        // The white letters show half the snip's gray, not the label's red under them
        let region = CGRect(x: 90, y: 50, width: 160, height: 110)
        let isHalfWhite: ([Double]) -> Bool = { pixel in
            pixel.allSatisfy { $0 > 0.68 && $0 < 0.82 } && pixel.max()! - pixel.min()! < 0.04
        }
        let white = try #require(box(solid, in: region, where: isWhite))
        let faded = try #require(box(half, in: region, where: isHalfWhite))
        #expect(abs(faded.minX - white.minX) <= 2 && abs(faded.maxY - white.maxY) <= 2)
    }

    @Test func theTextBeingTypedFadesToo() {
        let snip = SnipImages.plain()
        let context = CGContext(data: nil, width: snip.width, height: snip.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: snip.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(snip, in: CGRect(x: 0, y: 0, width: snip.width, height: snip.height))
        context.translateBy(x: 0, y: CGFloat(snip.height))
        context.scaleBy(x: 1, y: -1)
        var draft = text("")
        draft.opacity = 0.5
        SnipRenderer.drawLabelBeingTyped(draft, in: context, scale: 2)
        let image = context.makeImage()!
        let label = SnipImages.pixel(image, 106, 66)
        #expect(!SnipImages.isRed(label) && label[0] > 0.65 && label[1] < 0.45)
    }

    @Test func blankTextDrawsNothing() {
        let snip = SnipImages.plain()
        let image = SnipRenderer.render(snip, [text("")], scale: 2)!
        for (x, y) in [(100, 60), (110, 80), (130, 90)] {
            #expect(SnipImages.pixel(image, x, y) == SnipImages.pixel(snip, x, y))
        }
    }

    @Test func theTextBeingTypedShowsJustItsLabel() {
        let snip = SnipImages.plain()
        let context = CGContext(data: nil, width: snip.width, height: snip.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: snip.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(snip, in: CGRect(x: 0, y: 0, width: snip.width, height: snip.height))
        context.translateBy(x: 0, y: CGFloat(snip.height))
        context.scaleBy(x: 1, y: -1)
        SnipRenderer.drawLabel(text("Hi"), in: context, scale: 2)
        let image = context.makeImage()!
        let region = CGRect(x: 80, y: 40, width: 200, height: 100)
        #expect(box(image, in: region, where: SnipImages.isRed) != nil && box(image, in: region, where: isWhite) == nil)
    }

    @Test func shiftLeavesTextWhereItIs() {
        #expect(Annotation.constrained(.text, from: .zero, to: CGPoint(x: 30, y: 7)) == CGPoint(x: 30, y: 7))
    }
}
