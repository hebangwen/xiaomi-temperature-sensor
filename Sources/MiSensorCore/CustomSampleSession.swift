import CoreBluetooth
import Foundation

/// Reads one live temperature/humidity sample from the custom sensor service.
/// This path needs no Xiaomi bindkey because the characteristics are readable
/// without the authentication handshake.
@MainActor
final class CustomSampleSession: NSObject, @preconcurrency CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    static let liveUUID = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")
    static let mirrorUUID = CBUUID(string: "8EDFFFEF-3D1B-9C37-4623-AD7265F14076")

    private let peripheral: CBPeripheral
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CustomSensorSample, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(peripheral: CBPeripheral, timeout: TimeInterval) {
        self.peripheral = peripheral
        self.timeout = timeout
        super.init()
    }

    func run() async throws -> CustomSensorSample {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID, CBUUID(string: "8EDFFFF0-3D1B-9C37-4623-AD7265F14076")])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 15) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(GATTProbeError.disconnected("读取超时")))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        BLEScannerDiagnostics.log("SAMPLE services err=\(error?.localizedDescription ?? "none") found=\(peripheral.services?.map(\.uuid.uuidString).joined(separator: ",") ?? "-")")
        if let error {
            finish(.failure(error))
            return
        }
        let services = peripheral.services ?? []
        let targets = services.filter {
            $0.uuid == Self.serviceUUID || $0.uuid == CBUUID(string: "8EDFFFF0-3D1B-9C37-4623-AD7265F14076")
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
        guard error == nil else { return }
        BLEScannerDiagnostics.log("SAMPLE chars \(service.uuid.uuidString) = \((service.characteristics ?? []).map(\.uuid.uuidString).joined(separator: ","))")
        guard let characteristic = (service.characteristics ?? []).first(where: {
            $0.uuid == Self.liveUUID || $0.uuid == Self.mirrorUUID
        }) else { return }
        if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        } else if characteristic.properties.contains(.notify)
                    || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        BLEScannerDiagnostics.log("SAMPLE value \(characteristic.uuid.uuidString) err=\(error?.localizedDescription ?? "none") len=\(characteristic.value?.count ?? -1)")
        guard error == nil, let value = characteristic.value else { return }
        guard let sample = CustomServiceParser.parseLive(value) else { return }
        finish(.success(sample))
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
