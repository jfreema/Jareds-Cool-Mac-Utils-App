import Foundation
import Testing
@testable import JaredsMacUtils

/// A float as the SMC keeps it on Apple silicon: 4 bytes, little-endian
private func float(_ value: Float) -> [UInt8] {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
}

private func apple(_ key: String, _ celsius: Double) -> SMCReading {
    SMCReading(key: key, type: "flt ", celsius: celsius)
}

private func intel(_ key: String, _ celsius: Double) -> SMCReading {
    SMCReading(key: key, type: "sp78", celsius: celsius)
}

struct HeatLevelTests {
    @Test func startsAtRoundNumbersOfDegreesFahrenheit() {
        #expect(HeatLevel.level(fahrenheit: 60) == .cool)
        #expect(HeatLevel.level(fahrenheit: 97) == .cool)
        #expect(HeatLevel.level(fahrenheit: 98) == .normal)
        #expect(HeatLevel.level(fahrenheit: 154) == .normal)
        #expect(HeatLevel.level(fahrenheit: 155) == .warm)
        #expect(HeatLevel.level(fahrenheit: 181) == .warm)
        #expect(HeatLevel.level(fahrenheit: 182) == .hot)
        #expect(HeatLevel.level(fahrenheit: 204) == .hot)
        #expect(HeatLevel.level(fahrenheit: 205) == .overheating)
        #expect(HeatLevel.level(fahrenheit: 225) == .overheating)
        #expect(HeatLevel.level(fahrenheit: 226) == .critical)
        #expect(HeatLevel.level(fahrenheit: 260) == .critical)
    }

    @Test func followsMacOSsThermalState() {
        // Nothing wrong says nothing, so a cool Mac stays cool
        #expect(HeatLevel.level(ProcessInfo.ThermalState.nominal) == nil)
        #expect(HeatLevel.level(ProcessInfo.ThermalState.fair) == .warm)
        #expect(HeatLevel.level(ProcessInfo.ThermalState.serious) == .hot)
        #expect(HeatLevel.level(ProcessInfo.ThermalState.critical) == .overheating)
    }
}

struct TemperatureReadingTests {
    /// Jared, on November 10, 2026: "check only every 10 seconds on the mac"
    @Test func isReadEveryTenSecondsAndNoSooner() {
        #expect(TemperatureReading.every == 10)
        #expect(TemperatureReading.isDue(after: nil))
        #expect(!TemperatureReading.isDue(after: 0))
        #expect(!TemperatureReading.isDue(after: 9.9))
        #expect(TemperatureReading.isDue(after: 10))
        #expect(TemperatureReading.isDue(after: 3600))
        // The clock was set back
        #expect(TemperatureReading.isDue(after: -5))
    }

    @Test func showsWholeDegreesFahrenheit() {
        #expect(TemperatureReading(celsius: 41, thermalState: .nominal).fahrenheit == 106)
        #expect(TemperatureReading(celsius: 100, thermalState: .nominal).fahrenheit == 212)
        #expect(TemperatureReading(celsius: 71.1, thermalState: .nominal).fahrenheit == 160)
        #expect(TemperatureReading(celsius: nil, thermalState: .nominal).fahrenheit == nil)
    }

    @Test func saysTheHotterOfTheTemperatureAndMacOS() {
        #expect(TemperatureReading(celsius: 41, thermalState: .nominal).level == .normal)
        #expect(TemperatureReading(celsius: 80, thermalState: .nominal).level == .warm)
        #expect(TemperatureReading(celsius: 100, thermalState: .fair).level == .overheating)
        // macOS also counts the case and the battery
        #expect(TemperatureReading(celsius: 41, thermalState: .serious).level == .hot)
        #expect(TemperatureReading(celsius: 41, thermalState: .critical).level == .overheating)
    }

