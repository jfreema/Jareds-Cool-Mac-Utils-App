import CoreGraphics
import Foundation
import Testing
@testable import Yafie

private let start = Date(timeIntervalSinceReferenceDate: 0)

private func at(_ seconds: TimeInterval) -> Date { start + seconds }

/// ⌘ in the device-independent flags, plus the left or right key's own bit, as a flagsChanged event carries them
private let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
private let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
private let bothCommands = leftCommand.union(rightCommand)

struct CleaningSessionTests {
    @Test func endsAfterFiveMinutes() {
        let session = CleaningSession(start: start)
        #expect(session.deadline == at(300))
        #expect(!session.isOver(at: at(299.9)))
        #expect(session.isOver(at: at(300)))
    }

    @Test func holdingBothCommandKeysEndsItAfterASecondAndAHalf() {
        var session = CleaningSession(start: start)
        session.commandKeys(down: true, at: at(10))
        #expect(session.deadline == at(11.5))
        #expect(!session.isOver(at: at(11.4)))
        #expect(session.isOver(at: at(11.5)))
    }

    @Test func lettingGoStartsTheHoldOver() {
        var session = CleaningSession(start: start)
        session.commandKeys(down: true, at: at(10))
        session.commandKeys(down: false, at: at(11))
        #expect(session.heldSince == nil)
        #expect(session.deadline == at(300))
        session.commandKeys(down: true, at: at(20))
        #expect(session.deadline == at(21.5))
    }

    @Test func theHoldCountsFromWhenBothWentDown() {
        var session = CleaningSession(start: start)
        session.commandKeys(down: true, at: at(10))
        session.commandKeys(down: true, at: at(11))
        #expect(session.deadline == at(11.5))
    }

    @Test func aHoldNearTheEndDoesNotPushItBack() {
        var session = CleaningSession(start: start)
        session.commandKeys(down: true, at: at(299))
        #expect(session.deadline == at(300))
    }

    @Test func needsTheLeftAndRightCommandKeys() {
        #expect(CleaningSession.bothCommandKeys(bothCommands))
        #expect(!CleaningSession.bothCommandKeys(leftCommand))
        #expect(!CleaningSession.bothCommandKeys(rightCommand))
        #expect(!CleaningSession.bothCommandKeys([]))
        // With Shift and a non-coalesced bit too
        #expect(CleaningSession.bothCommandKeys(bothCommands.union([.maskShift, .maskNonCoalesced])))
        // ⌘ alone, without the keys' own bits
        #expect(!CleaningSession.bothCommandKeys(.maskCommand))
    }

    @Test func countdownShowsMinutesAndSeconds() {
        #expect(CleaningSession.countdown(300) == "5:00")
        #expect(CleaningSession.countdown(299) == "4:59")
        #expect(CleaningSession.countdown(299.000_000_1) == "4:59")
        #expect(CleaningSession.countdown(65) == "1:05")
        #expect(CleaningSession.countdown(9) == "0:09")
        #expect(CleaningSession.countdown(-1) == "0:00")
    }
}
