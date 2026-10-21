import CoreGraphics
import Testing
@testable import Yafie

/// A 1440 × 900 screen with a 25-point menu bar, and the Dock 80 points deep on one side
private let belowDock = CGRect(x: 0, y: 80, width: 1440, height: 795)
private let besideLeftDock = CGRect(x: 80, y: 0, width: 1360, height: 875)
private let besideRightDock = CGRect(x: 0, y: 0, width: 1360, height: 875)

private let bottomIcon = CGRect(x: 700, y: 4, width: 72, height: 72)
private let leftIcon = CGRect(x: 4, y: 400, width: 72, height: 72)
private let rightIcon = CGRect(x: 1364, y: 400, width: 72, height: 72)

private let fullCard = PreviewLayout.cardSize(scale: 1)

struct PreviewLayoutTests {
    @Test func oneWindowSitsCenteredAboveItsIcon() {
        let placement = PreviewLayout.place(1, by: bottomIcon, edge: .bottom, in: belowDock)
        #expect(fullCard == CGSize(width: 220, height: 164))
        #expect(placement.panel == CGRect(x: 618, y: 84, width: 236, height: 180))
        #expect(placement.cards == [CGRect(x: 8, y: 8, width: 220, height: 164)])
    }

    @Test func staysOnTheScreen() {
        let first = PreviewLayout.place(2, by: CGRect(x: 2, y: 4, width: 72, height: 72), edge: .bottom, in: belowDock)
        #expect(first.panel.minX == 8)
        let last = PreviewLayout.place(2, by: CGRect(x: 1366, y: 4, width: 72, height: 72), edge: .bottom,
                                       in: belowDock)
        #expect(last.panel.maxX == 1432)
    }

    @Test func manyWindowsWrapIntoRowsFromTheTopLeft() {
        let placement = PreviewLayout.place(7, by: bottomIcon, edge: .bottom, in: belowDock)
        // Six cards fit across 1440 points
        #expect(placement.panel.size == CGSize(width: 6 * 228 + 8, height: 2 * 172 + 8))
        #expect(placement.cards[0].origin == CGPoint(x: 8, y: 180))
        #expect(placement.cards[5].origin == CGPoint(x: 8 + 5 * 228, y: 180))
        #expect(placement.cards[6].origin == CGPoint(x: 8, y: 8))
        #expect(placement.cards.allSatisfy { $0.size == fullCard })
    }

    @Test func tooManyWindowsShrinkTheCards() {
        let placement = PreviewLayout.place(30, by: bottomIcon, edge: .bottom, in: belowDock)
        #expect(placement.cards.count == 30)
        #expect(placement.cards[0].width < fullCard.width)
        #expect(placement.panel.minY == bottomIcon.maxY + PreviewLayout.gap)
        #expect(placement.panel.maxY <= belowDock.maxY - PreviewLayout.margin)
        #expect(placement.panel.minX >= 8 && placement.panel.maxX <= 1432)
        let bounds = CGRect(origin: .zero, size: placement.panel.size)
        #expect(placement.cards.allSatisfy { bounds.contains($0) })
    }

    @Test func besideASideDock() {
        let left = PreviewLayout.place(2, by: leftIcon, edge: .left, in: besideLeftDock)
        #expect(left.panel == CGRect(x: 84, y: 260, width: 236, height: 352))
        #expect(left.cards.map(\.origin) == [CGPoint(x: 8, y: 180), CGPoint(x: 8, y: 8)])
        let right = PreviewLayout.place(2, by: rightIcon, edge: .right, in: besideRightDock)
        #expect(right.panel == CGRect(x: 1120, y: 260, width: 236, height: 352))
    }

    @Test func sideDockColumnsStartNextToTheDock() {
        // Four cards fit down 875 points, so six take two columns
        let right = PreviewLayout.place(6, by: rightIcon, edge: .right, in: besideRightDock)
        #expect(right.panel.width == 464)  // two columns
        #expect(right.cards[0].origin == CGPoint(x: 236, y: right.panel.height - 172))
        #expect(right.cards[3].origin == CGPoint(x: 236, y: 8))
        #expect(right.cards[4].origin == CGPoint(x: 8, y: right.panel.height - 172))
        let left = PreviewLayout.place(6, by: leftIcon, edge: .left, in: besideLeftDock)
        #expect(left.cards[0].minX == 8)
        #expect(left.cards[4].minX == 236)
    }

