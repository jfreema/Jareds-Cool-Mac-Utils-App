import Foundation

/// Low Power Mode for each power source, as `pmset -g custom` lists it. Changed through the sudoers rule.
struct LowPowerSetting: Equatable, Sendable, CustomStringConvertible {
    /// pmset's flags for them
    enum Source: String, CaseIterable, Sendable {
        case battery = "-b", adapter = "-c"
    }

    /// Low Power, under either key
    static let on = 1
    /// powermode on Macs with High Power Mode too, where 0 is Automatic and 2 High Power. First if both show up.
    static let keys = ["powermode", "lowpowermode"]

    let key: String
    /// For each power source the Mac has
    let values: [Source: Int]

    init(key: String, values: [Source: Int]) {
        self.key = key
        self.values = values
    }

    /// The sources where it's off, which is what to put back after turning it on. Nil if it's on for all.
    var whereOff: LowPowerSetting? {
        let off = values.filter { $0.value != Self.on }
        return off.isEmpty ? nil : LowPowerSetting(key: key, values: off)
    }

    /// The same sources, in Low Power Mode
    var inLowPower: LowPowerSetting {
        LowPowerSetting(key: key, values: values.mapValues { _ in Self.on })
    }

    /// pmset's arguments, one source at a time
    var commands: [[String]] {
        Source.allCases.compactMap { source in values[source].map { [source.rawValue, key, String($0)] } }
    }

    /// Like "lowpowermode -b 0 -c 0", for the watchdog and for after a restart
    var description: String {
        ([key] + Source.allCases.compactMap { source in values[source].map { "\(source.rawValue) \($0)" } })
            .joined(separator: " ")
    }

    /// From its description
    init?(_ text: some StringProtocol) {
        let fields = String(text).split(separator: " ").map(String.init)
        guard let key = fields.first, Self.keys.contains(key), fields.count >= 3, fields.count % 2 == 1 else {
            return nil
        }
        var values: [Source: Int] = [:]
        for index in stride(from: 1, to: fields.count, by: 2) {
            guard let source = Source(rawValue: fields[index]), let value = Int(fields[index + 1]) else { return nil }
            values[source] = value
        }
        self.init(key: key, values: values)
    }

    /// From `pmset -g custom`, which lists each power source's settings under a heading. Nil without Low Power Mode.
    init?(pmset output: String) {
        var source: Source?
        var found: [String: [Source: Int]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if !line.hasPrefix(" ") {
                source = switch line {
                case "Battery Power:": .battery
                case "AC Power:": .adapter
                default: nil
                }
            } else if let source, fields.count == 2, Self.keys.contains(String(fields[0])),
                      let value = Int(fields[1]) {
                found[String(fields[0]), default: [:]][source] = value
            }
        }
        guard let key = Self.keys.first(where: { found[$0] != nil }), let values = found[key] else { return nil }
        self.init(key: key, values: values)
    }
}

extension LowPowerSetting {
    /// Nil without Low Power Mode
    static func current() async -> LowPowerSetting? {
        await SleepSetting.queued { read() }
    }

    /// True if every source took
    static func apply(_ setting: LowPowerSetting) async -> Bool {
        await SleepSetting.queued { write(setting) }
    }

    /// Runs after queued writes
    static func applySynchronously(_ setting: LowPowerSetting) -> Bool {
        SleepSetting.queue.sync { write(setting) }
    }

    /// Tests by rewriting a current value. True without Low Power Mode, since there's nothing to change.
    static func isPasswordFree() async -> Bool {
        await SleepSetting.queued {
            guard let arguments = read()?.commands.first else { return true }
            return run(arguments)
        }
    }

    private static func read() -> LowPowerSetting? {
        let result = Shell.run("/usr/bin/pmset", ["-g", "custom"])
        return result.status == 0 ? LowPowerSetting(pmset: result.output) : nil
    }

    /// Every source, even after one fails
    private static func write(_ setting: LowPowerSetting) -> Bool {
        !setting.commands.map(run).contains(false)
    }

    private static func run(_ arguments: [String]) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + arguments).status == 0
    }
}
