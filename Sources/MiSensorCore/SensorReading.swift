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

public struct SensorSnapshotStore: @unchecked Sendable {
    public static let defaultFilename = "sensor-readings.json"
    /// App Group UserDefaults 镜像键。实测（2026-11-08）小组件扩展进程读
    /// group 容器里的 JSON 文件会被 System Policy 拒绝（Sandbox
    /// `file-read-data` → EPERM），但 cfprefsd 的 group suite 通道可用，
    /// 所以主 App 落盘文件的同时把同一份 JSON 镜像进 suite；扩展端
    /// 读不到文件时回退到 suite。
    static let suiteMirrorKey = "MiSensor.snapshotJSON"

    /// 主 App 与小组件（WidgetKit 扩展）共用的 App Group 标识。
    ///
    /// 本机没有 Mac Development 签名证书，`$(DEVELOPMENT_TEAM)` 展开为空会让
    /// group 变成非法的 `.com.example.misensor`（AGENTS.md §9 曾实测
    /// containermanagerd 拒绝）。2026-11-07 已实测改为不带 Team 前缀的
    /// `com.example.misensor` 后，ad-hoc + App Sandbox 下主 App 与小组件进程
    /// 都能读写 `~/Library/Group Containers/com.example.misensor`。
    /// 若将来接入真实签名证书，需连同两个 entitlements 与两个 Info.plist 一起换回
    /// `$(DEVELOPMENT_TEAM).com.example.misensor`。
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
    private let suite: UserDefaults?

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        suite: UserDefaults? = nil
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.suite = suite
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
            fileManager: fileManager,
            suite: UserDefaults(suiteName: group)
        )
    }

    /// 快照 JSON 的实际落盘位置；主 App 首次迁移旧快照时使用。
    public var storeFileURL: URL { fileURL }

    public func loadAll() -> [String: SensorReading] {
        if let data = try? Data(contentsOf: fileURL),
           let readings = SensorSnapshotStore.decode(data) {
            return readings
        }
        // 扩展进程沙盒拒绝读 group 容器文件时走 suite 镜像。
        if let suite, let data = suite.data(forKey: SensorSnapshotStore.suiteMirrorKey),
           let readings = SensorSnapshotStore.decode(data) {
            return readings
        }
        return [:]
    }

    /// 与「本机 HTTP 快照通道」共用的解码入口（SnapshotServer / Widget）。
    public static func decode(_ data: Data) -> [String: SensorReading]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([String: SensorReading].self, from: data)
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
        // 同一份 JSON 镜像进 group suite，供沙盒更严的小组件扩展读取。
        suite?.set(data, forKey: SensorSnapshotStore.suiteMirrorKey)
    }
}
