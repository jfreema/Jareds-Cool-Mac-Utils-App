@preconcurrency import Darwin  // mach_task_self_, which Swift 6 won't read otherwise
import Foundation
import IOKit
import os

let temperatureLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "jaredsmacutils", category: "temp")

// MARK: Reading

/// How hot the inside of the Mac is
enum HeatLevel: Int, Comparable {
    case cool, normal, warm, hot, overheating, critical

    static func < (lhs: HeatLevel, rhs: HeatLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// From the processor's temperature, in °F as the menu shows it: cool below 98, normal from 98, warm from 155, hot
    /// from 182, overheating from 205 and critical above 225
    static func level(fahrenheit: Int) -> HeatLevel {
        switch fahrenheit {
        case ..<98: .cool
        case ..<155: .normal
        case ..<182: .warm
        case ..<205: .hot
        case ..<226: .overheating
        default: .critical
        }
    }

    /// From macOS's own word on it, which counts the case and the battery too, or nil when it says nothing's wrong.
    /// From serious on, macOS slows the Mac down to cool it off.
    static func level(_ state: ProcessInfo.ThermalState) -> HeatLevel? {
        switch state {
        case .nominal: nil
        case .fair: .warm
        case .serious: .hot
        case .critical: .overheating
        @unknown default: nil
        }
    }
}

/// The inside of the Mac, as the menu shows it
struct TemperatureReading: Equatable {
    /// The processor's cores, averaged. Nil when the Mac's sensors can't be read, as in a virtual machine.
    var celsius: Double?
    var thermalState: ProcessInfo.ThermalState

    var fahrenheit: Int? { celsius.map { Int(($0 * 9 / 5 + 32).rounded()) } }

    /// The hotter of the two. macOS saying nothing's wrong doesn't make a cool Mac normal.
    var level: HeatLevel {
        let macOS = HeatLevel.level(thermalState)
        guard let fahrenheit else { return macOS ?? .normal }
        let measured = HeatLevel.level(fahrenheit: fahrenheit)
        return max(measured, macOS ?? measured)
    }

    /// For the tooltip: where it comes from, and what the levels mean
    var explanation: String {
        var text = "This Mac's temperature sensors can't be read, so this is how hot macOS says it is."
        if fahrenheit != nil {
            text = "The processor, the hottest part inside your Mac: cool below 98°F, normal from 98°F, warm from "
                + "155°F, hot from 182°F, overheating from 205°F, critical above 225°F."
        }
        if let macOS = HeatLevel.level(thermalState), macOS >= .hot {
            text += " macOS is slowing your Mac down to cool it off."
        }
        return text
    }

    /// For VoiceOver
    var spoken: String {
        let word = switch level {
        case .cool: "cool"
        case .normal: "normal"
        case .warm: "warm"
        case .hot: "hot"
        case .overheating: "overheating"
        case .critical: "critical"
        }
        return fahrenheit.map { "\($0) degrees Fahrenheit, \(word)" } ?? "can't be read, \(word)"
    }
}

// MARK: Which sensors

/// A key the SMC has read, in °C
struct SMCReading: Equatable {
    let key: String
    let type: String
    let celsius: Double
}

/// Which of the SMC's keys and HID's sensors are the processor's, and its temperature from them. Apple doesn't
/// document them, and they change with each chip, so these are the names Stats and macmon go by.
enum ProcessorTemperature {
    /// Below this is a sensor that's off, and above it one that's broken
    static let plausible = 5.0...130.0
    /// The types the SMC keeps temperatures in: a float on Apple silicon, signed 7.8 fixed point on Intel
    static let types: Set<String> = ["flt ", "sp78"]

    /// Apple silicon's cores, as floats: Tp (M1, M2, M4 and later), Te (efficiency cores, M3 and M4), Tf0 and Tf4
    /// (M3's performance cores)
    static func isAppleSiliconCore(_ key: String) -> Bool {
        key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf0") || key.hasPrefix("Tf4")
    }

    /// Intel's cores, in fixed point: TC0C, TC1C and on, or TC0c, TC1c and on
    static func isIntelCore(_ key: String) -> Bool {
        let letters = Array(key)
        guard letters.count == 4, key.hasPrefix("TC"), let digit = letters[2].asciiValue else { return false }
        let isDigit = (48...57).contains(digit)  // 0 to 9
        return isDigit && (letters[3] == "C" || letters[3] == "c")
    }

