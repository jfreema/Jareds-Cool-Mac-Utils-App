import Testing
@testable import Yafie

struct LowPowerSettingTests {
    /// `pmset -g custom` on a MacBook Air, trimmed
    private let macBookAir = """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         0
         standby              1
         displaysleep         20
        AC Power:
         Sleep On Power Button 1
         lowpowermode         0
         standby              1
         displaysleep         60
        """

    @Test func readsEachPowerSource() {
        #expect(LowPowerSetting(pmset: macBookAir)
                    == LowPowerSetting(key: "lowpowermode", values: [.battery: 0, .adapter: 0]))
    }

    @Test func usesPowerModeOnMacsWithHighPowerMode() {
        let output = """
            Battery Power:
             powermode            0
             sleep                1
            AC Power:
             powermode            2
             sleep                1
            """
        #expect(LowPowerSetting(pmset: output) == LowPowerSetting(key: "powermode", values: [.battery: 0, .adapter: 2]))
    }

    @Test func aMacWithoutABattery() {
        let output = """
            AC Power:
             lowpowermode         1
             sleep                1
            """
        #expect(LowPowerSetting(pmset: output) == LowPowerSetting(key: "lowpowermode", values: [.adapter: 1]))
    }

    @Test func nilWithoutLowPowerMode() {
        #expect(LowPowerSetting(pmset: "AC Power:\n sleep                1\n") == nil)
        #expect(LowPowerSetting(pmset: "") == nil)
    }

    @Test func savesOnlyTheSourcesItTurnsOn() {
        let setting = LowPowerSetting(key: "lowpowermode", values: [.battery: 1, .adapter: 0])
        #expect(setting.whereOff == LowPowerSetting(key: "lowpowermode", values: [.adapter: 0]))
        #expect(setting.inLowPower.whereOff == nil)
    }

    @Test func putsHighPowerModeBack() {
        let setting = LowPowerSetting(key: "powermode", values: [.battery: 0, .adapter: 2])
        #expect(setting.whereOff == setting)
        #expect(setting.inLowPower == LowPowerSetting(key: "powermode", values: [.battery: 1, .adapter: 1]))
        #expect(setting.commands == [["-b", "powermode", "0"], ["-c", "powermode", "2"]])
    }

    @Test func survivesARestartAsText() {
        let setting = LowPowerSetting(key: "lowpowermode", values: [.battery: 0, .adapter: 0])
        #expect(setting.description == "lowpowermode -b 0 -c 0")
        #expect(LowPowerSetting(setting.description) == setting)
        #expect(LowPowerSetting("powermode -c 2") == LowPowerSetting(key: "powermode", values: [.adapter: 2]))
    }

    @Test(arguments: ["", "1", "lowpowermode", "lowpowermode -b", "lowpowermode -a 0", "lowpowermode -b x",
                      "sleep -b 0"])
    func ignoresAnythingElse(text: String) {
        #expect(LowPowerSetting(text) == nil)
    }
}
