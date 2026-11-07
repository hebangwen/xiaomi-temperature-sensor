import Foundation

/// Parser for the custom GATT service exposed by `LYWSD03MMC`-family sensors
/// (service `EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6`).
///
/// These characteristics are readable/notifiable **without** the Xiaomi
/// authentication handshake, so readings work with no bindkey.
public struct CustomSensorSample: Equatable, Sendable {
    public let temperature: Double
    public let humidity: Double
    public let batteryMillivolts: UInt16?
    public let timestamp: UInt32?
}

public struct CustomHistoryRecord: Equatable, Sendable {
    public let index: UInt8
    public let timestamp: UInt32
    public let temperatureA: Double
    public let humidityA: Double
    public let temperatureB: Double
    public let humidityB: Double
}

public enum CustomServiceParser {
    public static let serviceUUID = "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6"

    /// `0xEBE0CCC1` / `0x8EDFFFEF`: the current reading.
    /// Layout: int16 LE in 0.01 °C, humidity in %, battery in millivolts.
    public static func parseLive(_ data: Data) -> CustomSensorSample? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
        let humidity = Double(bytes[2])
        let millivolts = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
        return CustomSensorSample(
            temperature: Double(raw) / 100,
            humidity: humidity,
            batteryMillivolts: millivolts,
            timestamp: nil
        )
    }

    /// `0xEBE0CCBB`: last measurement record.
    /// Layout: counter(4) + timestamp(4) + two (int16 LE in 0.1 °C, humidity %).
    public static func parseMeasureRecord(_ data: Data) -> CustomHistoryRecord? {
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else { return nil }
        let timestamp = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8)
            | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        let temperatureA = Double(Int16(bitPattern: UInt16(bytes[8]) | (UInt16(bytes[9]) << 8))) / 10
        let temperatureB = Double(Int16(bitPattern: UInt16(bytes[11]) | (UInt16(bytes[12]) << 8))) / 10
        return CustomHistoryRecord(
            index: 0,
            timestamp: timestamp,
            temperatureA: temperatureA,
            humidityA: Double(bytes[10]),
            temperatureB: temperatureB,
            humidityB: Double(bytes[13])
        )
    }

    /// `0xEBE0CCBC`: hourly history record.
    /// Layout: index(1) + counter(3) + timestamp(4) + two (int16 LE in 0.1 °C, humidity %).
    public static func parseHistory(_ data: Data) -> CustomHistoryRecord? {
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else { return nil }
        let timestamp = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8)
            | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        let temperatureA = Double(Int16(bitPattern: UInt16(bytes[8]) | (UInt16(bytes[9]) << 8))) / 10
        let temperatureB = Double(Int16(bitPattern: UInt16(bytes[11]) | (UInt16(bytes[12]) << 8))) / 10
        return CustomHistoryRecord(
            index: bytes[0],
            timestamp: timestamp,
            temperatureA: temperatureA,
            humidityA: Double(bytes[10]),
            temperatureB: temperatureB,
            humidityB: Double(bytes[13])
        )
    }
}
