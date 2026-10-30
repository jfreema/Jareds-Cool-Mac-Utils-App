import CoreGraphics
import Foundation
import Testing
@testable import Yafie

/// A 1512 × 982 main screen, with a 1920 × 1080 one to its right and 200 points lower
private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let side = CGRect(x: 1512, y: -200, width: 1920, height: 1080)

struct RecordingLayoutTests {
    @Test func gifsAreAPixelAPointUpTo1280() {
        #expect(RecordingLayout.gifSize(for: CGSize(width: 800, height: 600)) == .init(width: 800, height: 600))
        #expect(RecordingLayout.gifSize(for: CGSize(width: 2560, height: 1440)) == .init(width: 1280, height: 720))
        #expect(RecordingLayout.gifSize(for: CGSize(width: 1000, height: 3000)) == .init(width: 427, height: 1280))
        #expect(RecordingLayout.gifSize(for: CGSize(width: 0.2, height: 0.2)) == .init(width: 1, height: 1))
    }

    @Test func screenCaptureKitCountsFromItsDisplaysTopLeft() {
        #expect(RecordingLayout.displayRect(CGRect(x: 100, y: 200, width: 300, height: 400), on: main)
                == CGRect(x: 100, y: 382, width: 300, height: 400))
        #expect(RecordingLayout.displayRect(CGRect(x: 1612, y: 0, width: 400, height: 300), on: side)
                == CGRect(x: 100, y: 580, width: 400, height: 300))
    }

    @Test func windowServerBoundsTurnRightSideUp() {
        #expect(RecordingLayout.appKitRect(CGRect(x: 100, y: 50, width: 400, height: 300), mainScreenHeight: 982)
                == CGRect(x: 100, y: 632, width: 400, height: 300))
    }

    @Test func aClickPicksTheFrontWindowUnderThePointer() {
        let front = CGRect(x: 100, y: 100, width: 400, height: 300)
        let back = CGRect(x: 300, y: 200, width: 600, height: 500)
        #expect(RecordingLayout.clicked(CGPoint(x: 350, y: 250), windows: [front, back], screen: main) == front)
        #expect(RecordingLayout.clicked(CGPoint(x: 800, y: 600), windows: [front, back], screen: main) == back)
    }

    @Test func aClickOffAnyWindowPicksTheScreen() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(RecordingLayout.clicked(CGPoint(x: 1000, y: 800), windows: [window], screen: main) == main)
    }

    @Test func aClickedWindowIsCutToItsScreen() {
        let across = CGRect(x: 1300, y: 300, width: 500, height: 400)
        #expect(RecordingLayout.clicked(CGPoint(x: 1400, y: 400), windows: [across], screen: main)
                == CGRect(x: 1300, y: 300, width: 212, height: 400))
    }

    @Test func aDragGoesEitherWayInWholePoints() {
        #expect(RecordingLayout.dragged(from: CGPoint(x: 400.5, y: 300.2), to: CGPoint(x: 100.4, y: 100.7), within: main)
                == CGRect(x: 100, y: 100, width: 301, height: 201))
    }

    @Test func aDragStaysOnItsScreen() {
        #expect(RecordingLayout.dragged(from: CGPoint(x: 1400, y: 900), to: CGPoint(x: 1700, y: 1100), within: main)
                == CGRect(x: 1400, y: 900, width: 112, height: 82))
    }

    @Test func stopSitsUnderTheArea() {
        let frame = RecordingLayout.barFrame(size: CGSize(width: 160, height: 40),
                                             around: CGRect(x: 400, y: 400, width: 600, height: 300), in: main)
        #expect(frame == CGRect(x: 620, y: 350, width: 160, height: 40))
    }

    @Test func stopGoesOverAnAreaAtTheBottom() {
        let frame = RecordingLayout.barFrame(size: CGSize(width: 160, height: 40),
                                             around: CGRect(x: 400, y: 20, width: 600, height: 300), in: main)
        #expect(frame.minY == 330)
    }

    @Test func stopGoesInsideAnAreaTheSizeOfTheScreen() {
        let frame = RecordingLayout.barFrame(size: CGSize(width: 160, height: 40), around: main, in: main)
        #expect(frame == CGRect(x: 676, y: 10, width: 160, height: 40))
    }

    @Test func stopStaysOnTheScreen() {
        let frame = RecordingLayout.barFrame(size: CGSize(width: 160, height: 40),
                                             around: CGRect(x: 1450, y: 400, width: 60, height: 60), in: main)
        #expect(frame.maxX == 1504)
    }

    @Test func stopIsNeverCutShort() {
        let frame = RecordingLayout.barFrame(size: CGSize(width: 126.2, height: 39.5),
                                             around: CGRect(x: 400, y: 400, width: 600, height: 300), in: main)
        #expect(frame == CGRect(x: 637, y: 350, width: 127, height: 40))
    }

    @Test func clockShowsMinutesAndSeconds() {
        #expect(RecordingLayout.clock(0) == "0:00")
        #expect(RecordingLayout.clock(7) == "0:07")
        #expect(RecordingLayout.clock(65) == "1:05")
    }

    @Test func summarySaysHowLongAndHowBig() {
        #expect(RecordingLayout.summary(seconds: 8.4, bytes: 3_240_000) == "8 seconds · 3.2 MB")
        #expect(RecordingLayout.summary(seconds: 0.3, bytes: 420_400) == "1 second · 420 KB")
    }

    @Test func framesBecomeImages() throws {
        let red: UInt32 = 0xFFFF_0000, blue: UInt32 = 0xFF00_00FF
        let image = try #require(RecordingLayout.image([red, blue, blue, red], width: 2, height: 2))
        #expect(GIFWriterTests.pixels(of: image) == [red, blue, blue, red])
    }

    @Test func recordingsAreNamedLikeSnips() {
        let utc = TimeZone(identifier: "UTC")!
        var components = DateComponents(year: 2026, month: 10, day: 30, hour: 9, minute: 5, second: 41)
        components.timeZone = utc
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(Snip.name("Recording", for: date, in: utc) == "Recording 2026-10-30 at 09.05.41")
    }
}
