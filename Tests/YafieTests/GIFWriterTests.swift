import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Yafie

/// GIFs written, then read back with ImageIO, which puts each frame together over the ones before
struct GIFWriterTests {
    private struct Written {
        let data: Data
        let source: CGImageSource

        var frameCount: Int { CGImageSourceGetCount(source) }

        /// In seconds, as written, not as browsers would stretch them
        var delays: [Double] {
            (0..<frameCount).map { index in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                return gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? -1
            }
        }

        func pixels(_ index: Int) -> [UInt32] {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return [] }
            return GIFWriterTests.pixels(of: image)
        }
    }

    private static let width = 40, height = 30

    private static func write(_ frames: [([UInt32], Double)], until end: Double,
                              width: Int = width, height: Int = height) -> Written {
        var data = Data()
        let writer = GIFWriter(width: width, height: height) { data.append($0) }
        for (frame, time) in frames { writer.add(frame, at: time) }
        writer.finish(at: end)
        return Written(data: data, source: CGImageSourceCreateWithData(data as CFData, nil)!)
    }

    /// Four flat colors, one in each corner, with an optional square of another color
    private static func quarters(square: (x: Int, y: Int, color: UInt32)? = nil) -> [UInt32] {
        var frame = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                frame[y * width + x] = switch (x < width / 2, y < height / 2) {
                case (true, true): 0xFFFF_3B30
                case (false, true): 0xFF34_C759
                case (true, false): 0xFF00_7AFF
                case (false, false): 0xFFFF_FFFF
                }
            }
        }
        if let square {
            for y in square.y..<(square.y + 4) {
                for x in square.x..<(square.x + 4) { frame[y * width + x] = square.color }
            }
        }
        return frame
    }

    static func pixels(of image: CGImage) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// The biggest difference in any channel
    private static func farthest(_ a: [UInt32], _ b: [UInt32]) -> Int {
        zip(a, b).map { a, b in
            [16, 8, 0].map { abs(Int(a >> $0 & 0xFF) - Int(b >> $0 & 0xFF)) }.max()!
        }.max() ?? 0
    }

    @Test func aFewColorsComeBackExactly() {
        let frame = Self.quarters()
        let gif = Self.write([(frame, 0)], until: 1)
        #expect(gif.data.prefix(6) == Data("GIF89a".utf8))
        #expect(gif.data.last == 0x3B)
        #expect(gif.frameCount == 1)
        #expect(gif.pixels(0) == frame)
    }

    @Test func loopsForever() {
        let gif = Self.write([(Self.quarters(), 0)], until: 1)
        let properties = CGImageSourceCopyProperties(gif.source, nil) as? [CFString: Any]
        let loops = (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount]
        #expect(loops as? Int == 0)
    }

    @Test func laterFramesDrawOverEarlierOnes() {
        let first = Self.quarters()
        let second = Self.quarters(square: (x: 18, y: 13, color: 0xFFFF_CC00))
        let third = Self.quarters(square: (x: 2, y: 20, color: 0xFF00_0000))
        let gif = Self.write([(first, 0), (second, 0.1), (third, 0.2)], until: 0.3)
        #expect(gif.frameCount == 3)
        #expect(gif.pixels(0) == first)
        #expect(gif.pixels(1) == second)
        #expect(gif.pixels(2) == third)
    }

    @Test func laterFramesCostLittleWhenLittleChanges() {
        let first = Self.quarters()
        let one = Self.write([(first, 0)], until: 1)
        let two = Self.write([(first, 0), (Self.quarters(square: (x: 18, y: 13, color: 0xFFFF_CC00)), 0.1)], until: 1)
        #expect(two.data.count - one.data.count < 60)
    }

    @Test func delaysFollowTheClock() {
        let gif = Self.write([(Self.quarters(), 10), (Self.quarters(square: (x: 0, y: 0, color: 0xFF00_0000)), 10.1),
                              (Self.quarters(square: (x: 8, y: 8, color: 0xFF00_0000)), 10.25)], until: 10.4)
        #expect(gif.delays == [0.1, 0.15, 0.15])
    }

    /// 15 frames a second don't divide into hundredths, so the rounding carries to the next frame
    @Test func roundingCarriesOver() {
        let frames = (0..<16).map { (Self.quarters(square: (x: $0, y: $0, color: 0xFF00_0000)), Double($0) / 15) }
        let gif = Self.write(frames, until: 16.0 / 15)
        let hundredths = gif.delays.map { Int(($0 * 100).rounded()) }
        #expect(hundredths.count == 16)
        #expect(hundredths.allSatisfy { $0 == 6 || $0 == 7 })
        #expect(hundredths.reduce(0, +) == 107)
    }

    @Test func aFrameTooSoonTakesThePlaceOfTheOneBefore() {
        let skipped = Self.quarters(square: (x: 0, y: 0, color: 0xFF00_0000))
        let shown = Self.quarters(square: (x: 4, y: 4, color: 0xFF00_0000))
        let last = Self.quarters(square: (x: 8, y: 8, color: 0xFF00_0000))
        let gif = Self.write([(skipped, 0), (shown, 0.01), (last, 0.1)], until: 0.2)
        #expect(gif.frameCount == 2)
        #expect(gif.pixels(0) == shown)
        #expect(gif.delays == [0.1, 0.1])
    }

    @Test func aFrameLikeTheOneUpOnlyMakesItStayLonger() {
        let still = Self.quarters()
        let moved = Self.quarters(square: (x: 4, y: 4, color: 0xFF00_0000))
        let gif = Self.write([(still, 0), (still, 0.1), (still, 0.2), (moved, 0.3)], until: 0.5)
        #expect(gif.delays == [0.3, 0.2])
    }

    /// As when a frame between them came too soon to show
    @Test func aFrameLikeTheLastWrittenStillCarriesItsDelay() {
        let still = Self.quarters()
        let blink = Self.quarters(square: (x: 4, y: 4, color: 0xFF00_0000))
        let gif = Self.write([(still, 0), (blink, 0.1), (still, 0.105), (blink, 0.3)], until: 0.4)
        #expect(gif.frameCount == 3)
        #expect(gif.pixels(1) == still)
        #expect(gif.pixels(2) == blink)
        #expect(gif.delays == [0.1, 0.2, 0.1])
    }

    @Test func theLastFrameHoldsTwoSecondsAtMost() {
        #expect(Self.write([(Self.quarters(), 0)], until: 30).delays == [2])
        #expect(Self.write([(Self.quarters(), 0)], until: 0.5).delays == [0.5])
    }

    @Test func framesOfTheWrongSizeAreLeftOut() {
        let gif = Self.write([([0xFF00_0000], 0), (Self.quarters(), 0.1)], until: 0.2)
        #expect(gif.frameCount == 1)
        #expect(gif.delays == [0.1])
    }

    /// Thousands of colors, which the palette's 255 stand in for
    @Test func manyColorsStayClose() {
        let width = 64, height = 64
        let frame = (0..<(width * height)).map { n in
            0xFF00_0000 | UInt32(n % width * 4) << 16 | UInt32(n / width * 4) << 8 | 0x80
        }
        let gif = Self.write([(frame, 0)], until: 1, width: width, height: height)
        #expect(Self.farthest(gif.pixels(0), frame) <= 16)
    }

    /// Noise fills the compression table many times over, so the decoder has to follow every clear code
    @Test func compressionSurvivesFullTables() {
        let width = 300, height = 200
        var seed: UInt32 = 12345
        // 255 colors 8 apart, so each has a palette entry to itself
        let palette = (0..<255).map { (n: Int) -> UInt32 in
            0xFF00_0040 | UInt32(n % 32 * 8) << 16 | UInt32(n / 32 * 8) << 8
        }
        let frame = (0..<(width * height)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return palette[Int(seed >> 16) % palette.count]
        }
        let gif = Self.write([(frame, 0)], until: 1, width: width, height: height)
        #expect(gif.pixels(0) == frame)
    }

    @Test func changedAreaIsTight() {
        let before = Self.quarters()
        #expect(GIFWriter.changedArea(before, from: before, width: Self.width, height: Self.height) == nil)
        var after = before
        after[5 * Self.width + 7] = 0xFF00_0000
        #expect(GIFWriter.changedArea(after, from: before, width: Self.width, height: Self.height)
                == GIFWriter.Area(x: 7, y: 5, width: 1, height: 1))
        after[20 * Self.width + 3] = 0xFF00_0000
        after[9 * Self.width + 30] = 0xFF00_0000
        #expect(GIFWriter.changedArea(after, from: before, width: Self.width, height: Self.height)
                == GIFWriter.Area(x: 3, y: 5, width: 28, height: 16))
    }
}
