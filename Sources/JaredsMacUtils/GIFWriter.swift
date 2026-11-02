import Foundation

/// An animated GIF, written a frame at a time as the frames come in, so a recording holds three frames at most however
/// long it runs. ImageIO's encoder keeps every frame until it finishes, which takes gigabytes for half a minute.
///
/// Each frame has its own palette, from a median cut of its colors. After the first, a frame covers only the area that
/// changed, with the pixels that didn't see-through, so what stays still stays sharp and costs next to nothing.
final class GIFWriter {
    /// A rectangle of pixels, from the top left
    struct Area: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// The most a frame in the GIF's first second stays up, in hundredths of a second: long enough to see where it
    /// starts, without the wait before you began scrolling, which would play every time the GIF goes round. Not just
    /// the first frame's: the app you're recording redraws as it gets the focus back, which can end that one early.
    static let longestStart = 100
    /// The most a frame in the middle stays up: a longer pause is cut to this
    static let longestPause = 200
    /// The most the last frame stays up: long enough to see where it ends, without the time it took to click Stop
    static let longestEnd = 200

    let width: Int
    let height: Int
    /// Frames written so far
    private(set) var frameCount = 0
    /// How long the frames written so far stay up, in hundredths of a second
    private(set) var length = 0

    private let output: (Data) -> Void
    private var start: Double?
    /// The newest frame, which waits for the next to say how long it stays up
    private var pending: [UInt32]?
    /// The last frame written, which the next only has to change
    private var shown: [UInt32]?
    private var isFinished = false
    private let colors = GIFColors()
    private let compressor = GIFCompressor()

    /// Writes the header straight away
    init(width: Int, height: Int, output: @escaping (Data) -> Void) {
        self.width = max(1, min(width, 0xFFFF))
        self.height = max(1, min(height, 0xFFFF))
        self.output = output
        // No global palette, then the loop forever extension
        var header: [UInt8] = Array("GIF89a".utf8)
        header += Self.le16(self.width)
        header += Self.le16(self.height)
        header += [0x70, 0, 0]
        header += [0x21, 0xFF, 0x0B]
        header += Array("NETSCAPE2.0".utf8)
        header += [0x03, 0x01, 0x00, 0x00, 0x00]
        output(Data(header))
    }

    /// - Parameters:
    ///   - frame: width × height pixels, top row first, each 0xAARRGGBB, as BGRA bytes read on a Mac
    ///   - time: when it was on screen, in seconds on any clock
    func add(_ frame: [UInt32], at time: Double) {
        guard !isFinished, frame.count == width * height else { return }
        guard let pending, let start else {
            start = time
            pending = frame
            return
        }
        if Self.same(frame, pending) { return }  // the one up stays up longer
        let due = Int(((time - start) * 100).rounded()) - length
        // Browsers stretch a delay under 2 hundredths to 10, so a frame that soon takes the place of the one before
        if due >= 2 {
            let delay = min(due, length < Self.longestStart ? Self.longestStart : Self.longestPause)
            // The time cut from a wait doesn't count towards the frames after it
            self.start = start + Double(due - delay) / 100
            write(pending, delay: delay)
        }
        self.pending = frame
    }

    /// Writes the last frame, up until `time`, and the end of the file
    func finish(at time: Double) {
        guard !isFinished else { return }
        isFinished = true
        if let pending, let start {
            let due = Int(((time - start) * 100).rounded()) - length
            write(pending, delay: min(max(due, 2), Self.longestEnd))
        }
        output(Data([0x3B]))
    }

    private func write(_ frame: [UInt32], delay: Int) {
        let delay = min(delay, 0xFFFF)
        let previous = shown
        let area = if let previous {
            // Nothing changed from the last frame written, as when one in between came too soon: one see-through
            // pixel carries the delay
            Self.changedArea(frame, from: previous, width: width, height: height)
                ?? Area(x: 0, y: 0, width: 1, height: 1)
        } else {
            Area(x: 0, y: 0, width: width, height: height)
        }
        let (palette, indices) = colors.indexed(frame, unchangedFrom: previous, in: area, width: width)
        let entries = palette.count + (previous == nil ? 0 : 1)
        var tableBits = 1
        while 1 << tableBits < entries { tableBits += 1 }

        // Drawn over what's there, with see-through pixels after the first frame
        let flags: UInt8 = previous == nil ? 0x04 : 0x05
        var bytes: [UInt8] = [0x21, 0xF9, 0x04, flags]
        bytes += Self.le16(delay)
        bytes += [UInt8(palette.count), 0x00, 0x2C]
        for value in [area.x, area.y, area.width, area.height] { bytes += Self.le16(value) }
        bytes.append(0x80 | UInt8(tableBits - 1))
        for color in palette {
            bytes += [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)]
        }
        bytes += [UInt8](repeating: 0, count: ((1 << tableBits) - palette.count) * 3)
        bytes += compressor.compress(indices, codeSize: max(2, tableBits))
        output(Data(bytes))

