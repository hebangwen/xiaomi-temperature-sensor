import CoreBluetooth
import Foundation

/// Connects to one sensor, walks every service and reads the characteristics
/// that are exposed without the Xiaomi authentication handshake.
@MainActor
final class GATTProbeSession: NSObject, @preconcurrency CBPeripheralDelegate {
    private let peripheral: CBPeripheral
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<String, Error>?
    private var lines: [String] = []
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false
    private var readableCount = 0

    init(peripheral: CBPeripheral, timeout: TimeInterval) {
        self.peripheral = peripheral
        self.timeout = timeout
        super.init()
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            peripheral.delegate = self
            BLEScannerDiagnostics.log("GATT connect -> \(peripheral.identifier.uuidString)")
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 20) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.success(self?.lines.joined(separator: "\n") ?? ""))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        let services = peripheral.services ?? []
        lines.append("device: \(peripheral.name ?? "?")\nservices: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            lines.append("  \(service.uuid.uuidString) error: \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        lines.append("\(service.uuid.uuidString):")
        for characteristic in characteristics {
            let props = describe(characteristic.properties)
            lines.append("  0x\(characteristic.uuid.uuidString) [\(props)]")
            if characteristic.properties.contains(.read) {
                readableCount += 1
                peripheral.readValue(for: characteristic)
            }
            if characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let raw = characteristic.value ?? Data()
        let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
        var line = "  read 0x\(characteristic.uuid.uuidString) = \(hex)"
        if let ascii, !ascii.isEmpty, ascii.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            line += "  \"\(ascii)\""
        }
        lines.append(line)
        if characteristic.properties.contains(.read) { readableCount -= 1 }
        scheduleFinishIfIdle()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lines.append("  notify 0x\(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        } else {
            lines.append("  notify 0x\(characteristic.uuid.uuidString) enabled")
        }
        scheduleFinishIfIdle()
    }

    private func scheduleFinishIfIdle() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !didFinish, readableCount <= 0 else { return }
            finish(.success(lines.joined(separator: "\n")))
        }
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }

    func markDisconnected(_ reason: String) {
        finish(.failure(GATTProbeError.disconnected(reason)))
    }

    func markConnected() {
        peripheral.discoverServices(nil)
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        BLEScannerDiagnostics.log("GATT probe finished: \(lines.count) lines")
        continuation?.resume(with: result)
        continuation = nil
    }
}
