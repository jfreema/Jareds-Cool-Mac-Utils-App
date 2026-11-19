import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import JaredsMacUtils

private func text(_ string: String, changeCount: Int = 1) -> ClipEntry {
    ClipEntry(items: [[ClipData(type: ClipEntry.textType, data: Data(string.utf8))]], changeCount: changeCount)!
}

/// A PNG of a plain picture, as a browser's Copy Image puts on the clipboard
private func png(width: Int, height: Int) -> Data {
    let data = NSMutableData()
    let file = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(file, SnipImages.plain(width: width, height: height), nil)
    CGImageDestinationFinalize(file)
    return data as Data
}

private func previews(_ history: ClipHistory) -> [ClipPreview] { history.entries.map(\.preview) }

struct ClipHistoryTests {
    @Test func keepsTheLastFiveNewestFirst() {
        var history = ClipHistory()
        for word in ["one", "two", "three", "four", "five", "six"] { history.add(text(word)) }
        #expect(previews(history) == [.text("six"), .text("five"), .text("four"), .text("three"), .text("two")])
    }

    @Test func aCopyMadeAgainMovesToTheTop() {
        var history = ClipHistory()
        for word in ["one", "two", "three", "one"] { history.add(text(word)) }
        #expect(previews(history) == [.text("one"), .text("three"), .text("two")])
    }

    @Test func aPastedCopyBecomesTheNewest() {
        var history = ClipHistory()
        for (count, word) in ["one", "two", "three"].enumerated() { history.add(text(word, changeCount: count)) }
        history.promote(2, changeCount: 9)
        #expect(previews(history) == [.text("one"), .text("three"), .text("two")])
        #expect(history.entries[0].changeCount == 9)
        // Out of range does nothing
        history.promote(5, changeCount: 10)
        #expect(previews(history) == [.text("one"), .text("three"), .text("two")])
    }
}

struct ClipEntryTests {
    @Test func skipsWhatPasswordManagersMarkAsPrivate() {
        let password = [ClipData(type: ClipEntry.textType, data: Data("hunter2".utf8)),
                        ClipData(type: "org.nspasteboard.ConcealedType", data: Data())]
        #expect(ClipEntry(items: [password], changeCount: 1) == nil)
        #expect(ClipEntry.isPrivate(["public.utf8-plain-text", "com.agilebits.onepassword"]))
        #expect(!ClipEntry.isPrivate(["public.utf8-plain-text", "public.rtf"]))
    }

    @Test func skipsAnEmptyCopy() {
        #expect(ClipEntry(items: [], changeCount: 1) == nil)
        #expect(ClipEntry(items: [[], []], changeCount: 1) == nil)
    }

    @Test func showsTextOnOneLine() {
        #expect(text("  Meet at\n\n the  north\tentrance \n").preview == .text("Meet at the north entrance"))
    }

    @Test func cutsLongTextShort() {
        let long = String(repeating: "word ", count: 2000)
        guard case .text(let shown) = text(long).preview else {
            Issue.record("Not text")
            return
        }
        #expect(shown.count == ClipPreview.longest)
        #expect(shown.hasSuffix("…"))
        // Only spaces is nothing to show
        #expect(ClipEntry.oneLine(" \n\t ") == "")
    }

    @Test func showsFilesByName() {
        let finder = [[ClipData(type: ClipEntry.fileType, data: Data("file:///Users/jared/Battle%20Plan.pdf".utf8)),
                       ClipData(type: ClipEntry.textType, data: Data("Battle Plan.pdf".utf8))],
                      [ClipData(type: ClipEntry.fileType, data: Data("file:///Users/jared/Notes/".utf8))]]
        #expect(ClipEntry(items: finder, changeCount: 1)?.preview == .files(["Battle Plan.pdf", "Notes"]))
    }

    @Test func showsTextOverAPictureOfIt() {
        // As Excel and Pages copy: the text, and a picture of it
        let cells = [[ClipData(type: "public.png", data: png(width: 40, height: 20)),
                      ClipData(type: ClipEntry.textType, data: Data("Total\t42".utf8))]]
        #expect(ClipEntry(items: cells, changeCount: 1)?.preview == .text("Total 42"))
    }

    @Test func showsAPicturesSize() {
        let picture = png(width: 160, height: 90)
        let entry = ClipEntry(items: [[ClipData(type: "public.png", data: picture)]], changeCount: 1)
        #expect(entry?.preview == .picture(width: 160, height: 90))
        #expect(entry?.pictureData == picture)
        // Unreadable, it's still a picture
        let broken = ClipEntry(items: [[ClipData(type: "public.tiff", data: Data([1, 2, 3]))]], changeCount: 1)
        #expect(broken?.preview == .picture(width: 0, height: 0))
    }

    @Test func showsALinkOrNothing() {
        let link = [[ClipData(type: ClipEntry.linkType, data: Data("https://example.com/a".utf8))]]
        #expect(ClipEntry(items: link, changeCount: 1)?.preview == .text("https://example.com/a"))
        let color = [[ClipData(type: "com.apple.cocoa.pasteboard.color", data: Data([0, 1]))]]
        #expect(ClipEntry(items: color, changeCount: 1)?.preview == .other)
    }

    @Test func keepsEveryTypeInOrder() {
        let rich = [ClipData(type: "public.rtf", data: Data("{\\rtf1 Hi}".utf8)),
                    ClipData(type: ClipEntry.textType, data: Data("Hi".utf8))]
        #expect(ClipEntry(items: [rich], changeCount: 1)?.items == [rich])
    }
}

struct ClipThumbnailTests {
    @Test func keepsThePicturesShapeWithin96By48() {
        #expect(ClipPickerView.thumbnailSize(of: CGSize(width: 512, height: 512)) == CGSize(width: 48, height: 48))
        #expect(ClipPickerView.thumbnailSize(of: CGSize(width: 1600, height: 1000)) == CGSize(width: 77, height: 48))
        #expect(ClipPickerView.thumbnailSize(of: CGSize(width: 1920, height: 400)) == CGSize(width: 96, height: 20))
        #expect(ClipPickerView.thumbnailSize(of: .zero) == CGSize(width: 48, height: 48))
    }
}

struct ClipKeyTests {
    @Test func numbersPasteWhicheverRow() {
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_1)) == .choose(0))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_2)) == .choose(1))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_3)) == .choose(2))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_4)) == .choose(3))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_5)) == .choose(4))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_Keypad1)) == .choose(0))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_Keypad3)) == .choose(2))
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_Keypad5)) == .choose(4))
    }

    @Test func returnPastesTheLitRowAndArrowsMoveIt() {
        #expect(ClipKey(keyCode: UInt16(kVK_Return)) == .chooseLit)
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_KeypadEnter)) == .chooseLit)
        #expect(ClipKey(keyCode: UInt16(kVK_UpArrow)) == .up)
        #expect(ClipKey(keyCode: UInt16(kVK_DownArrow)) == .down)
    }

    @Test func anyOtherKeyCloses() {
        #expect(ClipKey(keyCode: UInt16(kVK_Escape)) == .close)
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_6)) == .close)
        #expect(ClipKey(keyCode: UInt16(kVK_ANSI_V)) == .close)
    }
}
