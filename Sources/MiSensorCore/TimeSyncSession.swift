import CoreBluetooth
import Foundation

public enum ClockSyncError: Error, Equatable, LocalizedError {
    case noClockCharacteristic
    case writeFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .noClockCharacteristic:
            "该固件没有可写的时钟特征（EBE0CCB7 / FE95 0x0020），无法校时"
        case .writeFailed(let reason):
            "写入设备时钟失败：\(reason)"
        case .timedOut:
            "校时超时：连接或回读没有在限定时间内完成"
        }
    }
}

/// 把 Mac 当前时间写进温湿度计，也就是“充当蓝牙网关”。
///
/// 时序（原厂固件，无需 bindkey）：
///
/// 1. 连接后读 `EBE0CCB7` 拿设备自报时钟（未校时设备会给出 1973 年前后的值）；
/// 2. 按设备特征长度（4 或 6 字节）**等长**写入小端 Unix 秒；
/// 3. 立刻回读 `EBE0CCB7`，与写入值比较，偏差 ≤ 30 秒即视为固件接受；
/// 4. 顺带读 `EBE0CCBB`，把历史缓冲里残留的旧时间戳一并回报（校时不会改写历史）。
///
/// `FE95/0x0020` 是标准 MiBeacon 校时特征，只有暴露该特征的固件才会走这条路，
/// 而且无法回读校验。
@MainActor
final class TimeSyncSession: NSObject, @preconcurrency CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    static let clockUUID = CBUUID(string: ClockProtocol.customClockCharacteristic)
    static let recordUUID = CBUUID(string: ClockProtocol.customRecordCharacteristic)
    static let miServiceUUID = CBUUID(string: "FE95")
    static let miTimeUUID = CBUUID(string: ClockProtocol.miTimeCharacteristic)

    private let peripheral: CBPeripheral
    private let deviceID: String
    private let date: Date
    private let timeout: TimeInterval
    private let writeEnabled: Bool
    private var continuation: CheckedContinuation<ClockSyncResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false
    private var started = false

    private var expectedDiscoveries = 0
    private var resolvedDiscoveries = 0
    private var clockCharacteristic: CBCharacteristic?
    private var recordCharacteristic: CBCharacteristic?
    private var miTimeCharacteristic: CBCharacteristic?

    private var channel: ClockSyncResult.Channel = .customClock
    /// 本机时区偏移（秒）。设备时钟字段是「本地时间数值」，写入时要扣掉它。
    private var utcOffsetSeconds = 0
    /// 设备时钟特征的长度（4 或 6）。写入必须与之等长。
    private var clockFieldLength = 4
    private var pushedUnix: UInt32 = 0
    private var clockBefore: UInt32?
    private var recordUnix: UInt32?
    private var didWrite = false

    init(
        peripheral: CBPeripheral,
        deviceID: String,
        date: Date,
        timeout: TimeInterval,
        writeEnabled: Bool = true
    ) {
        self.peripheral = peripheral
        self.deviceID = deviceID
        self.date = date
        self.timeout = timeout
        self.writeEnabled = writeEnabled
        self.utcOffsetSeconds = ClockProtocol.utcOffsetSeconds(for: date)
        super.init()
    }

    func run() async throws -> ClockSyncResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 12) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ClockSyncError.timedOut))
            }
        }
    }

    /// 由 `CBCentralManagerDelegate` 在连接建好后调用。连接前发现服务会直接失败。
    func markConnected() {
        guard !started else { return }
        started = true
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID, Self.miServiceUUID])
    }

    func markDisconnected(_ reason: String) {
        finish(.failure(GATTProbeError.disconnected(reason)))
    }

    /// 回调只接受本会话的连接，避免多设备轮询时把别台设备的读写算到自己头上。
    private func isOwn(_ peripheral: CBPeripheral) -> Bool {
        guard peripheral.identifier == self.peripheral.identifier else {
            BLEScannerDiagnostics.log(
                "CLOCK ignored callback from foreign peripheral \(peripheral.identifier.uuidString)"
            )
            return false
        }
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isOwn(peripheral) else { return }
        if let error {
            finish(.failure(error))
            return
        }
        let services = (peripheral.services ?? []).filter {
            $0.uuid == Self.serviceUUID || $0.uuid == Self.miServiceUUID
        }
        BLEScannerDiagnostics.log(
            "CLOCK services found=\(services.map(\.uuid.uuidString).joined(separator: ","))"
        )
        expectedDiscoveries = services.count
        guard expectedDiscoveries > 0 else {
            finish(.failure(ClockSyncError.noClockCharacteristic))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isOwn(peripheral) else { return }
        let characteristics = service.characteristics ?? []
        BLEScannerDiagnostics.log(
            "CLOCK chars \(service.uuid.uuidString) = \(characteristics.map(\.uuid.uuidString).joined(separator: ","))"
        )
        switch service.uuid {
        case Self.serviceUUID:
            clockCharacteristic = characteristics.first {
                $0.uuid == Self.clockUUID && $0.properties.contains(.write)
            }
            recordCharacteristic = characteristics.first { $0.uuid == Self.recordUUID }
        case Self.miServiceUUID:
            miTimeCharacteristic = characteristics.first {
                $0.uuid == Self.miTimeUUID && $0.properties.contains(.write)
            }
        default:
            break
        }
        resolvedDiscoveries += 1
        guard resolvedDiscoveries >= expectedDiscoveries else { return }
        startSync()
    }

    private func startSync() {
        if let clockCharacteristic {
            channel = .customClock
            peripheral.readValue(for: clockCharacteristic)
        } else if !writeEnabled {
            finish(.failure(ClockSyncError.noClockCharacteristic))
        } else if let miTimeCharacteristic {
            channel = .miTime
            BLEScannerDiagnostics.log("CLOCK falling back to FE95/0x0020")
            writeMiTime(to: miTimeCharacteristic)
        } else {
            finish(.failure(ClockSyncError.noClockCharacteristic))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isOwn(peripheral), error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.clockUUID:
            let clock = ClockProtocol.decodeCustomClock(value)
            clockFieldLength = value.count
            if !didWrite, clock == nil {
                finish(.failure(ClockSyncError.noClockCharacteristic))
            } else if !didWrite, !writeEnabled {
                clockBefore = clock
                finish(.success(result(clockAfter: clock, writePerformed: false)))
            } else if !didWrite {
                clockBefore = clock
                writeCustomClock()
            } else {
                finish(.success(result(clockAfter: clock)))
            }
        case Self.recordUUID:
            recordUnix = ClockProtocol.recordTimestamp(fromRecord: value)
        default:
            break
        }
    }

    private func writeCustomClock() {
        guard let clockCharacteristic else { return }
        // 设备字段就是 Unix 秒，屏幕直接显示它；不要扣时区。
        let deviceValue = ClockProtocol.deviceClockValue(
            unix: ClockProtocol.unixSeconds(from: date),
            utcOffsetSeconds: utcOffsetSeconds
        )
        pushedUnix = deviceValue
        didWrite = true
        let payload = ClockProtocol.encodeCustomClock(
            deviceValue: deviceValue,
            fieldLength: clockFieldLength,
            utcOffsetHours: ClockProtocol.hourOffset(for: date)
        )
        BLEScannerDiagnostics.log("CLOCK write \(payload.count)B to EBE0CCB7 (field=\(clockFieldLength))")
        peripheral.writeValue(payload, for: clockCharacteristic, type: .withResponse)
    }

    private func writeMiTime(to characteristic: CBCharacteristic) {
        let unix = ClockProtocol.unixSeconds(from: date)
        pushedUnix = unix
        // UTC+8 用 8；设备按“秒 + 时区”自行换算本地日期，与本机时区无关。
        // 标准 MiBeacon 校时由固件自己换算时区，这里传原始 Unix 秒。
        let payload = ClockProtocol.encodeMiTime(
            unix: unix,
            utcOffsetHours: ClockProtocol.hourOffset(for: date)
        )
        didWrite = true
        peripheral.writeValue(payload, for: characteristic, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isOwn(peripheral) else { return }
        if let error {
            finish(.failure(ClockSyncError.writeFailed(error.localizedDescription)))
            return
        }
        BLEScannerDiagnostics.log("CLOCK write ack \(characteristic.uuid.uuidString)")
        switch channel {
        case .customClock:
            // 立刻回读做校验，同时把历史记录里的时间戳一起取回来。
            if let clockCharacteristic {
                peripheral.readValue(for: clockCharacteristic)
            }
            if let recordCharacteristic, recordUnix == nil {
                peripheral.readValue(for: recordCharacteristic)
            }
        case .miTime:
            finish(.success(result(clockAfter: nil)))
        }
    }

    private func result(clockAfter: UInt32?, writePerformed: Bool = true) -> ClockSyncResult {
        ClockSyncResult(
            deviceID: deviceID,
            channel: channel,
            pushedUnix: pushedUnix,
            pushedAt: date,
            clockBefore: clockBefore,
            clockAfter: clockAfter,
            recordUnix: recordUnix,
            writePerformed: writePerformed,
            utcOffsetSeconds: utcOffsetSeconds
        )
    }

    private func finish(_ result: Result<ClockSyncResult, Error>) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
