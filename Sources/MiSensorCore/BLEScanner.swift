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

/// Every FE95 frame the OS handed us, decoded or not. Used by the diagnostics UI
/// so a firmware the parser cannot read is still visible instead of silent.
public struct RawSensorFrame: Sendable {
    public let deviceID: String
    public let peripheralName: String?
    public let rssi: Int
    public let payload: Data
    public let note: String?
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
public final class BLEScanner: NSObject, @preconcurrency CBCentralManagerDelegate {    private let service = CBUUID(string: "FE95")
    private lazy var central = CBCentralManager(
        delegate: self,
        queue: nil,
        options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.example.MiSensor.central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ]
    )

    public var onStatusChange: ((BLEScannerStatus) -> Void)?
    public var onAdvertisement: ((SensorAdvertisement) -> Void)?
    public var onProblem: ((String, MiBeaconError) -> Void)?
    public var onDeviceIdentity: ((String, String) -> Void)?
    public var onRawFrame: ((RawSensorFrame) -> Void)?

    private var bindkeys: [String: Data] = [:]
    private var knownMACs: [UUID: Data] = [:]
    private var discoveredPeripherals: [String: UUID] = [:]
    private var probeSession: GATTProbeSession?
    private var sampleSession: CustomSampleSession?
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

    /// Connects to a discovered sensor and dumps its GATT tree. Used to check
    /// whether readings are available over a connection when advertisements
    /// carry no Object payload.
    public func probeGATT(for deviceID: String, timeout: TimeInterval = 20) async throws -> String {
        guard central.state == .poweredOn else { throw GATTProbeError.notScanning }
        guard let uuid = discoveredPeripherals[deviceID] else {
            throw GATTProbeError.peripheralUnavailable
        }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw GATTProbeError.peripheralUnavailable
        }

        central.stopScan()

        let session = GATTProbeSession(peripheral: peripheral, timeout: timeout)
        probeSession = session
        central.connect(peripheral, options: nil)
        do {
            let report = try await session.run()
            probeSession = nil
            scanIfPossible()
            return report
        } catch {
            probeSession = nil
            scanIfPossible()
            throw error
        }
    }

    /// Connects, reads one live sample from the custom sensor service and
    /// disconnects. Used when the advertisement carries no usable payload.
    public func readCustomSample(for deviceID: String, timeout: TimeInterval = 12) async throws -> CustomSensorSample {
        guard central.state == .poweredOn else { throw GATTProbeError.notScanning }
        guard let uuid = discoveredPeripherals[deviceID],
              let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw GATTProbeError.peripheralUnavailable
        }

        central.stopScan()
        let session = CustomSampleSession(peripheral: peripheral, timeout: timeout)
        sampleSession = session
        central.connect(peripheral, options: nil)

        do {
            let sample = try await session.run()
            central.cancelPeripheralConnection(peripheral)
            sampleSession = nil
            scanIfPossible()
            return sample
        } catch {
            central.cancelPeripheralConnection(peripheral)
            sampleSession = nil
            scanIfPossible()
            throw error
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let id = peripheral.identifier.uuidString
        BLEScannerDiagnostics.log("GATT connected -> \(id)")
        probeSession?.markConnected()
        if let sampleSession {
            peripheral.delegate = sampleSession
            peripheral.discoverServices([CustomSampleSession.serviceUUID])
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        probeSession?.markDisconnected(error?.localizedDescription ?? "连接失败")
        probeSession = nil
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        probeSession?.markDisconnected(error?.localizedDescription ?? "设备断开")
        probeSession = nil
        sampleSession?.markDisconnected(error?.localizedDescription ?? "设备断开")
        sampleSession = nil
    }

    public func setBindkey(_ key: Data?, for deviceID: String) {
        bindkeys[deviceID.uppercased()] = key
        lastProblems.removeValue(forKey: deviceID.uppercased())
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
                note: beacon.hasObject ? nil : "帧内没有 Object 字段"
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
