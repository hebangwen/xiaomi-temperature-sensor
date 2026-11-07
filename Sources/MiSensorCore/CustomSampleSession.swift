import CoreBluetooth
import Foundation

/// Reads one live temperature/humidity sample from the custom sensor service.
/// This path needs no Xiaomi bindkey because the characteristics are readable
/// without the authentication handshake.
@MainActor
final class CustomSampleSession: NSObject, @preconcurrency CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    static let mirrorServiceUUID = CBUUID(string: "8EDFFFF0-3D1B-9C37-4623-AD7265F14076")
    static let liveUUID = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")
    static let mirrorUUID = CBUUID(string: "8EDFFFEF-3D1B-9C37-4623-AD7265F14076")
    /// 1 字节电量（0-100），两族固件都有；`0x2A19` 恒返 99% 是假值。
    static let batteryUUID = CBUUID(string: "EBE0CCC4-7A0A-4B0C-8A1A-6FF2997DA3A6")

    private let peripheral: CBPeripheral
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CustomSensorSample, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false
    private var liveSample: CustomSensorSample?
    private var batteryPercent: Int?
    /// 仍在等待一次读回回调的特征（实时值 + 电量）。
    /// 谁先到都行，全部到齐或超时才结束，保证样本里带上电量。
    private var pendingReads: Set<CBUUID> = []
    private var liveHandled = false

    init(peripheral: CBPeripheral, timeout: TimeInterval) {
        self.peripheral = peripheral
        self.timeout = timeout
        super.init()
    }

    func run() async throws -> CustomSensorSample {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID, Self.mirrorServiceUUID])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 15) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(GATTProbeError.disconnected("读取超时")))
            }
        }
    }

    /// A sample is only valid for the peripheral this session was created for.
    /// Anything else means a delegate got bound to the wrong device and would
    /// write one sensor's reading under another sensor's name.
    private func isOwn(_ peripheral: CBPeripheral) -> Bool {
        guard peripheral.identifier == self.peripheral.identifier else {
            BLEScannerDiagnostics.log(
                "SAMPLE ignored callback from foreign peripheral \(peripheral.identifier.uuidString)"
            )
            return false
        }
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isOwn(peripheral) else { return }
        BLEScannerDiagnostics.log("SAMPLE services err=\(error?.localizedDescription ?? "none") found=\(peripheral.services?.map(\.uuid.uuidString).joined(separator: ",") ?? "-")")
        if let error {
            finish(.failure(error))
            return
        }
        let services = peripheral.services ?? []
        let targets = services.filter {
            $0.uuid == Self.serviceUUID || $0.uuid == Self.mirrorServiceUUID
        }
        guard !targets.isEmpty else {
            finish(.failure(GATTProbeError.noCharacteristic("自定义传感服务")))
            return
        }
        for service in targets {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isOwn(peripheral), error == nil else { return }
        BLEScannerDiagnostics.log("SAMPLE chars \(service.uuid.uuidString) = \((service.characteristics ?? []).map(\.uuid.uuidString).joined(separator: ","))")
        for characteristic in service.characteristics ?? [] {
            let uuid = characteristic.uuid
            let isLive = uuid == Self.liveUUID || uuid == Self.mirrorUUID
            let isBattery = uuid == Self.batteryUUID
            // LYWSD03MMC 会同时暴露 EBE0CCB0 的 CCC1 和镜像服务的 FFEF；取先到的那个。
            if isLive && liveHandled { continue }
            if !isLive && !isBattery { continue }
            if characteristic.properties.contains(.read) {
                pendingReads.insert(uuid)
                peripheral.readValue(for: characteristic)
                if isLive { liveHandled = true }
            } else if isLive,
                      characteristic.properties.contains(.notify)
                        || characteristic.properties.contains(.indicate) {
                // 只有 notify 的固件：订阅后靠通知结束会话。
                liveHandled = true
                pendingReads.insert(uuid)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isOwn(peripheral) else { return }
        let uuid = characteristic.uuid
        BLEScannerDiagnostics.log("SAMPLE value \(uuid.uuidString) err=\(error?.localizedDescription ?? "none") len=\(characteristic.value?.count ?? -1)")
        if error != nil {
            // 某族固件缺 CCC4 或读取拒绝：不影响温湿度样本本身。
            pendingReads.remove(uuid)
            completeIfReady()
            return
        }
        guard let value = characteristic.value else {
            pendingReads.remove(uuid)
            completeIfReady()
            return
        }
        if uuid == Self.liveUUID || uuid == Self.mirrorUUID {
            liveSample = CustomServiceParser.parseLive(value)
        } else if uuid == Self.batteryUUID {
            batteryPercent = CustomServiceParser.parseBattery(value)
        }
        pendingReads.remove(uuid)
        completeIfReady()
    }

    /// 实时值是必要条件；电量读没读到都放行，避免 CCC4 缺失的固件白等。
    private func completeIfReady() {
        guard let sample = liveSample else { return }
        guard pendingReads.isEmpty else { return }
        finish(.success(CustomSensorSample(
            temperature: sample.temperature,
            humidity: sample.humidity,
            batteryMillivolts: sample.batteryMillivolts,
            batteryPercent: batteryPercent,
            timestamp: sample.timestamp
        )))
    }

    func markDisconnected(_ reason: String) {
        finish(.failure(GATTProbeError.disconnected(reason)))
    }

    private func finish(_ result: Result<CustomSensorSample, Error>) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