    @Test func picturesKeepTheirWindowsShape() {
        let area = CGRect(x: 0, y: 0, width: 240, height: 150)
        let wide = PreviewLayout.fit(CGSize(width: 1600, height: 900), in: area)
        #expect(wide == CGRect(x: 0, y: 8, width: 240, height: 135))
        let tall = PreviewLayout.fit(CGSize(width: 900, height: 1600), in: area)
        #expect(tall == CGRect(x: 78, y: 0, width: 84, height: 150))
        #expect(PreviewLayout.fit(.zero, in: area) == area)
    }

    @Test func theCloseButtonIsInThePicturesTopRightCorner() {
        // A tall window's picture, narrower than its card
        let picture = CGRect(x: 78, y: 28, width: 84, height: 150)
        #expect(PreviewLayout.closeButton(on: picture) == CGRect(x: 138, y: 154, width: 20, height: 20))
    }

    @Test func cardsHoldAPictureAboveATitle() {
        #expect(PreviewLayout.pictureArea(in: fullCard) == CGRect(x: 8, y: 28, width: 204, height: 128))
        #expect(PreviewLayout.titleArea(in: fullCard) == CGRect(x: 8, y: 8, width: 204, height: 16))
    }

    @Test func staysOpenOnTheWayFromTheIconToThePanel() {
        let panel = PreviewLayout.place(3, by: bottomIcon, edge: .bottom, in: belowDock).panel
        func keeps(_ x: CGFloat, _ y: CGFloat) -> Bool {
            PreviewLayout.keepsOpen(CGPoint(x: x, y: y), panel: panel, icon: bottomIcon, edge: .bottom)
        }
        #expect(keeps(736, 40))  // on the icon
        #expect(keeps(736, 80))  // just above it
        #expect(keeps(panel.minX + 2, 80))  // heading for the first card
        #expect(keeps(panel.midX, panel.midY))
        #expect(!keeps(300, 40))  // another icon
        #expect(!keeps(panel.midX, panel.maxY + 20))
        #expect(!keeps(panel.minX - 20, panel.midY))
    }

    @Test func staysOpenBesideASideDock() {
        let panel = PreviewLayout.place(2, by: rightIcon, edge: .right, in: besideRightDock).panel
        func keeps(_ x: CGFloat, _ y: CGFloat) -> Bool {
            PreviewLayout.keepsOpen(CGPoint(x: x, y: y), panel: panel, icon: rightIcon, edge: .right)
        }
        #expect(keeps(1360, 436))
        #expect(keeps(1360, panel.maxY - 4))
        #expect(!keeps(1400, 100))
    }

    @Test func magnifiedIconsGrowAwayFromTheEdge() {
        #expect(PreviewLayout.magnified(bottomIcon, to: 128, edge: .bottom)
                    == CGRect(x: 700, y: 4, width: 72, height: 128))
        #expect(PreviewLayout.magnified(leftIcon, to: 128, edge: .left) == CGRect(x: 4, y: 400, width: 128, height: 72))
        #expect(PreviewLayout.magnified(rightIcon, to: 128, edge: .right)
                    == CGRect(x: 1308, y: 400, width: 128, height: 72))
        // Already magnified further, or magnification smaller than the icon
        #expect(PreviewLayout.magnified(bottomIcon, to: 48, edge: .bottom) == bottomIcon)
    }

    @Test func dockEdgeFromItsSetting() {
        #expect(PreviewLayout.Edge(orientation: nil) == .bottom)
        #expect(PreviewLayout.Edge(orientation: "bottom") == .bottom)
        #expect(PreviewLayout.Edge(orientation: "left") == .left)
        #expect(PreviewLayout.Edge(orientation: "right") == .right)
    }
}