    @Test func aCoolMacIsCoolUnlessMacOSSaysOtherwise() {
        #expect(TemperatureReading(celsius: 30, thermalState: .nominal).level == .cool)
        #expect(TemperatureReading(celsius: 30, thermalState: .fair).level == .warm)
        #expect(TemperatureReading(celsius: 110, thermalState: .nominal).level == .critical)
        // macOS can't make it any less hot
        #expect(TemperatureReading(celsius: 110, thermalState: .critical).level == .critical)
    }

    @Test func withoutSensorsMacOSSaysHowHot() {
        #expect(TemperatureReading(celsius: nil, thermalState: .nominal).level == .normal)
        #expect(TemperatureReading(celsius: nil, thermalState: .fair).level == .warm)
        #expect(TemperatureReading(celsius: nil, thermalState: .nominal).explanation.contains("can't be read"))
    }

    @Test func saysWhenMacOSIsSlowingTheMacDown() {
        #expect(!TemperatureReading(celsius: 90, thermalState: .fair).explanation.contains("slowing"))
        #expect(TemperatureReading(celsius: 90, thermalState: .serious).explanation.contains("slowing"))
    }

    @Test func speaksTheTemperatureAndHowHot() {
        #expect(TemperatureReading(celsius: 41, thermalState: .nominal).spoken == "106 degrees Fahrenheit, normal")
        #expect(TemperatureReading(celsius: 30, thermalState: .nominal).spoken == "86 degrees Fahrenheit, cool")
        #expect(TemperatureReading(celsius: 110, thermalState: .nominal).spoken == "230 degrees Fahrenheit, critical")
        #expect(TemperatureReading(celsius: nil, thermalState: .fair).spoken == "can't be read, warm")
    }
}

struct SMCMessageTests {
    @Test func isLaidOutAsTheKernelsStruct() {
        var message = SMCMessage()
        message.key = FourCC.number("TC0P")
        message.dataSize = 2
        message.dataType = FourCC.number("sp78")
        message.command = 5
        message.index = 0x0102_0304
        #expect(message.bytes.count == 80)
        // The Mac's own byte order: little-endian
        #expect(Array(message.bytes[0..<4]) == [0x50, 0x30, 0x43, 0x54])
        #expect(Array(message.bytes[28..<32]) == [2, 0, 0, 0])
        #expect(Array(message.bytes[32..<36]) == Array("87ps".utf8))
        #expect(message.bytes[42] == 5)
        #expect(Array(message.bytes[44..<48]) == [4, 3, 2, 1])
        // Nothing else
        let written: Set<Int> = [0, 1, 2, 3, 28, 32, 33, 34, 35, 42, 44, 45, 46, 47]
        let others = message.bytes.indices.filter { !written.contains($0) }.map { message.bytes[$0] }
        #expect(others.allSatisfy { $0 == 0 })
    }

    @Test func readsAnAnswer() {
        var answer = SMCMessage()
        answer.bytes[40] = 0x84  // key not found
        answer.bytes[48] = 0x2e
        answer.bytes[49] = 0x80
        #expect(answer.result == 0x84)
        #expect(answer.value(size: 2) == [0x2e, 0x80])
        #expect(answer.value(size: 99).count == 32)
    }

    @Test func namesAreFourLetters() {
        #expect(FourCC.number("TC0P") == 0x5443_3050)
        #expect(FourCC.text(0x5443_3050) == "TC0P")
        #expect(FourCC.text(FourCC.number("flt ")) == "flt ")
        #expect(FourCC.text(FourCC.number("#KEY")) == "#KEY")
    }
}

struct ProcessorTemperatureTests {
    @Test func readsAppleSiliconFloats() {
        #expect(ProcessorTemperature.celsius(type: "flt ", bytes: float(42.5)) == 42.5)
        #expect(ProcessorTemperature.celsius(type: "flt ", bytes: [0, 0]) == nil)
    }

    @Test func readsIntelFixedPoint() {
        #expect(ProcessorTemperature.celsius(type: "sp78", bytes: [0x2e, 0x80]) == 46.5)
        #expect(ProcessorTemperature.celsius(type: "sp78", bytes: [0xff, 0x00]) == -1)
        #expect(ProcessorTemperature.celsius(type: "ui16", bytes: [0x2e, 0x80]) == nil)
    }

