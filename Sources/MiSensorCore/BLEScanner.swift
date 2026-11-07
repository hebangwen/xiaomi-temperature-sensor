import CoreBluetooth
import Foundation
import os

public enum BLEScannerStatus: String, Sendable {
    case starting = "正在初始化蓝牙"
    case scanning = "正在接收温湿度计广播"
    case poweredOff = "蓝牙已关闭"
    case unauthorized = "请在系统设置中允许 App 使用蓝牙"
    case unsupported = "当前 Mac 不支持低功耗蓝牙"
    case resetting = "蓝牙服务正在重置"
    case unknown = "蓝牙状态未知"
}

public struct SensorAdvertisement: Sendable {
    public let beacon: DecodedBeacon
    public let peripheralName: String?
    public let rssi: Int
    public let isDuplicate: Bool
}

/// `CBPeripheral` 不是 `Sendable`，但 CoreBluetooth 保证回调发生在同一个主线程。
/// 用这个盒子把扫描到的外设对象带进主 actor 闭包，避免“捕获非 Sendable 值”的编译错误。
private final class PeripheralBox: @unchecked Sendable {
    let peripheral: CBPeripheral
    init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
}

/// Every FE95 frame the OS handed us, decoded or not. Used by the diagnostics UI
/// so a firmware the parser cannot read is still visible instead of silent.
public struct RawSensorFrame: Sendable {
    public let deviceID: String
    public let peripheralName: String?
    public let rssi: Int
    public let payload: Data
    public let note: String?
    /// 帧里的 Product ID。用来区分「真是温湿度计」和共用 `FE95` 的灯/开关。
    public let productID: UInt16?
    /// 这一帧是否带出了温湿度（或电量）之类的测量值。
    public let hasMeasurement: Bool

    public init(
        deviceID: String,
        peripheralName: String?,
        rssi: Int,
        payload: Data,
        note: String?,
        productID: UInt16? = nil,
        hasMeasurement: Bool = false
    ) {
        self.deviceID = deviceID
        self.peripheralName = peripheralName
        self.rssi = rssi
        self.payload = payload
        self.note = note
        self.productID = productID
        self.hasMeasurement = hasMeasurement
    }
}

/// Unstructured diagnostic sink. Kept outside the MainActor type so the
/// CoreBluetooth delegate can log before any actor hop.
enum BLEScannerDiagnostics {
    private static let logger = Logger(subsystem: "com.example.MiSensor", category: "BLE")

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

enum GATTProbeError: Error, LocalizedError {
    case notScanning
    case peripheralUnavailable
    case disconnected(String)
    case noCharacteristic(String)

    var errorDescription: String? {
        switch self {
        case .notScanning: "蓝牙尚未就绪"
        case .peripheralUnavailable: "找不到该设备，请让设备靠近并重新广播"
        case .disconnected(let reason): "连接中断：\(reason)"
        case .noCharacteristic(let name): "设备没有 \(name) 特征"
        }
    }
}

/// Passive-only CoreBluetooth scanner. It never connects to the sensor and never
/// starts a GATT session, so the original firmware remains untouched.
@MainActor
public final class BLEScanner: NSObject, @preconcurrency CBCentralManagerDelegate {
    private let service = CBUUID(string: "FE95")
    /// 状态恢复标识只在有 App bundle 的进程里有效。命令行工具传 nil，
    /// 否则 `CBCentralManager` 会卡在初始化而不回调状态。
    private let restoreIdentifier: String?
    private lazy var central: CBCentralManager = {
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        return CBCentralManager(delegate: self, queue: nil, options: options)
    }()

    public init(restoreIdentifier: String? = "com.example.MiSensor.central") {
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    public var onStatusChange: ((BLEScannerStatus) -> Void)?
    public var onAdvertisement: ((SensorAdvertisement) -> Void)?
    public var onProblem: ((String, MiBeaconError) -> Void)?
    public var onDeviceIdentity: ((String, String) -> Void)?
    public var onRawFrame: ((RawSensorFrame) -> Void)?

    private var bindkeys: [String: Data] = [:]
    private var knownMACs: [UUID: Data] = [:]
    private var discoveredPeripherals: [String: UUID] = [:]
    // 直接复用 didDiscover 拿到的 CBPeripheral。对广播稀疏的设备（如 MJWSD05MMC），
    // 用 retrievePeripherals 重新取出的对象 connect 会一直挂到超时，实测必现。
    private var discoveredObjects: [UUID: CBPeripheral] = [:]
    // One session per peripheral. A single shared session let the GATT callbacks
    // of sensor A be delivered to sensor B's session when both polled at once,
    // which wrote A's sample into B's reading.
    private var probeSessions: [UUID: GATTProbeSession] = [:]
    private var sampleSessions: [UUID: CustomSampleSession] = [:]
    // 校时会写设备，和读取会话一样按外设隔离，不允许共享 delegate。
    private var timeSyncSessions: [UUID: TimeSyncSession] = [:]
    // CoreBluetooth allows one connection attempt at a time here: the second
    // connect() cancels the scan the first one relies on, and stopScan() from
    // either task aborts the other's service discovery.
    private let gattGate = AsyncGate()
    private var lastFrames: [String: Data] = [:]
    private var lastProblems: [String: MiBeaconError] = [:]
    private var fallbackTask: Task<Void, Never>?

    public func start() {
        _ = central
    }

    public func restart() {
        central.stopScan()
        scanIfPossible()
    }

    /// 优先用扫描时拿到的外设对象；只有缓存缺失时才回退到 retrievePeripherals。
    private func resolvePeripheral(for deviceID: String) throws -> CBPeripheral {
        guard let uuid = discoveredPeripherals[deviceID] else {
            throw GATTProbeError.peripheralUnavailable
        }
        if let cached = discoveredObjects[uuid] {
            return cached
        }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw GATTProbeError.peripheralUnavailable
        }
        return peripheral
    }