    /// Intel Macs without a key for each core: the package, the die, then beside it
    static let intelFallbacks = ["TCXC", "TC0D", "TC0E", "TC0F", "TC0P", "TC0H"]

    static func isCandidate(_ key: String) -> Bool {
        isAppleSiliconCore(key) || isIntelCore(key) || intelFallbacks.contains(key)
    }

    /// A key's value in °C
    static func celsius(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            // Little-endian
            let bits = bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count == 2:
            // Big-endian, with 8 bits after the point
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: bits)) / 256
        default:
            return nil
        }
    }

    /// The cores averaged, Apple silicon's or Intel's, or else the best of Intel's other keys
    static func celsius(smc readings: [SMCReading]) -> Double? {
        let readings = readings.filter { plausible.contains($0.celsius) }
        if let cores = average(readings.filter { $0.type == "flt " && isAppleSiliconCore($0.key) }.map(\.celsius)) {
            return cores
        }
        if let cores = average(readings.filter { $0.type == "sp78" && isIntelCore($0.key) }.map(\.celsius)) {
            return cores
        }
        return intelFallbacks.lazy.compactMap { key in readings.first { $0.key == key }?.celsius }.first
    }

    /// M1's CPU clusters averaged, or else the chip's die sensors, which later chips keep
    static func celsius(hid sensors: [(name: String, celsius: Double)]) -> Double? {
        let sensors = sensors.filter { plausible.contains($0.celsius) }
        let clusters = sensors.filter { $0.name.hasPrefix("pACC MTR Temp") || $0.name.hasPrefix("eACC MTR Temp") }
        return average(clusters.map(\.celsius)) ?? average(sensors.filter { $0.name.contains("tdie") }.map(\.celsius))
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

// MARK: SMC

/// A four-letter SMC name, like TC0P, as the number the SMC knows it by
enum FourCC {
    static func number(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func text(_ number: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: number >> $0) }, as: UTF8.self)
    }
}

/// A request to the SMC, or its answer, laid out as the kernel's SMCKeyData_t: 80 bytes, with the key at 0, a key's
/// size and type at 28 and 32, the result at 40, the command at 42, an index at 44, and the value from 48. Its size is
/// 32 bits, though C's IOByteCount is 64 on Apple silicon, which is what broke the old smc.c there.
struct SMCMessage {
    static let size = 80

    var bytes = [UInt8](repeating: 0, count: SMCMessage.size)

    var key: UInt32 {
        get { word(at: 0) }
        set { setWord(newValue, at: 0) }
    }
    var dataSize: UInt32 {
        get { word(at: 28) }
        set { setWord(newValue, at: 28) }
    }
    var dataType: UInt32 {
        get { word(at: 32) }
        set { setWord(newValue, at: 32) }
    }
    /// 0 when it worked
    var result: UInt8 {
        get { bytes[40] }
        set { bytes[40] = newValue }
    }
    var command: UInt8 {
        get { bytes[42] }
        set { bytes[42] = newValue }
    }
    var index: UInt32 {
        get { word(at: 44) }
        set { setWord(newValue, at: 44) }
    }

    func value(size: Int) -> [UInt8] {
        Array(bytes[48..<(48 + min(max(size, 0), 32))])
    }

    /// In the Mac's own byte order, which is little-endian on Apple silicon and Intel alike
    private func word(at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private mutating func setWord(_ word: UInt32, at offset: Int) {
        for byte in 0..<4 {
            bytes[offset + byte] = UInt8(truncatingIfNeeded: word >> (8 * byte))
        }
    }
}

/// The System Management Controller, which keeps the Mac's sensors, read through the same calls as Stats and macmon.
/// Reading needs no password or permission. Only used on the thermometer's queue.
final class SMC {
    struct Key: Equatable {
        let name: String
        let type: String
        let size: Int
    }

    private var connection: io_connect_t = 0