    @Test func knowsEachChipsCoreKeys() {
        for key in ["Tp01", "Tp0T", "Tp1h", "Te05", "Te0S", "Tf04", "Tf4E", "Tp0y"] {
            #expect(ProcessorTemperature.isAppleSiliconCore(key), "\(key)")
        }
        // M3's graphics, any chip's graphics and memory, and Intel's keys
        for key in ["Tf14", "Tf2A", "Tg0f", "Tm02", "TC0P", "TB0T"] {
            #expect(!ProcessorTemperature.isAppleSiliconCore(key), "\(key)")
        }
        for key in ["TC0C", "TC1C", "TC7c"] {
            #expect(ProcessorTemperature.isIntelCore(key), "\(key)")
        }
        for key in ["TCXC", "TCGC", "TC0P", "TC0D", "Tp01", "TC1"] {
            #expect(!ProcessorTemperature.isIntelCore(key), "\(key)")
        }
    }

    @Test func averagesAppleSiliconsCores() {
        let readings = [apple("Tp01", 50), apple("Tp05", 60), apple("Te05", 40), apple("Tg0f", 90), apple("Tm02", 30)]
        #expect(ProcessorTemperature.celsius(smc: readings) == 50)
    }

    @Test func leavesOutSensorsThatAreOffOrBroken() {
        let readings = [apple("Tp01", 50), apple("Tp05", 0), apple("Tp09", -40), apple("Tp0D", 1000), apple("Tp0H", 70)]
        #expect(ProcessorTemperature.celsius(smc: readings) == 60)
        #expect(ProcessorTemperature.celsius(smc: [apple("Tp01", 0)]) == nil)
    }

    @Test func averagesIntelsCores() {
        // An Intel iMac's Tp0P is its power supply, in fixed point
        let readings = [intel("TC1C", 60), intel("TC2C", 64), intel("TC0P", 50), intel("Tp0P", 40)]
        #expect(ProcessorTemperature.celsius(smc: readings) == 62)
    }

    @Test func otherwiseTakesIntelsPackageThenDieThenBesideIt() {
        #expect(ProcessorTemperature.celsius(smc: [intel("TC0P", 50), intel("TCXC", 70)]) == 70)
        #expect(ProcessorTemperature.celsius(smc: [intel("TC0P", 50), intel("TC0D", 65)]) == 65)
        #expect(ProcessorTemperature.celsius(smc: [intel("TC0P", 50)]) == 50)
        #expect(ProcessorTemperature.celsius(smc: []) == nil)
    }

    @Test func pickedKeysAreTheOnesItReads() {
        #expect(ProcessorTemperature.isCandidate("Tp01"))
        #expect(ProcessorTemperature.isCandidate("TC2C"))
        #expect(ProcessorTemperature.isCandidate("TC0P"))
        #expect(!ProcessorTemperature.isCandidate("Tg0f"))
        #expect(!ProcessorTemperature.isCandidate("F0Ac"))
    }

    @Test func averagesM1sClustersFromHID() {
        let sensors = [("pACC MTR Temp Sensor2", 50.0), ("eACC MTR Temp Sensor0", 40.0), ("PMU tdie1", 70.0),
                       ("gas gauge battery", 30.0)].map { (name: $0.0, celsius: $0.1) }
        #expect(ProcessorTemperature.celsius(hid: sensors) == 45)
    }

    @Test func otherwiseAveragesTheDieFromHID() {
        let sensors = [("PMU tdie1", 50.0), ("PMU tdie2", 54.0), ("PMU tdie3", 0.0), ("NAND CH0 temp", 30.0)]
            .map { (name: $0.0, celsius: $0.1) }
        #expect(ProcessorTemperature.celsius(hid: sensors) == 52)
        #expect(ProcessorTemperature.celsius(hid: [(name: "gas gauge battery", celsius: 30)]) == nil)
    }
}