    /// Connects to a discovered sensor and dumps its GATT tree. Used to check
    /// whether readings are available over a connection when advertisements
    /// carry no Object payload.
    public func probeGATT(for deviceID: String, timeout: TimeInterval = 20) async throws -> String {
        await gattGate.acquire()
        defer { gattGate.release() }

        guard central.state == .poweredOn else { throw GATTProbeError.notScanning }
        let peripheral = try resolvePeripheral(for: deviceID)
        let uuid = peripheral.identifier

        central.stopScan()

        let session = GATTProbeSession(peripheral: peripheral, timeout: timeout)
        probeSessions[uuid] = session
        central.connect(peripheral, options: nil)
        do {
            let report = try await session.run()
            probeSessions.removeValue(forKey: uuid)
            scanIfPossible()
            return report
        } catch {
            probeSessions.removeValue(forKey: uuid)
            scanIfPossible()
            throw error
        }
    }

    /// Connects, reads one live sample from the custom sensor service and
    /// disconnects. Used when the advertisement carries no usable payload.
    public func readCustomSample(for deviceID: String, timeout: TimeInterval = 12) async throws -> CustomSensorSample {
        // Sensors are polled by independent tasks. Serialize them so only one
        // connect / stopScan / service discovery is in flight at a time.
        await gattGate.acquire()
        defer { gattGate.release() }

        guard central.state == .poweredOn else { throw GATTProbeError.notScanning }
        let peripheral = try resolvePeripheral(for: deviceID)
        let peripheralID = peripheral.identifier

        central.stopScan()
        let session = CustomSampleSession(peripheral: peripheral, timeout: timeout)
        sampleSessions[peripheralID] = session
        central.connect(peripheral, options: nil)

        do {
            let sample = try await session.run()
            central.cancelPeripheralConnection(peripheral)
            sampleSessions.removeValue(forKey: peripheralID)
            scanIfPossible()
            return sample
        } catch {
            central.cancelPeripheralConnection(peripheral)
            sampleSessions.removeValue(forKey: peripheralID)
            scanIfPossible()
            throw error
        }
    }

    /// 把当前时间写进设备，也就是充当一次蓝牙网关。
    /// 这一步**会改设备状态**（设备时钟），是本项目唯一写设备的通道。
    public func pushClock(
        to deviceID: String,
        at date: Date = Date(),
        timeout: TimeInterval = 12
    ) async throws -> ClockSyncResult {
        try await runClockSession(
            deviceID: deviceID,
            date: date,
            timeout: timeout,
            writeEnabled: true
        )
    }

    /// 只读设备时钟，不写入。用于确认设备是否已经校时。
    public func readClock(
        from deviceID: String,
        timeout: TimeInterval = 12
    ) async throws -> ClockSyncResult {
        try await runClockSession(
            deviceID: deviceID,
            date: Date(),
            timeout: timeout,
            writeEnabled: false
        )
    }