    /// Nil without one, as in a virtual machine
    init?() {
        let services = Self.services()
        defer { for service in services { IOObjectRelease(service.object) } }
        // Apple silicon has several, and the keys are behind AppleSMCKeysEndpoint. An Intel Mac has the one.
        guard let service = services.first(where: { $0.name == "AppleSMCKeysEndpoint" }) ?? services.first,
              IOServiceOpen(service.object, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Each AppleSMC service, with its name
    static func services() -> [(object: io_object_t, name: String)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [(object: io_object_t, name: String)] = []
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else { break }
            var name = [CChar](repeating: 0, count: 128)  // io_name_t
            let found = IORegistryEntryGetName(object, &name) == KERN_SUCCESS
            let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            services.append((object, found ? text : ""))
        }
        return services
    }

    /// Its type and size, or nil if this Mac doesn't have it
    func key(_ name: String) -> Key? {
        var request = SMCMessage()
        request.key = FourCC.number(name)
        request.command = 9  // key info
        guard let answer = call(request) else { return nil }
        return Key(name: name, type: FourCC.text(answer.dataType), size: Int(answer.dataSize))
    }

    func value(_ key: Key) -> [UInt8]? {
        guard (1...32).contains(key.size) else { return nil }
        var request = SMCMessage()
        request.key = FourCC.number(key.name)
        request.dataSize = UInt32(key.size)
        request.command = 5  // read bytes
        return call(request)?.value(size: key.size)
    }

    /// The names of all its keys, a thousand or two
    func allKeys() -> [String] {
        guard let count = key("#KEY"), let bytes = value(count), bytes.count == 4 else { return [] }
        let total = bytes.reduce(0) { $0 << 8 | Int($1) }  // big-endian
        return (0..<min(total, 20_000)).compactMap { index -> String? in
            var request = SMCMessage()
            request.command = 8  // key at an index
            request.index = UInt32(index)
            return call(request).map { FourCC.text($0.key) }
        }
    }

    /// One request, and its answer if the SMC took it
    private func call(_ request: SMCMessage) -> SMCMessage? {
        var answer = SMCMessage()
        var answerSize = SMCMessage.size
        let status = request.bytes.withUnsafeBytes { input in
            answer.bytes.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, SMCMessage.size, output.baseAddress,
                                          &answerSize)
            }
        }
        return status == KERN_SUCCESS && answer.result == 0 ? answer : nil
    }
}

// MARK: HID

/// Apple silicon's temperature sensors as HID services, through private calls in IOKit that monitoring apps have used
/// since the M1, found with dlsym. Only for when the SMC has nothing.
enum HIDTemperatures {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatching = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias FloatValue = @convention(c) (OpaquePointer, Int32) -> Double

    private struct Calls {
        let createClient: CreateClient
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let floatValue: FloatValue
    }

    private static let calls: Calls? = {
        func find<Call>(_ name: String, _ type: Call.Type) -> Call? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
        }
        guard let createClient = find("IOHIDEventSystemClientCreate", CreateClient.self),
              let setMatching = find("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = find("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = find("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = find("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = find("IOHIDEventGetFloatValue", FloatValue.self) else { return nil }
        return Calls(createClient: createClient, setMatching: setMatching, copyServices: copyServices,
                     copyProperty: copyProperty, copyEvent: copyEvent, floatValue: floatValue)
    }()

    /// kIOHIDEventTypeTemperature
    private static let temperatureEvent: Int64 = 15

    /// Each sensor's name and °C
    static func read() -> [(name: String, celsius: Double)] {
        guard let calls, let client = calls.createClient(kCFAllocatorDefault) else { return [] }
        defer { release(client) }
        // kHIDPage_AppleVendor and kHIDUsage_AppleVendor_TemperatureSensor
        _ = calls.setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = calls.copyServices(client)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(services)).compactMap { index -> (name: String, celsius: Double)? in
            guard let pointer = CFArrayGetValueAtIndex(services, index) else { return nil }
            let service = OpaquePointer(pointer)
            guard let name = calls.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = calls.copyEvent(service, temperatureEvent, 0, 0) else { return nil }
            defer { release(event) }
            return (name, calls.floatValue(event, Int32(temperatureEvent << 16)))
        }
    }

    private static func release(_ object: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(object)).release()
    }
}

