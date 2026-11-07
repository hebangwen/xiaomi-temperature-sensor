import AppKit
import Foundation
import ServiceManagement
import os

@MainActor
final class SensorController: ObservableObject {
    @Published private(set) var readings: [String: SensorReading]
    @Published private(set) var status = BLEScannerStatus.starting.rawValue
    @Published private(set) var problems: [String: String] = [:]
    @Published private(set) var lastFrameHex: [String: String] = [:]
    @Published private(set) var lastRawFrameNote: [String: String] = [:]
    @Published private(set) var hasReceivedFrame = false
    @Published private(set) var gattProbeResult: String?
    @Published private(set) var isProbingGATT = false
    @Published private(set) var loginItemEnabled = SMAppService.mainApp.status == .enabled
    /// 每台设备的校时结果文案，设置页直接展示。
    @Published private(set) var clockReports: [String: String] = [:]
    @Published private(set) var isSyncingClock: Set<String> = []
    @Published private(set) var lastClockSync: [String: Date] = [:]
    /// 被用户忽略的设备 ID（例如共用 FE95 广播的智能灯）。
    @Published private(set) var ignoredDeviceIDs: Set<String> = []
    /// 时间网关开关。开启后每台设备最多每小时被写一次时间。
    @Published var timeGatewayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(timeGatewayEnabled, forKey: Self.gatewayDefaultsKey)
            guard timeGatewayEnabled else { return }
            status = "时间网关已启用：收到广播后会把 Mac 当前时间写进设备"
            for deviceID in readings.keys {
                maybeSyncClock(deviceID: deviceID)
            }
        }
    }

    let sharedStorageAvailable: Bool
    let storageDescription: String

    private let scanner = BLEScanner()
    private let pollLogger = Logger(subsystem: "com.example.MiSensor", category: "Poll")
    private let store: SensorSnapshotStore
    private var lastStoreWrite = Date.distantPast
    private var lastDuplicateRSSIUpdate: [String: Date] = [:]
    private var lastDiagnosticUpdate: [String: Date] = [:]
    private var deviceAliases: [String: String] = [:]
    private var autoProbeDeviceID: String?
    private var probedDeviceIDs: Set<String> = []
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var pollFailures: [String: Int] = [:]
    private var wakeTask: Task<Void, Never>?
    // 没有时钟特征的固件只尝试一次，避免每次广播都白连一次。
    private var clockUnsupportedDevices: Set<String> = []
    // 暴露过 EBE0CCB0 自定义服务的设备，说明确实是温湿度计。
    private var serviceCapableDeviceIDs: Set<String> = []
    private var lastMergeSweep = Date.distantPast
    private static let ignoredDevicesKey = "MiSensor.ignoredDevices" 
    private static let gatewayDefaultsKey = "MiSensor.timeGatewayEnabled"
    private static let lastClockSyncKey = "MiSensor.lastClockSync"
    /// 原厂固件没有 RTC 校准，时钟持续漂移；1 小时校一次让记录时间戳保持可信。
    private static let clockSyncInterval: TimeInterval = 3600

    init() {
        let savedIgnoredDevices = Set(
            UserDefaults.standard.stringArray(forKey: Self.ignoredDevicesKey) ?? []
        )
        ignoredDeviceIDs = savedIgnoredDevices
        if let sharedStore = SensorSnapshotStore() {
            store = sharedStore
            sharedStorageAvailable = true
            storageDescription = "App Group / sensor-readings.json"
        } else {
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("MiSensor", isDirectory: true)
            store = SensorSnapshotStore(
                fileURL: directory.appendingPathComponent("sensor-readings.json")
            )
            sharedStorageAvailable = false
            storageDescription = directory.path
        }

        timeGatewayEnabled = UserDefaults.standard.bool(forKey: Self.gatewayDefaultsKey)
            || ProcessInfo.processInfo.arguments.contains("--push-clock")
        lastClockSync = SensorController.loadLastClockSync()

        // 用局部常量，避免在 timeGatewayEnabled 赋值前访问 self。
        readings = store.loadAll().filter { !savedIgnoredDevices.contains($0.key) }
        dropDuplicateFallbackRows()
        for deviceID in readings.keys {
            scanner.setBindkey(BindkeyKeychain.key(for: deviceID), for: deviceID)
        }

        scanner.onStatusChange = { [weak self] scannerStatus in
            self?.status = scannerStatus.rawValue
        }
        scanner.onAdvertisement = { [weak self] advertisement in
            self?.receive(advertisement)
        }
        scanner.onProblem = { [weak self] deviceID, error in
            self?.handleProblem(deviceID: deviceID, error: error)
        }
        scanner.onDeviceIdentity = { [weak self] fallbackID, deviceID in
            self?.migrateDevice(from: fallbackID, to: deviceID)
        }
        scanner.onRawFrame = { [weak self] frame in
            self?.recordRawFrame(frame)
        }
        scanner.start()
        for deviceID in readings.keys {
            maybeSyncClock(deviceID: deviceID)
        }
        wakeTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didWakeNotification
            )
            for await _ in notifications {
                self?.scanner.restart()
            }
        }
    }

    func sortedReadings() -> [SensorReading] {
        readings.values
            .filter { !ignoredDeviceIDs.contains($0.deviceID) }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// 忽略一台设备：常见的例子是共用 `FE95` 广播、但永远读不到温湿度的智能灯。
    /// 忽略只影响本机的显示与轮询，设备本身不做任何操作，可随时恢复。
    func ignoreDevice(_ deviceID: String) {
        guard !deviceID.isEmpty else { return }
        ignoredDeviceIDs.insert(deviceID)
        pollTasks.removeValue(forKey: deviceID)?.cancel()
        readings.removeValue(forKey: deviceID)
        problems.removeValue(forKey: deviceID)
        lastFrameHex.removeValue(forKey: deviceID)
        lastRawFrameNote.removeValue(forKey: deviceID)
        Self.saveIgnoredDevices(ignoredDeviceIDs)
        persist(force: true)
        status = "已忽略该设备，可在设置页恢复"
    }

    func restoreIgnoredDevices() {
        guard !ignoredDeviceIDs.isEmpty else { return }
        ignoredDeviceIDs.removeAll()
        Self.saveIgnoredDevices(ignoredDeviceIDs)
        status = "已恢复显示被忽略的设备（收到广播后重新出现）"
    }

    func isIgnored(_ deviceID: String) -> Bool {
        ignoredDeviceIDs.contains(deviceID)
    }

    private static func saveIgnoredDevices(_ value: Set<String>) {
        UserDefaults.standard.set(Array(value), forKey: ignoredDevicesKey)
    }

    func rename(deviceID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var reading = readings[deviceID] else { return }
        reading.displayName = trimmed
        readings[deviceID] = reading
        persist()
    }

    func saveBindkey(_ text: String, for deviceID: String) throws {
        guard let key = MiBeaconParser.parseBindkey(text) else {
            throw MiBeaconError.invalidBindkeyLength
        }
        try BindkeyKeychain.save(key, for: deviceID)
        scanner.setBindkey(key, for: deviceID)
        problems.removeValue(forKey: deviceID)
        status = "bindkey 已保存，等待下一帧加密广播"
    }

    func removeBindkey(for deviceID: String) throws {
        try BindkeyKeychain.remove(deviceID: deviceID)
        scanner.setBindkey(nil, for: deviceID)
        status = "bindkey 已移除"
    }

    func hasBindkey(for deviceID: String) -> Bool {
        BindkeyKeychain.key(for: deviceID) != nil
    }

    func setLoginItem(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    func probeGATT(for deviceID: String) {
        guard !isProbingGATT else { return }
        isProbingGATT = true
        gattProbeResult = "正在连接 \(deviceID) …"
        status = "正在连接设备读取 GATT"

        Task {
            do {
                let report = try await scanner.probeGATT(for: deviceID)
                gattProbeResult = report
                status = "GATT 探测完成"
                writeDiagnostic("misensor-gatt.txt", report)
            } catch {
                gattProbeResult = "GATT 探测失败：\(error.localizedDescription)"
                status = error.localizedDescription
                if let gattProbeResult {
                    writeDiagnostic("misensor-gatt.txt", gattProbeResult)
                }
            }
            isProbingGATT = false
        }
    }

    /// 手动把当前时间推给设备（设置页按钮）。
    func pushClock(for deviceID: String) {
        guard !deviceID.isEmpty else { return }
        guard !isSyncingClock.contains(deviceID) else { return }
        clockUnsupportedDevices.remove(deviceID)
        isSyncingClock.insert(deviceID)
        clockReports[deviceID] = "正在连接设备推送时间…"
        status = "正在向设备推送当前时间"

        Task {
            defer { isSyncingClock.remove(deviceID) }
            do {
                let result = try await scanner.pushClock(to: deviceID)
                clockReports[deviceID] = result.summary
                status = result.summary
                if result.verified {
                    lastClockSync[deviceID] = Date()
                    SensorController.saveLastClockSync(lastClockSync)
                    appendClockLog(result.summary)
                } else {
                    clockUnsupportedDevices.insert(deviceID)
                    SensorController.saveLastClockSync(lastClockSync)
                }
            } catch ClockSyncError.noClockCharacteristic {
                clockUnsupportedDevices.insert(deviceID)
                clockReports[deviceID] = "该固件没有可写的时钟特征，无法校时"
                status = "该固件没有可写的时钟特征"
            } catch {
                clockReports[deviceID] = "校时失败：\(error.localizedDescription)"
                status = "校时失败：\(error.localizedDescription)"
            }
        }
    }

    /// 只读设备时钟，不改设备，用于确认它到底有没有被校时。
    func readClock(for deviceID: String) {
        guard !deviceID.isEmpty, !isSyncingClock.contains(deviceID) else { return }
        isSyncingClock.insert(deviceID)
        clockReports[deviceID] = "正在读取设备时间…"
        Task {
            defer { isSyncingClock.remove(deviceID) }
            do {
                let result = try await scanner.readClock(from: deviceID)
                clockReports[deviceID] = result.summary
                status = result.summary
            } catch {
                clockReports[deviceID] = "读取设备时间失败：\(error.localizedDescription)"
            }
        }
    }

    private func maybeSyncClock(deviceID: String) {
        guard timeGatewayEnabled else { return }
        guard readings[deviceID] != nil else { return }
        guard !clockUnsupportedDevices.contains(deviceID) else { return }
        guard !isSyncingClock.contains(deviceID) else { return }
        let last = lastClockSync[deviceID] ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.clockSyncInterval else { return }
        pushClock(for: deviceID)
    }

    private static func loadLastClockSync() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: lastClockSyncKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func saveLastClockSync(_ value: [String: Date]) {
        let raw = value.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: lastClockSyncKey)
    }

    private func appendClockLog(_ line: String) {
        guard let url = diagnosticURL(named: "misensor-clock.txt") else { return }
        let text = "\(DeviceClockFormatter().string(from: Date())) \(line)\n"
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    func openBluetoothSettings() {        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
        NSWorkspace.shared.open(url)
    }

    private func recordRawFrame(_ frame: RawSensorFrame) {
        hasReceivedFrame = true
        let deviceID = canonicalID(frame.deviceID)
        let hex = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastFrameHex[deviceID] = hex
        lastRawFrameNote[deviceID] = frame.note

        if autoProbeDeviceID == nil,
           ProcessInfo.processInfo.arguments.contains("--probe-gatt") {
            autoProbeDeviceID = deviceID
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.probeGATT(for: deviceID)
            }
        }

        // "--probe-gatt-all" walks every sensor that has broadcast at least once,
        // one at a time, and writes a report per device.
        if ProcessInfo.processInfo.arguments.contains("--probe-gatt-all"),
           !probedDeviceIDs.contains(deviceID) {
            probedDeviceIDs.insert(deviceID)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                do {
                    let report = try await self.scanner.probeGATT(for: deviceID)
                    let safe = deviceID.replacingOccurrences(of: ":", with: "-")
                    self.writeDiagnostic("misensor-gatt-\(safe).txt", report)
                } catch {
                    self.writeDiagnostic(
                        "misensor-gatt-fail.txt",
                        "失败：\(error.localizedDescription)"
                    )
                }
            }
        }
        if readings[deviceID] == nil {
            // 共用 FE95 的设备（灯、开关……）没有温湿度也不暴露自定义服务，
            // 原始帧已经记录在 lastFrameHex 里供诊断，但不建行、不轮询。
            guard shouldTrack(
                deviceID: deviceID,
                productID: frame.productID,
                hasMeasurement: frame.hasMeasurement
            ) else { return }
            readings[deviceID] = SensorReading(
                deviceID: deviceID,
                displayName: defaultName(
                    deviceID: deviceID,
                    peripheralName: frame.peripheralName
                ),
                rssi: frame.rssi,
                updatedAt: .distantPast
            )
        }
        if let note = frame.note {
            problems[deviceID] = note
            status = note
        }
        ensurePolling(deviceID: deviceID)
        maybeSyncClock(deviceID: deviceID)
        sweepProvisionalRows()
    }

    /// 是否值得为这台设备保留一行。判据从强到弱：
    /// 用户没忽略 → 帧里有测量值 → 暴露过 EBE0CCB0 自定义服务 → Product ID 是已知温湿度计。
    private func shouldTrack(deviceID: String, productID: UInt16?, hasMeasurement: Bool) -> Bool {
        if ignoredDeviceIDs.contains(deviceID) { return false }
        if hasMeasurement { return true }
        if serviceCapableDeviceIDs.contains(deviceID) { return true }
        if let productID, MiDeviceCatalog.isKnownThermometer(productID: productID) {
            return true
        }
        return false
    }

    /// 未绑定设备的帧常常不带 MAC，身份只能退回 CoreBluetooth UUID；
    /// 同一台物理设备因此会同时留下 UUID 行和 MAC 行。每 30 秒扫一次，
    /// 读数接近就把 UUID 行并进 MAC 行。
    private func sweepProvisionalRows() {
        guard Date().timeIntervalSince(lastMergeSweep) >= 30 else { return }
        lastMergeSweep = Date()
        let provisional = readings.filter { MiDeviceCatalog.isProvisionalIdentity($0.key) }
        guard !provisional.isEmpty else { return }
        for (provisionalID, row) in provisional {
            guard !ignoredDeviceIDs.contains(provisionalID) else { continue }
            guard let match = readings.first(where: { key, value in
                key != provisionalID
                    && !MiDeviceCatalog.isProvisionalIdentity(key)
                    && MiDeviceCatalog.looksLikeDuplicateRow(
                        temperatureA: row.temperature,
                        humidityA: row.humidity,
                        temperatureB: value.temperature,
                        humidityB: value.humidity
                    )
            }) else { continue }
            pollTasks.removeValue(forKey: provisionalID)?.cancel()
            pollFailures.removeValue(forKey: provisionalID)
            pollLogger.notice("merge duplicate row \(provisionalID, privacy: .public) -> \(match.key, privacy: .public)")
            migrateDevice(from: provisionalID, to: match.key)
            status = "已把身份未识别的重复行合并进 \(readings[match.key]?.displayName ?? match.key)"
        }
    }

    /// Broadcast-only devices either encrypt their payload or omit it entirely.
    /// In both cases the custom sensor service can still be read over GATT
    /// without a bindkey, so fall back to polling it.
    private func ensurePolling(deviceID rawDeviceID: String) {
        let deviceID = canonicalID(rawDeviceID)
        guard pollTasks[deviceID] == nil else { return }
        pollLogger.notice("poll start \(deviceID, privacy: .public)")
        pollTasks[deviceID] = Task { [weak self] in
            defer { self?.pollTasks[deviceID] = nil }
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let sample = try await self.scanner.readCustomSample(for: deviceID)
                    self.apply(sample, to: deviceID)
                    self.pollFailures[deviceID] = 0
                    self.pollLogger.notice("poll ok \(deviceID, privacy: .public) \(sample.temperature, privacy: .public)C")
                } catch {
                    let failures = (self.pollFailures[deviceID] ?? 0) + 1
                    self.pollFailures[deviceID] = failures
                    self.pollLogger.error("poll fail \(deviceID, privacy: .public) #\(failures, privacy: .public) \(error.localizedDescription, privacy: .public)")
                    if failures >= 3 {
                        self.problems[deviceID] = "该设备不支持免密钥读取"
                        return
                    }
                }
                // Keep the reading fresh: reconnect every two minutes.
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    private func apply(_ sample: CustomSensorSample, to deviceID: String) {
        serviceCapableDeviceIDs.insert(deviceID)
        var reading = readings[deviceID] ?? SensorReading(
            deviceID: deviceID,
            displayName: defaultName(deviceID: deviceID, peripheralName: nil),
            updatedAt: Date()
        )
        reading.temperature = sample.temperature
        reading.humidity = sample.humidity
        reading.temperatureUpdatedAt = Date()
        reading.humidityUpdatedAt = Date()
        // GATT 侧的电量来自 EBE0CCC4；广播 0x100A 的电量优先级更高，
        // 所以只在快照里没有电量、或读数比广播更可信（原厂固件不广播 0x100A）时补上。
        if let batteryPercent = sample.batteryPercent,
           reading.battery == nil {
            reading.battery = batteryPercent
            reading.batteryUpdatedAt = Date()
        }
        reading.updatedAt = Date()
        readings[deviceID] = reading
        problems.removeValue(forKey: deviceID)
        pollFailures[deviceID] = 0
        status = "已通过 GATT 读取温湿度"
        if ProcessInfo.processInfo.arguments.contains("--dump-samples") {
            let batteryText = reading.battery.map { " \($0)%" } ?? ""
            appendSampleLine(String(format: "%@ %.2fC %.0f%%%@\n",
                                    reading.displayName, sample.temperature, sample.humidity, batteryText))
        }
        persist(force: true)
        sweepProvisionalRows()
    }

    /// The App is sandboxed, so `/tmp` is not writable in a signed build. Keep
    /// the familiar path when it is writable (unsigned / ad-hoc debugging) and
    /// fall back to the container's temporary directory otherwise.
    private func diagnosticURL(named name: String) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/tmp/\(name)"),
            FileManager.default.temporaryDirectory.appendingPathComponent(name)
        ]
        return candidates.first {
            FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path)
        }
    }

    private func writeDiagnostic(_ name: String, _ content: String) {
        guard let url = diagnosticURL(named: name) else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendSampleLine(_ line: String) {
        guard let url = diagnosticURL(named: "misensor-sample.txt") else { return }
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func migrateDevice(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        deviceAliases[oldID] = newID
        // A UUID fallback row and its MAC row must not both keep polling.
        if let task = pollTasks.removeValue(forKey: oldID) {
            task.cancel()
            pollFailures.removeValue(forKey: oldID)
            problems.removeValue(forKey: oldID)
        }
        var migratedMeasurements = false

        if let old = readings.removeValue(forKey: oldID) {
            var merged = old
            merged.deviceID = newID
            if let current = readings[newID] {
                if current.hasMeasurements { merged.displayName = current.displayName }
                if let value = current.temperature {
                    merged.temperature = value
                    merged.temperatureUpdatedAt = current.temperatureUpdatedAt
                }
                if let value = current.humidity {
                    merged.humidity = value
                    merged.humidityUpdatedAt = current.humidityUpdatedAt
                }
                if let value = current.battery {
                    merged.battery = value
                    merged.batteryUpdatedAt = current.batteryUpdatedAt
                }
                merged.rssi = current.rssi ?? old.rssi
                merged.productID = current.productID ?? old.productID
                merged.lastFrameCounter = current.lastFrameCounter ?? old.lastFrameCounter
                merged.updatedAt = max(current.updatedAt, old.updatedAt)
            }
            readings[newID] = merged
            migratedMeasurements = merged.hasMeasurements
        }

        if let problem = problems.removeValue(forKey: oldID), problems[newID] == nil {
            problems[newID] = problem
        }
        if let frame = lastFrameHex.removeValue(forKey: oldID), lastFrameHex[newID] == nil {
            lastFrameHex[newID] = frame
        }
        if let note = lastRawFrameNote.removeValue(forKey: oldID), lastRawFrameNote[newID] == nil {
            lastRawFrameNote[newID] = note
        }

        if BindkeyKeychain.key(for: newID) == nil,
           let oldKey = BindkeyKeychain.key(for: oldID) {
            do {
                try BindkeyKeychain.save(oldKey, for: newID)
                scanner.setBindkey(oldKey, for: newID)
                try BindkeyKeychain.remove(deviceID: oldID)
            } catch {
                status = "迁移 bindkey 失败：\(error.localizedDescription)"
            }
        }

        if migratedMeasurements {
            persist()
        }
    }

    private func handleProblem(deviceID rawDeviceID: String, error: MiBeaconError) {
        let deviceID = canonicalID(rawDeviceID)
        // An encrypted sensor has no measurement yet, but it must still appear in
        // Settings so its first bindkey can be entered. This placeholder is not
        // written to the snapshot store.
        if readings[deviceID] == nil,
           error == .bindkeyRequired
            || error == .authenticationFailed
            || error == .missingMACForDecryption {
            readings[deviceID] = SensorReading(
                deviceID: deviceID,
                displayName: defaultName(deviceID: deviceID, peripheralName: nil),
                updatedAt: .distantPast
            )
        }
        problems[deviceID] = error.localizedDescription
        status = error.localizedDescription
        if error == .bindkeyRequired || error == .authenticationFailed || error == .noObjectInFrame {
            ensurePolling(deviceID: deviceID)
        }
    }

    private func receive(_ advertisement: SensorAdvertisement) {
        let beacon = advertisement.beacon
        let deviceID = canonicalID(beacon.deviceID)
        let previous = readings[deviceID]
        var reading = previous ?? SensorReading(
            deviceID: deviceID,
            displayName: defaultName(deviceID: deviceID, peripheralName: advertisement.peripheralName),
            updatedAt: beacon.receivedAt
        )

        reading.rssi = advertisement.rssi
        reading.productID = beacon.productID
        reading.lastFrameCounter = beacon.frameCounter

        guard !advertisement.isDuplicate else {
            let lastUpdate = lastDuplicateRSSIUpdate[deviceID] ?? .distantPast
            if previous?.rssi != reading.rssi,
               beacon.receivedAt.timeIntervalSince(lastUpdate) >= 30 {
                readings[deviceID] = reading
                lastDuplicateRSSIUpdate[deviceID] = beacon.receivedAt
            }
            return
        }

        reading.updatedAt = beacon.receivedAt
        if let temperature = beacon.temperature {
            reading.temperature = temperature
            reading.temperatureUpdatedAt = beacon.receivedAt
        }
        if let humidity = beacon.humidity {
            reading.humidity = humidity
            reading.humidityUpdatedAt = beacon.receivedAt
        }
        if let battery = beacon.battery {
            reading.battery = battery
            reading.batteryUpdatedAt = beacon.receivedAt
        }

        let displayChanged = previous?.temperature != reading.temperature
            || previous?.humidity != reading.humidity
            || previous?.battery != reading.battery
            || (previous == nil && reading.hasMeasurements)

        readings[deviceID] = reading
        let lastDiagnostic = lastDiagnosticUpdate[deviceID] ?? .distantPast
        if displayChanged || beacon.receivedAt.timeIntervalSince(lastDiagnostic) >= 5 {
            lastFrameHex[deviceID] = beacon.rawFrame
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            lastDiagnosticUpdate[deviceID] = beacon.receivedAt
        }
        problems.removeValue(forKey: deviceID)
        if status != BLEScannerStatus.scanning.rawValue {
            status = BLEScannerStatus.scanning.rawValue
        }
        persist(force: displayChanged)
        sweepProvisionalRows()
    }

    /// One sensor must map to one row. A UUID fallback identity collapses onto
    /// the MAC-based ID as soon as the scanner has cached a MAC for that
    /// peripheral; the old row and its poll loop are retired on the first hit.
    private func canonicalID(_ deviceID: String) -> String {
        if let known = deviceAliases[deviceID] { return known }
        let canonical = scanner.canonicalDeviceID(for: deviceID)
        guard canonical != deviceID else { return deviceID }
        deviceAliases[deviceID] = canonical
        migrateDevice(from: deviceID, to: canonical)
        return canonical
    }

    /// Older snapshots could hold the same sensor twice: once under the MAC and
    /// once under the CoreBluetooth UUID. Drop the UUID copy when its value
    /// matches a MAC row, so the menu does not list one sensor twice.
    private func dropDuplicateFallbackRows() {
        readings = SensorSnapshotCleanup.dropProvisionalRows(readings)
    }

    private func defaultName(deviceID: String, peripheralName: String?) -> String {
        if let peripheralName, !peripheralName.isEmpty { return peripheralName }
        let parts = deviceID.split(separator: ":")
        if parts.count == 6 { return "温湿度计 \(parts.suffix(2).joined(separator: ":"))" }
        // 身份只有 CoreBluetooth UUID 时会与 MAC 行重复，名字标出来便于辨认。
        if MiDeviceCatalog.isProvisionalIdentity(deviceID) { return "温湿度计（身份未识别）" }
        return "米家温湿度计"
    }

    private func persist(force: Bool = true) {
        if !force, Date().timeIntervalSince(lastStoreWrite) < 30 { return }
        do {
            try store.saveAll(readings.filter { $0.value.hasMeasurements })
            lastStoreWrite = Date()
        } catch {
            status = "保存共享数据失败：\(error.localizedDescription)"
        }
    }

}
