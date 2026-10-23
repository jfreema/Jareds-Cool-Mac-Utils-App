import Foundation
import Testing
@testable import Yafie

struct ArrowStartTests {
    private func start(_ settings: [String: Any]) -> Double {
        HiddenIcons.startingPosition(controlCenter: settings)
    }

    @Test func startsLeftOfTheSystemIcons() {
        // As `defaults read com.apple.controlcenter` shows them, in any order
        #expect(start([
            "NSStatusItem Preferred Position WiFi": 191.5,
            "NSStatusItem Preferred Position Sound": 289,
            "NSStatusItem Preferred Position UserSwitcher": 210,
            "NSStatusItem Preferred Position Battery": 239,
        ]) == 290)
    }

    @Test func leavesOutControlCenterAndTheClock() {
        // They stay at the right end whatever their spots
        #expect(start([
            "NSStatusItem Preferred Position BentoBox-0": 400,
            "NSStatusItem Preferred Position Clock": 500,
            "NSStatusItem Preferred Position WiFi": 191,
        ]) == 192)
    }

    @Test func leavesOutIconsTurnedOff() {
        #expect(start([
            "NSStatusItem Preferred Position NowPlaying": 383,
            "NSStatusItem Visible NowPlaying": false,
            "NSStatusItem Preferred Position ScreenMirroring": 431,
            "NSStatusItem VisibleCC ScreenMirroring": 0,
            "NSStatusItem Preferred Position Sound": 289,
            "NSStatusItem VisibleCC Sound": 1,
        ]) == 290)
    }

    @Test func startsAtTheRightEndWithoutSystemIcons() {
        // As on GitHub's Mac runner, which has none
        #expect(start([
            "NSStatusItem Preferred Position BentoBox-0": 153,
            "NSStatusItem VisibleCC BentoBox-0": 1,
            "NSStatusItem VisibleCC Clock": 1,
            "LastUpdated": "2026-10-23",
        ]) == 0)
        #expect(start([:]) == 0)
    }
}
