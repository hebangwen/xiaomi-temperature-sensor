import Foundation

/// A merged snapshot of one sensor. BLE advertisements update individual fields;
/// values that were not present in the latest frame are deliberately retained.
public struct SensorReading: Codable, Equatable, Sendable, Identifiable {
    public var id: String { deviceID }

    public var deviceID: String
    public var displayName: String
    public var temperature: Double?
    public var humidity: Double?
    public var battery: Int?
    public var rssi: Int?
    public var productID: UInt16?
    public var lastFrameCounter: UInt8?
    public var updatedAt: Date
    public var temperatureUpdatedAt: Date?
    public var humidityUpdatedAt: Date?
    public var batteryUpdatedAt: Date?

    public init(
        deviceID: String,
        displayName: String,
        temperature: Double? = nil,
        humidity: Double? = nil,
        battery: Int? = nil,
        rssi: Int? = nil,
        productID: UInt16? = nil,
        lastFrameCounter: UInt8? = nil,
        updatedAt: Date = Date(),
        temperatureUpdatedAt: Date? = nil,
        humidityUpdatedAt: Date? = nil,
        batteryUpdatedAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
        self.rssi = rssi
        self.productID = productID
        self.lastFrameCounter = lastFrameCounter
        self.updatedAt = updatedAt
        self.temperatureUpdatedAt = temperatureUpdatedAt
        self.humidityUpdatedAt = humidityUpdatedAt
        self.batteryUpdatedAt = batteryUpdatedAt
    }

    public var hasMeasurements: Bool {
        temperature != nil || humidity != nil || battery != nil
    }

    public func freshness(at date: Date = Date()) -> SensorFreshness {
        let age = date.timeIntervalSince(updatedAt)
        if age < 0 || age <= 10 * 60 { return .fresh }
        if age <= 30 * 60 { return .aging }
        return .stale
    }
}

public enum SensorFreshness: String, Codable, Sendable {
    case fresh
    case aging
    case stale
}

/// 快照里的重复行清理。
///
/// 未绑定设备的广播帧常常不带 MAC，身份只能退回 `CBPeripheral.identifier`；
/// 设备地址轮换后 CoreBluetooth 会给出新的 UUID，于是同一台温湿度计会同时
/// 留下「UUID 行」和「MAC 行」。读数接近时删掉 UUID 行，只保留 MAC 行。
public enum SensorSnapshotCleanup {
    public static func dropProvisionalRows(
        _ readings: [String: SensorReading]
    ) -> [String: SensorReading] {
        var result = readings
        for (key, row) in readings where MiDeviceCatalog.isProvisionalIdentity(key) {
            guard let temperature = row.temperature, let humidity = row.humidity else {
                continue
            }
            let duplicated = readings.contains { other in
                other.key != key
                    && !MiDeviceCatalog.isProvisionalIdentity(other.key)
                    && MiDeviceCatalog.looksLikeDuplicateRow(
                        temperatureA: temperature,
                        humidityA: humidity,
                        temperatureB: other.value.temperature,
                        humidityB: other.value.humidity
                    )
            }
            if duplicated { result.removeValue(forKey: key) }
        }
        return result
    }
}

public struct SensorSnapshotStore {
    public static let defaultFilename = "sensor-readings.json"

    /// Xcode expands the same DEVELOPMENT_TEAM-based value in both targets'
    /// entitlements and Info.plists. Keeping runtime lookup here prevents a
    /// manually edited Swift constant from drifting away from signing settings.
    public static var configuredAppGroup: String? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "MiSensorAppGroupIdentifier"
        ) as? String,
              !value.isEmpty,
              !value.hasPrefix("$"),
              !value.hasPrefix(".") else {
            return nil
        }
        return value
    }

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public init?(
        appGroup: String? = nil,
        filename: String = SensorSnapshotStore.defaultFilename,
        fileManager: FileManager = .default
    ) {
        let group = appGroup ?? SensorSnapshotStore.configuredAppGroup
        guard let group,
              let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: group
              ) else { return nil }
        self.init(
            fileURL: container.appendingPathComponent(filename),
            fileManager: fileManager
        )
    }

    public func loadAll() -> [String: SensorReading] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: SensorReading].self, from: data)) ?? [:]
    }

    public func saveAll(_ readings: [String: SensorReading]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(readings)
        try data.write(to: fileURL, options: .atomic)
    }
}
