import Darwin
import Foundation
import Testing
@testable import Yafie

struct SleepSettingTests {
    /// As sudo does, matching the arguments like a shell pattern
    private func allowed(_ arguments: [String]) -> Bool {
        let command = (["/usr/bin/pmset"] + arguments).joined(separator: " ")
        return SleepSetting.allowedCommands.contains { fnmatch($0, command, 0) == 0 }
    }

    @Test func ruleAllowsEveryCommandYafieRuns() {
        #expect(allowed(["disablesleep", "1"]))
        #expect(allowed(["disablesleep", "0"]))
        for key in LowPowerSetting.keys {
            for value in 0...2 {
                for command in LowPowerSetting(key: key, values: [.battery: value, .adapter: value]).commands {
                    #expect(allowed(command))
                }
            }
        }
    }

    @Test(arguments: [["disablesleep", "2"], ["-a", "lowpowermode", "1"], ["-b", "lowpowermode", "3"],
                      ["-b", "lowpowermode", "10"], ["-b", "lowpowermode", "1", "-c", "lowpowermode", "1"],
                      ["-b", "sleep", "0"], ["-g"]])
    func ruleAllowsNothingElse(arguments: [String]) {
        #expect(!allowed(arguments))
    }

    @Test func ruleIsValidSudoers() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("yafie-rule-\(UUID().uuidString)")
        try (SleepSetting.rule + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Shell.run("/usr/sbin/visudo", ["-cqf", file.path]).status == 0)
    }
}