// MARK: Thermometer

/// Reads the processor's temperature on a queue of its own, since the SMC can take a moment and the main thread runs
/// lid sleep. It finds the SMC's keys once, on the first reading.
final class Thermometer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jaredsmacutils.temperature")
    // Only used on the queue
    private var smc: SMC?
    private var keys: [SMC.Key]?
    private var source: String?

    /// °C, or nil if the sensors can't be read
    func read(then done: @escaping @MainActor (Double?) -> Void) {
        queue.async {
            let celsius = self.celsius()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(celsius) } }
        }
    }

    private func celsius() -> Double? {
        let keys = self.keys ?? findKeys()
        if let smc, let celsius = ProcessorTemperature.celsius(smc: readings(keys, from: smc)) {
            say("Reading the processor's temperature from \(keys.count) SMC keys")
            return celsius
        }
        if let celsius = ProcessorTemperature.celsius(hid: HIDTemperatures.read()) {
            say("Reading the processor's temperature from HID sensors")
            return celsius
        }
        say("Can't read the processor's temperature: no SMC keys or HID sensors for it")
        return nil
    }

    /// Opens the SMC and picks out the processor's keys from all of them
    private func findKeys() -> [SMC.Key] {
        smc = SMC()
        let keys = (smc?.allKeys() ?? []).filter(ProcessorTemperature.isCandidate)
            .compactMap { smc?.key($0) }
            .filter { ProcessorTemperature.types.contains($0.type) }
        self.keys = keys
        let names = keys.map(\.name).joined(separator: " ")
        let found = smc == nil ? "No SMC" : "SMC keys for the processor:"
        temperatureLogger.notice("\(found, privacy: .public) \(names, privacy: .public)")
        return keys
    }

    private func readings(_ keys: [SMC.Key], from smc: SMC) -> [SMCReading] {
        keys.compactMap { key in
            smc.value(key).flatMap { ProcessorTemperature.celsius(type: key.type, bytes: $0) }
                .map { SMCReading(key: key.name, type: key.type, celsius: $0) }
        }
    }

    /// Logs where the readings come from when that changes
    private func say(_ message: String) {
        guard message != source else { return }
        source = message
        temperatureLogger.notice("\(message, privacy: .public)")
    }

    #if DEBUG
    /// Everything it finds, for trying it on a Mac: --temperature
    func describe(then done: @escaping @MainActor (String) -> Void) {
        queue.async {
            let services = SMC.services().map { service -> String in
                IOObjectRelease(service.object)
                return service.name
            }
            var lines = ["SMC services: " + services.joined(separator: ", ")]
            let keys = self.keys ?? self.findKeys()
            if let smc = self.smc {
                let all = smc.allKeys()
                lines.append("SMC open, \(all.count) keys")
                let temperatures = all.filter { $0.hasPrefix("T") }.compactMap { smc.key($0) }
                    .filter { ProcessorTemperature.types.contains($0.type) }
                lines.append("Temperature keys: " + self.readings(temperatures, from: smc)
                    .map { "\($0.key)=\(String(format: "%.1f", $0.celsius))" }.joined(separator: " "))
                lines.append("Processor keys: " + keys.map(\.name).joined(separator: " "))
                let celsius = ProcessorTemperature.celsius(smc: self.readings(keys, from: smc))
                lines.append("From the SMC: " + (celsius.map { String(format: "%.1f °C", $0) } ?? "nothing"))
            } else {
                lines.append("SMC not open")
            }
            let sensors = HIDTemperatures.read()
            lines.append("HID sensors: " + sensors.map { "\($0.name)=\(String(format: "%.1f", $0.celsius))" }
                .joined(separator: ", "))
            let fromHID = ProcessorTemperature.celsius(hid: sensors)
            lines.append("From HID: " + (fromHID.map { String(format: "%.1f °C", $0) } ?? "nothing"))
            let state = ProcessInfo.processInfo.thermalState
            let reading = TemperatureReading(celsius: self.celsius(), thermalState: state)
            let shown = reading.fahrenheit.map { "\($0)°F" } ?? "none"
            lines.append("Reading: \(shown), \(reading.spoken), thermal state \(state.rawValue)")
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }
    #endif
}