        shown = frame
        frameCount += 1
        length += delay
    }

    /// The smallest area around the pixels that differ, or nil if none do
    static func changedArea(_ frame: [UInt32], from previous: [UInt32], width: Int, height: Int) -> Area? {
        guard frame.count == width * height, previous.count == frame.count else { return nil }
        var top = -1, bottom = -1, left = width, right = -1
        frame.withUnsafeBufferPointer { now in
            previous.withUnsafeBufferPointer { before in
                guard let a = now.baseAddress, let b = before.baseAddress else { return }
                for y in 0..<height {
                    let row = y * width
                    guard memcmp(a + row, b + row, width * 4) != 0 else { continue }
                    if top < 0 { top = y }
                    bottom = y
                    var x = 0
                    while x < left, a[row + x] == b[row + x] { x += 1 }
                    left = x
                    x = width - 1
                    while x > right, a[row + x] == b[row + x] { x -= 1 }
                    right = x
                }
            }
        }
        guard top >= 0 else { return nil }
        return Area(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private static func same(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        a.count == b.count && a.withUnsafeBytes { a in
            b.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 }
        }
    }

    private static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
}

/// A frame's palette: a median cut of its colors at 5 bits a channel, each color the average of the pixels it stands
/// for. So a frame with few colors, like most of a screen, keeps them exactly.
final class GIFColors {
    private static let bins = 1 << 15

    private struct Box {
        var start: Int
        var end: Int
        var count = 0
        /// The channel its colors spread furthest along, 0 to 2 for red to blue, and how far
        var channel = 0
        var spread = 0
    }

    private var counts = [Int](repeating: 0, count: bins)
    private var reds = [Int](repeating: 0, count: bins)
    private var greens = [Int](repeating: 0, count: bins)
    private var blues = [Int](repeating: 0, count: bins)
    private var lookup = [UInt8](repeating: 0, count: bins)
    /// The bins with pixels in them
    private var used: [Int] = []

    /// The palette for the pixels in `area` that differ from `previous`, at most `limit` colors, each 0xRRGGBB, and
    /// every pixel's index into it, row by row. Pixels that don't differ get the index after the last color.
    func indexed(_ frame: [UInt32], unchangedFrom previous: [UInt32]?, in area: GIFWriter.Area, width: Int,
                 limit: Int = 255) -> (palette: [UInt32], indices: [UInt8]) {
        for bin in used {
            counts[bin] = 0
            reds[bin] = 0
            greens[bin] = 0
            blues[bin] = 0
        }
        used.removeAll(keepingCapacity: true)
        let rows = area.y..<(area.y + area.height), columns = area.x..<(area.x + area.width)
        let before = previous ?? frame
        let compares = previous != nil

        frame.withUnsafeBufferPointer { pixels in
            before.withUnsafeBufferPointer { before in
                for y in rows {
                    let row = y * width
                    for x in columns {
                        let pixel = pixels[row + x]
                        if compares, before[row + x] == pixel { continue }
                        let bin = Self.bin(pixel)
                        if counts[bin] == 0 { used.append(bin) }
                        counts[bin] += 1
                        reds[bin] += Int(pixel >> 16 & 0xFF)
                        greens[bin] += Int(pixel >> 8 & 0xFF)
                        blues[bin] += Int(pixel & 0xFF)
                    }
                }
            }
        }
        let palette = cut(to: limit)

        let seeThrough = UInt8(palette.count)
        var indices = [UInt8](repeating: seeThrough, count: area.width * area.height)
        frame.withUnsafeBufferPointer { pixels in
            before.withUnsafeBufferPointer { before in
                lookup.withUnsafeBufferPointer { lookup in
                    indices.withUnsafeMutableBufferPointer { indices in
                        var n = 0
                        for y in rows {
                            let row = y * width
                            for x in columns {
                                let pixel = pixels[row + x]
                                if !compares || before[row + x] != pixel { indices[n] = lookup[Self.bin(pixel)] }
                                n += 1
                            }
                        }
                    }
                }
            }
        }
        return (palette, indices)
    }

