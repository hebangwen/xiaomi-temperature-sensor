import AppKit
import Foundation
import ServiceManagement
import WidgetKit

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

    let sharedStorageAvailable: Bool
    let storageDescription: String

    private let scanner = BLEScanner()
    private let store: SensorSnapshotStore
    private var lastWidgetReload = Date.distantPast
    private var lastStoreWrite = Date.distantPast
    private var lastDuplicateRSSIUpdate: [String: Date] = [:]
    private var lastDiagnosticUpdate: [String: Date] = [:]
    private var autoProbeDeviceID: String?
    private var probedDeviceIDs: Set<String> = []
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var pollFailures: [String: Int] = [:]
    private var pendingReloadTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private let minimumReloadInterval: TimeInterval = 5 * 60

    init() {
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

        readings = store.loadAll()
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
        readings.values.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    func rename(deviceID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var reading = readings[deviceID] else { return }
        reading.displayName = trimmed
        readings[deviceID] = reading
        persist()
        reloadWidgets()
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
                try? report.write(
                    toFile: "/tmp/misensor-gatt.txt",
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                gattProbeResult = "GATT 探测失败：\(error.localizedDescription)"
                status = error.localizedDescription
                try? gattProbeResult?.write(
                    toFile: "/tmp/misensor-gatt.txt",
                    atomically: true,
                    encoding: .utf8
                )
            }
            isProbingGATT = false
        }
    }

    func openBluetoothSettings() {        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
        NSWorkspace.shared.open(url)
    }

    func reloadWidgets() {
        pendingReloadTask?.cancel()
        pendingReloadTask = nil
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "MiSensorWidget")
    }

    private func recordRawFrame(_ frame: RawSensorFrame) {
        hasReceivedFrame = true
        let hex = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastFrameHex[frame.deviceID] = hex
        lastRawFrameNote[frame.deviceID] = frame.note

        if autoProbeDeviceID == nil,
           ProcessInfo.processInfo.arguments.contains("--probe-gatt") {
            autoProbeDeviceID = frame.deviceID
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.probeGATT(for: frame.deviceID)
            }
        }

        // "--probe-gatt-all" walks every sensor that has broadcast at least once,
        // one at a time, and writes a report per device.
        if ProcessInfo.processInfo.arguments.contains("--probe-gatt-all"),
           !probedDeviceIDs.contains(frame.deviceID) {
            probedDeviceIDs.insert(frame.deviceID)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                do {
                    let report = try await self.scanner.probeGATT(for: frame.deviceID)
                    let safe = frame.deviceID.replacingOccurrences(of: ":", with: "-")
                    try? report.write(
                        toFile: "/tmp/misensor-gatt-\(safe).txt",
                        atomically: true,
                        encoding: .utf8
                    )
                } catch {
                    try? "失败：\(error.localizedDescription)".write(
                        toFile: "/tmp/misensor-gatt-fail.txt",
                        atomically: true,
                        encoding: .utf8
                    )
                }
            }
        }
        if readings[frame.deviceID] == nil {
            readings[frame.deviceID] = SensorReading(
                deviceID: frame.deviceID,
                displayName: defaultName(
                    deviceID: frame.deviceID,
                    peripheralName: frame.peripheralName
                ),
                rssi: frame.rssi,
                updatedAt: .distantPast
            )
        }
        if let note = frame.note {
            problems[frame.deviceID] = note
            status = note
        }
        ensurePolling(deviceID: frame.deviceID)
    }

    /// Broadcast-only devices either encrypt their payload or omit it entirely.
    /// In both cases the custom sensor service can still be read over GATT
    /// without a bindkey, so fall back to polling it.
    private func ensurePolling(deviceID: String) {
        guard pollTasks[deviceID] == nil else { return }
        pollTasks[deviceID] = Task { [weak self] in
            defer { self?.pollTasks[deviceID] = nil }
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let sample = try await self.scanner.readCustomSample(for: deviceID)
                    self.apply(sample, to: deviceID)
                    self.pollFailures[deviceID] = 0
                } catch {
                    let failures = (self.pollFailures[deviceID] ?? 0) + 1
                    self.pollFailures[deviceID] = failures
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
        var reading = readings[deviceID] ?? SensorReading(
            deviceID: deviceID,
            displayName: defaultName(deviceID: deviceID, peripheralName: nil),
            updatedAt: Date()
        )
        reading.temperature = sample.temperature
        reading.humidity = sample.humidity
        reading.temperatureUpdatedAt = Date()
        reading.humidityUpdatedAt = Date()
        reading.updatedAt = Date()
        readings[deviceID] = reading
        problems.removeValue(forKey: deviceID)
        pollFailures[deviceID] = 0
        status = "已通过 GATT 读取温湿度"
        if ProcessInfo.processInfo.arguments.contains("--dump-samples") {
            let line = String(format: "%@ %.2fC %.0f%%\n",
                              reading.displayName, sample.temperature, sample.humidity)
            if let handle = FileHandle(forWritingAtPath: "/tmp/misensor-sample.txt") {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: "/tmp/misensor-sample.txt", atomically: true, encoding: .utf8)
            }
        }
        persist(force: true)
        requestWidgetReloadThrottled()
    }

    private func migrateDevice(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
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
            reloadWidgets()
        }
    }

    private func handleProblem(deviceID: String, error: MiBeaconError) {
        // An encrypted sensor has no measurement yet, but it must still appear in
        // Settings so its first bindkey can be entered. This placeholder is not
        // written to the Widget snapshot store.
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
        let deviceID = beacon.deviceID
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

        if displayChanged { requestWidgetReloadThrottled() }
    }

    private func defaultName(deviceID: String, peripheralName: String?) -> String {
        if let peripheralName, !peripheralName.isEmpty { return peripheralName }
        let parts = deviceID.split(separator: ":")
        if parts.count == 6 { return "温湿度计 \(parts.suffix(2).joined(separator: ":"))" }
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

    private func requestWidgetReloadThrottled() {
        let elapsed = Date().timeIntervalSince(lastWidgetReload)
        if elapsed >= minimumReloadInterval {
            reloadWidgets()
            return
        }
        guard pendingReloadTask == nil else { return }
        let delay = minimumReloadInterval - elapsed
        pendingReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pendingReloadTask = nil
            self?.lastWidgetReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: "MiSensorWidget")
        }
    }
}
