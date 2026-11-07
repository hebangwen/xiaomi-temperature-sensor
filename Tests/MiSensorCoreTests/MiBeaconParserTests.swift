import Foundation
import MiSensorCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

func expectMiBeaconError(
    _ expected: MiBeaconError,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        throw TestFailure(description: "Expected error \(expected), but operation succeeded")
    } catch let error as MiBeaconError {
        try expectEqual(error, expected, "Unexpected parser error")
    }
}

@main
@MainActor
struct MiSensorCoreTests {
    private static let macWire: [UInt8] = [0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
    private static var passed = 0

    static func main() throws {
        try run("plaintext objects", testPlaintextTemperatureHumidityAndBattery)
        try run("negative combined temperature", testNegativeTemperatureAndCombinedObject)
        try run("capability bytes", testCapabilityAndIOCapabilityAreSkipped)
        try run("encrypted MiBeacon", testEncryptedFrameRoundTrip)
        try run("cached MAC for MAC-less frames", testMACLessFramesUseCachedMAC)
        try run("legacy encryption version", testLegacyEncryptedVersionIsExplicit)
        try run("wrong bindkey", testWrongBindkeyFailsAuthentication)
        try run("missing bindkey", testEncryptedFrameRequiresKey)
        try run("malformed object", testMalformedObjectIsRejected)
        try run("formatted bindkey", testBindkeyAcceptsFormattedHex)
        try run("RFC 3610 AES-CCM vector", testRFC3610VectorOne)
        try run("custom service live value", testCustomLiveValue)
        try run("custom service history record", testCustomHistoryRecord)
        try run("snapshot store", testStoreRoundTrip)
        print("PASS: \(passed) protocol and storage tests")
    }

    private static func run(
        _ name: String,
        _ test: () throws -> Void
    ) throws {
        do {
            try test()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            print("  ✗ \(name): \(error)")
            throw error
        }
    }

    private static func testPlaintextTemperatureHumidityAndBattery() throws {
        let frame = Data(
            [0x50, 0x50, 0x5B, 0x05, 42]
            + macWire
            + [0x04, 0x10, 0x02, 0x1A, 0x01]
            + [0x06, 0x10, 0x02, 0x5A, 0x01]
            + [0x0A, 0x10, 0x01, 95]
        )
        let beacon = try MiBeaconParser.decode(frame, fallbackDeviceID: "fallback")
        try expectEqual(beacon.deviceID, "01:02:03:04:05:06", "MAC byte order")
        try expectEqual(beacon.productID, 0x055B, "product ID")
        try expectEqual(beacon.frameCounter, 42, "frame counter")
        try expectEqual(beacon.version, 5, "protocol version")
        try expectEqual(beacon.temperature, 28.2, "temperature")
        try expectEqual(beacon.humidity, 34.6, "humidity")
        try expectEqual(beacon.battery, 95, "battery")
        try expect(!beacon.isEncrypted, "frame should be plaintext")
        try expectEqual(beacon.objects.count, 3, "object count")
    }

    private static func testNegativeTemperatureAndCombinedObject() throws {
        let frame = Data(
            [0x50, 0x50, 0x32, 0x28, 7]
            + macWire
            + [0x0D, 0x10, 0x04, 0x9C, 0xFF, 0xD6, 0x01]
        )
        let beacon = try MiBeaconParser.decode(frame, fallbackDeviceID: "fallback")
        try expectEqual(beacon.temperature, -10.0, "negative temperature")
        try expectEqual(beacon.humidity, 47.0, "combined humidity")
    }

    private static func testCapabilityAndIOCapabilityAreSkipped() throws {
        let frame = Data(
            [0x70, 0x50, 0x5B, 0x05, 1]
            + macWire
            + [0x20, 0x00, 0x00]
            + [0x0A, 0x10, 0x01, 88]
        )
        let beacon = try MiBeaconParser.decode(frame, fallbackDeviceID: "fallback")
        try expectEqual(beacon.battery, 88, "battery after v5 two-byte capability")

        let legacyFrame = Data(
            [0x70, 0x40, 0x5B, 0x05, 2]
            + macWire
            + [0x20, 0x00]
            + [0x0A, 0x10, 0x01, 77]
        )
        let legacyBeacon = try MiBeaconParser.decode(legacyFrame, fallbackDeviceID: "fallback")
        try expectEqual(legacyBeacon.battery, 77, "battery after legacy one-byte capability")
    }

    private static func encryptedFrame(
        key: Data,
        object: Data,
        counter: UInt8,
        random: Data,
        includeMAC: Bool = true
    ) throws -> Data {
        var nonce = Data(macWire)
        nonce.append(contentsOf: [0x5B, 0x05, counter])
        nonce.append(random)
        let encrypted = try AESCCM.encrypt(
            plaintext: object,
            key: key,
            nonce: nonce,
            associatedData: Data([0x11]),
            tagLength: 4
        )
        let header = includeMAC
            ? [0x58, 0x50, 0x5B, 0x05, counter]
            : [0x48, 0x50, 0x5B, 0x05, counter]
        return Data(
            header
            + (includeMAC ? macWire : [])
            + encrypted.prefix(object.count)
            + random
            + encrypted.suffix(4)
        )
    }

    private static func testEncryptedFrameRoundTrip() throws {
        let key = Data((0...15).map(UInt8.init))
        let object = Data([0x0D, 0x10, 0x04, 0x1A, 0x01, 0x5A, 0x01])
        let frame = try encryptedFrame(
            key: key,
            object: object,
            counter: 42,
            random: Data([0xAA, 0xBB, 0xCC])
        )
        let beacon = try MiBeaconParser.decode(
            frame,
            bindkey: key,
            fallbackDeviceID: "fallback"
        )
        try expect(beacon.isEncrypted, "frame should be encrypted")
        try expectEqual(beacon.temperature, 28.2, "decrypted temperature")
        try expectEqual(beacon.humidity, 34.6, "decrypted humidity")
    }

    private static func testMACLessFramesUseCachedMAC() throws {
        let key = Data((0...15).map(UInt8.init))
        let object = Data([0x0D, 0x10, 0x04, 0x1A, 0x01, 0x5A, 0x01])
        let encrypted = try encryptedFrame(
            key: key,
            object: object,
            counter: 43,
            random: Data([0xAA, 0xBB, 0xCD]),
            includeMAC: false
        )
        try expectMiBeaconError(.missingMACForDecryption) {
            _ = try MiBeaconParser.decode(
                encrypted,
                bindkey: key,
                fallbackDeviceID: "fallback"
            )
        }
        let beacon = try MiBeaconParser.decode(
            encrypted,
            bindkey: key,
            fallbackDeviceID: "fallback",
            knownMACInWireOrder: Data(macWire)
        )
        try expectEqual(beacon.deviceID, "01:02:03:04:05:06", "cached MAC identity")
        try expectEqual(beacon.temperature, 28.2, "MAC-less decrypted temperature")
        try expectEqual(beacon.humidity, 34.6, "MAC-less decrypted humidity")

        let plaintext = Data(
            [0x40, 0x50, 0x5B, 0x05, 44]
            + [0x0A, 0x10, 0x01, 66]
        )
        let plainBeacon = try MiBeaconParser.decode(
            plaintext,
            fallbackDeviceID: "fallback",
            knownMACInWireOrder: Data(macWire)
        )
        try expectEqual(plainBeacon.deviceID, beacon.deviceID, "plaintext cached identity")
        try expectEqual(plainBeacon.battery, 66, "MAC-less plaintext battery")
    }

    private static func testLegacyEncryptedVersionIsExplicit() throws {
        let frame = Data(
            [0x58, 0x30, 0x5B, 0x05, 9]
            + macWire
            + [0x01, 0x02, 0x03, 1, 2, 3, 4, 5, 6, 7]
        )
        try expectMiBeaconError(.unsupportedEncryptedVersion(3)) {
            _ = try MiBeaconParser.decode(frame, fallbackDeviceID: "fallback")
        }
    }

    private static func testWrongBindkeyFailsAuthentication() throws {
        let key = Data((0...15).map(UInt8.init))
        let frame = try encryptedFrame(
            key: key,
            object: Data([0x0A, 0x10, 0x01, 75]),
            counter: 9,
            random: Data([1, 2, 3])
        )
        try expectMiBeaconError(.authenticationFailed) {
            _ = try MiBeaconParser.decode(
                frame,
                bindkey: Data(repeating: 0, count: 16),
                fallbackDeviceID: "fallback"
            )
        }
    }

    private static func testEncryptedFrameRequiresKey() throws {
        let frame = Data(
            [0x58, 0x50, 0x5B, 0x05, 9]
            + macWire
            + [0x01, 0x02, 0x03, 1, 2, 3, 4, 5, 6, 7]
        )
        try expectMiBeaconError(.bindkeyRequired) {
            _ = try MiBeaconParser.decode(frame, fallbackDeviceID: "fallback")
        }
    }

    private static func testMalformedObjectIsRejected() throws {
        let frame = Data([0x40, 0x50, 0x5B, 0x05, 1, 0x04, 0x10, 0x02, 0x1A])
        try expectMiBeaconError(.malformedObject) {
            _ = try MiBeaconParser.decode(frame, fallbackDeviceID: "fallback")
        }
    }

    private static func testBindkeyAcceptsFormattedHex() {
        assert(MiBeaconParser.parseBindkey(
            "00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f"
        ) == Data((0...15).map(UInt8.init)))
        assert(MiBeaconParser.parseBindkey("not-a-key") == nil)
    }

    private static func testRFC3610VectorOne() throws {
        let key = Data(hex: "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")
        let nonce = Data(hex: "00000003020100a0a1a2a3a4a5")
        let aad = Data(hex: "0001020304050607")
        let plaintext = Data(hex: "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e")
        let expected = Data(hex: "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0")
        let encrypted = try AESCCM.encrypt(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: aad,
            tagLength: 8
        )
        try expectEqual(encrypted, expected, "RFC ciphertext and tag")
        let decrypted = try AESCCM.decrypt(
            ciphertext: expected.prefix(plaintext.count),
            tag: expected.suffix(8),
            key: key,
            nonce: nonce,
            associatedData: aad,
            tagLength: 8
        )
        try expectEqual(decrypted, plaintext, "RFC plaintext")
    }

    private static func testCustomLiveValue() throws {
        // Real capture: EBE0CCC1 = 0c 07 3b d8 0a
        let sample = try XCTUnwrapCustom(
            CustomServiceParser.parseLive(Data([0x0C, 0x07, 0x3B, 0xD8, 0x0A])),
            "live sample"
        )
        try expectEqual(sample.temperature, 18.04, "live temperature")
        try expectEqual(sample.humidity, 59, "live humidity")
        try expectEqual(sample.batteryMillivolts, 2776, "live battery")

        let second = try XCTUnwrapCustom(
            CustomServiceParser.parseLive(Data([0x11, 0x07, 0x3B, 0xD8, 0x0A])),
            "second sample"
        )
        try expectEqual(second.temperature, 18.09, "second temperature")
    }

    private static func testCustomHistoryRecord() throws {
        // Real capture: EBE0CCBC = c1 63 00 00 20 d8 7a 05 02 01 3c f4 00 39
        let record = try XCTUnwrapCustom(
            CustomServiceParser.parseHistory(Data([
                0xC1, 0x63, 0x00, 0x00, 0x20, 0xD8, 0x7A, 0x05,
                0x02, 0x01, 0x3C, 0xF4, 0x00, 0x39
            ])),
            "history record"
        )
        try expectEqual(record.index, 0xC1, "record index")
        try expectEqual(record.timestamp, 91_936_800, "record timestamp")
        try expectEqual(record.temperatureA, 25.8, "record temperature A")
        try expectEqual(record.humidityA, 60, "record humidity A")
        try expectEqual(record.temperatureB, 24.4, "record temperature B")
        try expectEqual(record.humidityB, 57, "record humidity B")

        // Real capture: EBE0CCBB = 67 70 00 00 80 b6 2c 06 b4 00 3b b4 00 3a
        let measure = try XCTUnwrapCustom(
            CustomServiceParser.parseMeasureRecord(Data([
                0x67, 0x70, 0x00, 0x00, 0x80, 0xB6, 0x2C, 0x06,
                0xB4, 0x00, 0x3B, 0xB4, 0x00, 0x3A
            ])),
            "measure record"
        )
        try expectEqual(measure.temperatureA, 18.0, "measure temperature A")
        try expectEqual(measure.humidityA, 59, "measure humidity A")
        try expectEqual(measure.temperatureB, 18.0, "measure temperature B")
        try expectEqual(measure.humidityB, 58, "measure humidity B")
    }

    private static func testStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SensorSnapshotStore(
            fileURL: directory.appendingPathComponent("readings.json")
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = SensorReading(
            deviceID: "01:02:03:04:05:06",
            displayName: "书房",
            temperature: 23.4,
            humidity: 45.6,
            battery: 90,
            updatedAt: date,
            temperatureUpdatedAt: date,
            humidityUpdatedAt: date,
            batteryUpdatedAt: date
        )
        try store.saveAll([reading.deviceID: reading])
        try expectEqual(store.loadAll(), [reading.deviceID: reading], "stored snapshot")
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

func XCTUnwrapCustom<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw TestFailure(description: "\(label) 解析失败") }
    return value
}