    /// Splits the colors into boxes, the busiest and widest first, until there are `limit`, then averages each box
    private func cut(to limit: Int) -> [UInt32] {
        var order = used
        var boxes: [Box] = []
        if order.count <= limit {
            boxes = order.indices.map { measure(Box(start: $0, end: $0 + 1), order) }
        } else {
            boxes = [measure(Box(start: 0, end: order.count), order)]
        }
        while boxes.count < limit {
            var best = -1, bestScore = 0
            for (index, box) in boxes.enumerated() where box.end - box.start > 1 && box.count * box.spread > bestScore {
                best = index
                bestScore = box.count * box.spread
            }
            guard best >= 0 else { break }
            let box = boxes[best]
            let shift = (2 - box.channel) * 5
            order[box.start..<box.end].sort { $0 >> shift & 31 < $1 >> shift & 31 }
            // At the median pixel, leaving a bin on each side
            var middle = box.start, total = 0
            repeat {
                total += counts[order[middle]]
                middle += 1
            } while middle < box.end - 1 && total * 2 < box.count
            boxes[best] = measure(Box(start: box.start, end: middle), order)
            boxes.append(measure(Box(start: middle, end: box.end), order))
        }

        return boxes.enumerated().map { index, box in
            var count = 0, red = 0, green = 0, blue = 0
            for bin in order[box.start..<box.end] {
                count += counts[bin]
                red += reds[bin]
                green += greens[bin]
                blue += blues[bin]
                lookup[bin] = UInt8(index)
            }
            let half = count / 2
            let r = UInt32((red + half) / count), g = UInt32((green + half) / count), b = UInt32((blue + half) / count)
            return r << 16 | g << 8 | b
        }
    }

    private func measure(_ box: Box, _ order: [Int]) -> Box {
        var box = box
        var low = [31, 31, 31], high = [0, 0, 0]
        for bin in order[box.start..<box.end] {
            box.count += counts[bin]
            for channel in 0..<3 {
                let value = bin >> ((2 - channel) * 5) & 31
                low[channel] = min(low[channel], value)
                high[channel] = max(high[channel], value)
            }
        }
        for channel in 0..<3 where high[channel] - low[channel] > box.spread {
            box.channel = channel
            box.spread = high[channel] - low[channel]
        }
        return box
    }

    /// The top 5 bits of red, green and blue
    private static func bin(_ pixel: UInt32) -> Int {
        // Typed one channel at a time: as one expression, the compiler gives up working out the literals' types
        let red: UInt32 = pixel >> 9 & 0x7C00
        let green: UInt32 = pixel >> 6 & 0x03E0
        let blue: UInt32 = pixel >> 3 & 0x001F
        return Int(red | green | blue)
    }
}

/// GIF's LZW compression, with the hash table of the classic compress: 5003 slots, probed from a hash of the code
/// and the next index
final class GIFCompressor {
    private static let slots = 5003

    private var keys = [Int32](repeating: -1, count: slots)
    private var codes = [UInt16](repeating: 0, count: slots)

    /// The image data: the code size, then the codes in blocks of up to 255 bytes, then an empty block
    func compress(_ indices: [UInt8], codeSize minimum: Int) -> [UInt8] {
        let clear = 1 << minimum, end = clear + 1
        var next = end + 1
        var size = minimum + 1
        var packed: [UInt8] = []
        packed.reserveCapacity(indices.count / 2 + 16)
        var bits = 0, count = 0
        func put(_ code: Int) {
            bits |= code << count
            count += size
            while count >= 8 {
                packed.append(UInt8(truncatingIfNeeded: bits))
                bits >>= 8
                count -= 8
            }
        }

        keys.withUnsafeMutableBufferPointer { keys in
            codes.withUnsafeMutableBufferPointer { codes in
                indices.withUnsafeBufferPointer { input in
                    keys.update(repeating: -1)
                    put(clear)
                    guard var prefix = input.first.map(Int.init) else { return put(end) }
                    for n in 1..<max(1, input.count) {
                        let index = Int(input[n])
                        let key = Int32(index << 12 | prefix)
                        var slot = index << 4 ^ prefix
                        if keys[slot] == key {
                            prefix = Int(codes[slot])
                            continue
                        }
                        if keys[slot] >= 0 {
                            let step = slot == 0 ? 1 : Self.slots - slot
                            var found = false
                            repeat {
                                slot -= step
                                if slot < 0 { slot += Self.slots }
                                if keys[slot] == key {
                                    found = true
                                    break
                                }
                            } while keys[slot] >= 0
                            if found {
                                prefix = Int(codes[slot])
                                continue
                            }
                        }
                        put(prefix)
                        if next == 4096 {
                            // The table's full: start a new one, as a decoder will on the clear code
                            put(clear)
                            keys.update(repeating: -1)
                            next = end + 1
                            size = minimum + 1
                        } else {
                            // Wider codes from the first that needs them, which is when a decoder widens too
                            if next >= 1 << size { size += 1 }
                            codes[slot] = UInt16(next)
                            keys[slot] = key
                            next += 1
                        }
                        prefix = index
                    }
                    put(prefix)
                    put(end)
                }
            }
        }
        if count > 0 { packed.append(UInt8(truncatingIfNeeded: bits)) }

        var data = [UInt8(minimum)]
        data.reserveCapacity(packed.count + packed.count / 255 + 3)
        var start = 0
        while start < packed.count {
            let length = min(255, packed.count - start)
            data.append(UInt8(length))
            data += packed[start..<(start + length)]
            start += length
        }
        data.append(0)
        return data
    }
}
