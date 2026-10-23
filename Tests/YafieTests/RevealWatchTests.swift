import CoreGraphics
import Foundation
import Testing
@testable import Yafie

struct RevealWatchTests {
    private func sample(_ time: TimeInterval, menuBar: Bool = true, key: Bool = false, menu: Bool = false,
                        inMenuBar: Bool = false) -> RevealWatch.Sample {
        RevealWatch.Sample(time: time, hasMenuBar: menuBar, hasKeyWindow: key, isMenuOpen: menu,
                           isPointerInMenuBar: inMenuBar)
    }

    @Test func staysWhileThePointerIsInTheMenuBar() {
        var watch = RevealWatch(start: 0)
        for time in stride(from: 0.0, through: 30, by: 0.25) {
            #expect(watch.decide(sample(time, inMenuBar: true)) == .stay)
        }
    }

    @Test func hidesAFewSecondsAfterThePointerLeavesWithNothingOpened() {
        var watch = RevealWatch(start: 0)
        #expect(watch.decide(sample(0, inMenuBar: true)) == .stay)
        #expect(watch.decide(sample(1)) == .stay)
        #expect(watch.decide(sample(3.9)) == .stay)
        #expect(watch.decide(sample(4)) == .hideAndReturn)
    }

    @Test func comingBackToTheMenuBarStartsTheWaitOver() {
        var watch = RevealWatch(start: 0)
        #expect(watch.decide(sample(1)) == .stay)
        #expect(watch.decide(sample(3, inMenuBar: true)) == .stay)
        #expect(watch.decide(sample(4)) == .stay)
        #expect(watch.decide(sample(6.9)) == .stay)
        #expect(watch.decide(sample(7)) == .hideAndReturn)
    }

    @Test func staysWhileAMenuIsOpen() {
        var watch = RevealWatch(start: 0)
        for time in stride(from: 0.0, through: 30, by: 0.25) {
            #expect(watch.decide(sample(time, menu: true)) == .stay)
        }
    }

    @Test func hidesSoonAfterAMenuCloses() {
        var watch = RevealWatch(start: 0)
        #expect(watch.decide(sample(0, inMenuBar: true)) == .stay)
        #expect(watch.decide(sample(1, menu: true)) == .stay)
        #expect(watch.decide(sample(10, menu: true)) == .stay)
        #expect(watch.decide(sample(10.25)) == .stay)
        #expect(watch.decide(sample(11)) == .stay)
        #expect(watch.decide(sample(11.25)) == .hideAndReturn)
    }

    @Test func staysAfterAMenuClosesWhileThePointerIsOnTheOtherIcons() {
        var watch = RevealWatch(start: 0)
        #expect(watch.decide(sample(1, menu: true)) == .stay)
        #expect(watch.decide(sample(2, inMenuBar: true)) == .stay)
        #expect(watch.decide(sample(20, inMenuBar: true)) == .stay)
    }

    @Test func staysWhileAWindowOfYafiesHasTheKeyboard() {
        // Like the tuner, opened from Yafie's own icon
        var watch = RevealWatch(start: 0)
        for time in stride(from: 0.0, through: 30, by: 0.25) {
            #expect(watch.decide(sample(time, key: true)) == .stay)
        }
        #expect(watch.decide(sample(31)) == .stay)
        #expect(watch.decide(sample(34)) == .hideAndReturn)
    }

    @Test func hidesWithoutTheFocusOnceAnotherAppHasTheMenuBar() {
        var watch = RevealWatch(start: 0)
        #expect(watch.decide(sample(0.25, inMenuBar: true)) == .stay)
        #expect(watch.decide(sample(0.5, menuBar: false, inMenuBar: true)) == .hide)
    }

    @Test func asksAgainWhileMacOSHasntHandedOverTheMenuBar() {
        // The app you were in still has it right after the click
        var watch = RevealWatch(start: 10)
        #expect(watch.decide(sample(10.25, menuBar: false, inMenuBar: true)) == .ask)
        #expect(watch.decide(sample(11.25, menuBar: false, inMenuBar: true)) == .ask)
        #expect(watch.decide(sample(11.5, menuBar: false, inMenuBar: true)) == .hide)
        #expect(!watch.hadMenuBar)
    }

    @Test func staysOnceTheMenuBarComes() {
        var watch = RevealWatch(start: 10)
        #expect(watch.decide(sample(10.25, menuBar: false, inMenuBar: true)) == .ask)
        #expect(watch.decide(sample(10.5, inMenuBar: true)) == .stay)
        #expect(watch.hadMenuBar)
        #expect(watch.decide(sample(15, inMenuBar: true)) == .stay)
    }

    @Test func knowsMenusFromMenuBarIcons() {
        let menu = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let mainMenu = Int(CGWindowLevelForKey(.mainMenuWindow))
        #expect(RevealWatch.isMenu(layer: menu, height: 200))
        #expect(RevealWatch.isMenu(layer: menu - 1, height: 200))
        // An icon, even on a MacBook with a notch, where the menu bar is taller
        #expect(!RevealWatch.isMenu(layer: status, height: 24))
        #expect(!RevealWatch.isMenu(layer: status, height: 37))
        // A popover or panel hanging from one
        #expect(RevealWatch.isMenu(layer: status, height: 300))
        // The menu bar itself
        #expect(!RevealWatch.isMenu(layer: mainMenu, height: 37))
        #expect(!RevealWatch.isMenu(layer: 0, height: 600))
    }

    @Test func findsThePointerInTheMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(RevealWatch.isInMenuBar(CGPoint(x: 900, y: 981), screen: screen, barHeight: 37))
        #expect(RevealWatch.isInMenuBar(CGPoint(x: 900, y: 982 - 40), screen: screen, barHeight: 37))
        #expect(!RevealWatch.isInMenuBar(CGPoint(x: 900, y: 900), screen: screen, barHeight: 37))
        // While the menu bar is hidden, as in full screen
        #expect(RevealWatch.isInMenuBar(CGPoint(x: 900, y: 970), screen: screen, barHeight: 0))
        // On a display beside it
        #expect(!RevealWatch.isInMenuBar(CGPoint(x: 1600, y: 981), screen: screen, barHeight: 37))
    }
}