    private func runClockSession(
        deviceID: String,
        date: Date,
        timeout: TimeInterval,
        writeEnabled: Bool
    ) async throws -> ClockSyncResult {
        await gattGate.acquire()
        defer { gattGate.release() }

        guard central.state == .poweredOn else { throw GATTProbeError.notScanning }
        let peripheral = try resolvePeripheral(for: deviceID)
        let peripheralID = peripheral.identifier

        central.stopScan()
        let session = TimeSyncSession(
            peripheral: peripheral,
            deviceID: deviceID,
            date: date,
            timeout: timeout,
            writeEnabled: writeEnabled
        )
        timeSyncSessions[peripheralID] = session
        central.connect(peripheral, options: nil)

        do {
            let result = try await session.run()
            central.cancelPeripheralConnection(peripheral)
            timeSyncSessions.removeValue(forKey: peripheralID)
            scanIfPossible()
            return result
        } catch {
            central.cancelPeripheralConnection(peripheral)
            timeSyncSessions.removeValue(forKey: peripheralID)
            scanIfPossible()
            throw error
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let id = peripheral.identifier
        BLEScannerDiagnostics.log("GATT connected -> \(id.uuidString)")
        if let session = timeSyncSessions[id] {
            // 连接完成后再发现服务：连接前 connect 尚未生效，discoverServices 会失败。
            peripheral.delegate = session
            session.markConnected()
        } else if let session = sampleSessions[id] {
            // Bind this peripheral to the session created for *it*. A shared
            // session let one device's callbacks feed the other device's read.
            peripheral.delegate = session
            peripheral.discoverServices([
                CustomSampleSession.serviceUUID,
                CustomSampleSession.mirrorServiceUUID
            ])
        } else if let session = probeSessions[id] {
            session.markConnected()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        let reason = error?.localizedDescription ?? "连接失败"
        if let session = sampleSessions.removeValue(forKey: id) {
            session.markDisconnected(reason)
        }
        if let session = probeSessions.removeValue(forKey: id) {
            session.markDisconnected(reason)
        }
        if let session = timeSyncSessions.removeValue(forKey: id) {
            session.markDisconnected(reason)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        let id = peripheral.identifier
        let reason = error?.localizedDescription ?? "设备断开"
        if let session = sampleSessions.removeValue(forKey: id) {
            session.markDisconnected(reason)
        }
        if let session = probeSessions.removeValue(forKey: id) {
            session.markDisconnected(reason)
        }
        if let session = timeSyncSessions.removeValue(forKey: id) {
            session.markDisconnected(reason)
        }
    }

    public func setBindkey(_ key: Data?, for deviceID: String) {
        bindkeys[deviceID.uppercased()] = key
        lastProblems.removeValue(forKey: deviceID.uppercased())
    }

    /// `CBPeripheral.identifier` is only a placeholder identity used until a
    /// frame carrying a MAC arrives. Once that MAC is cached, every UUID-based
    /// lookups collapses onto the MAC-based ID so a single sensor never keeps
    /// two rows (and two poll loops) side by side.
    public func canonicalDeviceID(for deviceID: String) -> String {
        guard let uuid = UUID(uuidString: deviceID),
              let mac = knownMACs[uuid],
              mac.count == 6 else {
            return deviceID
        }
        return mac.reversed()
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    public func removeAllBindkeys() {
        bindkeys.removeAll()
    }

    private func scanIfPossible() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        onStatusChange?(.scanning)
        scheduleFallbackScan()
    }

    private func scheduleFallbackScan() {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, central.state == .poweredOn else {
                return
            }
            // A few compatible firmwares advertise FE95 only as Service Data.
            // Broaden the CoreBluetooth filter when the fast filtered scan is silent.
            central.stopScan()
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let rawState = central.state.rawValue
        MainActor.assumeIsolated {
            let state = CBManagerState(rawValue: rawState) ?? .unknown
            switch state {
            case .poweredOn:
                scanIfPossible()
            case .poweredOff:
                onStatusChange?(.poweredOff)
            case .unauthorized:
                onStatusChange?(.unauthorized)
            case .unsupported:
                onStatusChange?(.unsupported)
            case .resetting:
                onStatusChange?(.resetting)
            case .unknown:
                onStatusChange?(.unknown)
            @unknown default:
                onStatusChange?(.unknown)
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        MainActor.assumeIsolated {
            if self.central.state == .poweredOn { scanIfPossible() }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Copy value types before entering the actor-isolated closure. With a nil
        // dispatch queue CoreBluetooth already calls us on the main thread.
        let peripheralID = peripheral.identifier
        let peripheralBox = PeripheralBox(peripheral)
        let peripheralName = peripheral.name
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey]
            as? [CBUUID: Data]
        let characteristicServices = advertisementData[CBAdvertisementDataServiceUUIDsKey]
            as? [CBUUID]
        let overflowServices = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey]
            as? [CBUUID]
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
            as? Data

        // Diagnostics: CoreBluetooth can silently drop service data, so record
        // what actually arrived before deciding whether this frame is usable.
        let summary = advertisementData
            .map { key, value -> String in
                if let data = value as? Data { return "\(key)=\(data.count)B" }
                if let uuids = value as? [CBUUID] { return "\(key)=\(uuids.count)" }
                return "\(key)=\(value)"
            }
            .sorted()
            .joined(separator: " ")
        BLEScannerDiagnostics.log(
            "ADV \(peripheralID.uuidString) \(rssi)dBm \(summary)"
        )

        let packet = serviceData?[CBUUID(string: "FE95")]
        if packet == nil {
            let mentionsFE95 = characteristicServices?.contains(CBUUID(string: "FE95")) == true
                || overflowServices?.contains(CBUUID(string: "FE95")) == true
            if mentionsFE95 {
                BLEScannerDiagnostics.log(
                    "FE95 adv without service data: \(peripheralID.uuidString) mfg=\(manufacturerData?.count ?? 0)B"
                )
            }
            return
        }

        MainActor.assumeIsolated {
            discoveredPeripherals[peripheralID.uuidString] = peripheralID
            discoveredObjects[peripheralID] = peripheralBox.peripheral
            if let packet {
                // Also map the MAC-based device ID so probeGATT can resolve a
                // sensor by the identifier the UI shows.
                if let identity = try? MiBeaconParser.identify(
                    packet,
                    fallbackDeviceID: peripheralID.uuidString,
                    knownMACInWireOrder: knownMACs[peripheralID]
                ) {
                    discoveredPeripherals[identity.deviceID] = peripheralID
                }
                handleAdvertisement(
                    packet: packet,
                    peripheralID: peripheralID,
                    name: localName ?? peripheralName,
                    rssi: rssi
                )
            }
        }
    }

    private func handleAdvertisement(
        packet: Data,
        peripheralID: UUID,
        name: String?,
        rssi: Int
    ) {
        let fallbackID = peripheralID.uuidString
        let knownMAC = knownMACs[peripheralID]
        do {
            let identity = try MiBeaconParser.identify(
                packet,
                fallbackDeviceID: fallbackID,
                knownMACInWireOrder: knownMAC
            )
            let deviceID = identity.deviceID
            if let mac = identity.macInWireOrder {
                let learnedNewMAC = knownMACs[peripheralID] == nil
                knownMACs[peripheralID] = mac
                if learnedNewMAC && deviceID != fallbackID {
                    onDeviceIdentity?(fallbackID, deviceID)
                }
            }
            let key = bindkeys[deviceID.uppercased()]
                ?? bindkeys[fallbackID.uppercased()]
            let beacon = try MiBeaconParser.decode(
                packet,
                bindkey: key,
                fallbackDeviceID: fallbackID,
                knownMACInWireOrder: identity.macInWireOrder
            )
            onRawFrame?(RawSensorFrame(
                deviceID: deviceID,
                peripheralName: name,
                rssi: rssi,
                payload: packet,
                note: beacon.hasObject ? nil : "帧内没有 Object 字段",
                productID: beacon.productID,
                hasMeasurement: beacon.temperature != nil
                    || beacon.humidity != nil
                    || beacon.battery != nil
            ))
            guard beacon.hasObject else {
                let key = deviceID.uppercased()
                if lastProblems[key] != .noObjectInFrame {
                    lastProblems[key] = .noObjectInFrame
                    onProblem?(deviceID, .noObjectInFrame)
                }
                return
            }

            lastProblems.removeValue(forKey: deviceID.uppercased())
            let duplicate = lastFrames[deviceID] == packet
            lastFrames[deviceID] = packet

            onAdvertisement?(SensorAdvertisement(
                beacon: beacon,
                peripheralName: name,
                rssi: rssi,
                isDuplicate: duplicate
            ))
        } catch let error as MiBeaconError {
            let deviceID = (try? MiBeaconParser.deviceID(
                of: packet,
                fallbackDeviceID: fallbackID,
                knownMACInWireOrder: knownMACs[peripheralID]
            )) ?? fallbackID
            let key = deviceID.uppercased()
            guard lastProblems[key] != error else { return }
            lastProblems[key] = error
            onRawFrame?(RawSensorFrame(
                deviceID: deviceID,
                peripheralName: name,
                rssi: rssi,
                payload: packet,
                note: error.localizedDescription
            ))
            onProblem?(deviceID, error)
        } catch {
            let deviceID = fallbackID.uppercased()
            guard lastProblems[deviceID] != .malformedObject else { return }
            lastProblems[deviceID] = .malformedObject
            onRawFrame?(RawSensorFrame(
                deviceID: fallbackID,
                peripheralName: name,
                rssi: rssi,
                payload: packet,
                note: "无法识别的 MiBeacon 帧"
            ))
            onProblem?(fallbackID, .malformedObject)
        }
    }
}

/// Minimal FIFO gate. CoreBluetooth connects one peripheral at a time here:
/// a second `connect()` stops the scan the first session depends on, and each
/// session's `stopScan()` would abort the other's service discovery. Polling
/// tasks therefore take the gate around the whole connect/read/disconnect
/// sequence instead of racing each other.
@MainActor
final class AsyncGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
