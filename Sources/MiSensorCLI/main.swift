import Foundation
import MiSensorCore

/// 命令行网关：扫描温湿度计、读设备时钟、把 Mac 当前时间写进设备。
///
/// ```bash
/// swift run MiSensorCLI scan                      # 列出附近广播 FE95 的设备
/// swift run MiSensorCLI clock --name LYWSD03MMC   # 只读设备时钟
/// swift run MiSensorCLI sync  --name LYWSD03MMC   # 推送当前时间并回读校验
/// ```
///
/// 退出码：0 成功（写入并回读一致）、1 写入未被接受、2 失败、3 超时。

@MainActor
private final class ExitBox {
    var code: Int32?
}

@MainActor
private final class Capture {
    var devices: [String: String] = [:]
    var order: [String] = []
    var temperatures: [String: String] = [:]

    func note(deviceID: String, name: String?) {
        if devices[deviceID] == nil {
            order.append(deviceID)
            devices[deviceID] = name ?? ""
        } else if devices[deviceID]?.isEmpty == true, let name {
            devices[deviceID] = name
        }
    }
}

private func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

@MainActor
private func makeScanner(_ capture: Capture) -> BLEScanner {
    let scanner = BLEScanner(restoreIdentifier: nil)
    scanner.onStatusChange = { status in
        if status != .scanning {
            print("蓝牙状态：\(status.rawValue)")
        }
    }
    scanner.onRawFrame = { frame in
        let name = frame.peripheralName ?? ""
        capture.devices[frame.deviceID] = capture.devices[frame.deviceID] ?? name
        if capture.devices[frame.deviceID]?.isEmpty != false, !name.isEmpty {
            capture.devices[frame.deviceID] = name
        }
        if !capture.order.contains(frame.deviceID) {
            capture.order.append(frame.deviceID)
            let hex = frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("发现 \(frame.deviceID) \(name.isEmpty ? "(无名称)" : name) rssi=\(frame.rssi) 帧=\(hex)\(frame.note.map { " 备注=\($0)" } ?? "")")
        }
    }
    scanner.onAdvertisement = { advertisement in
        let beacon = advertisement.beacon
        capture.note(deviceID: beacon.deviceID, name: advertisement.peripheralName)
        let temperature = beacon.temperature.map { String(format: "%.1f℃", $0) } ?? "-"
        let humidity = beacon.humidity.map { String(format: "%.0f%%", $0) } ?? "-"
        let summary = "\(temperature) \(humidity)"
        guard capture.temperatures[beacon.deviceID] != summary else { return }
        capture.temperatures[beacon.deviceID] = summary
        print("广播 \(beacon.deviceID) \(advertisement.peripheralName ?? "(无名称)") \(summary)")
    }
    scanner.onProblem = { deviceID, error in
        print("注意 \(deviceID)：\(error.localizedDescription)")
    }
    scanner.start()
    return scanner
}

@MainActor
private func waitForDevice(
    _ capture: Capture,
    name: String?,
    identifier: String?,
    seconds: Double
) async -> String? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let identifier {
            if capture.order.contains(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) {
                return identifier
            }
        } else if let name {
            if let match = capture.order.first(where: {
                (capture.devices[$0] ?? "").localizedCaseInsensitiveContains(name)
            }) {
                return match
            }
        } else if let first = capture.order.first {
            return first
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    return nil
}

private func isoDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

@MainActor
private func run(arguments: [String]) async -> Int32 {
    let command = arguments.first ?? "sync"
    switch command {
    case "-h", "--help", "help":
        print("""
        用法：
          MiSensorCLI scan   [--seconds 12]
          MiSensorCLI clock [--name NAME | --id MAC] [--wait 25] [--timeout 15]
          MiSensorCLI sync  [--name NAME | --id MAC] [--wait 25] [--timeout 15] [--at ISO8601]
          MiSensorCLI probe [--name NAME | --id MAC] [--wait 25] [--timeout 20]
          MiSensorCLI sample [--name NAME | --id MAC] [--wait 25] [--timeout 15]
        说明：
          sample 会连接设备读一次实时温湿度 + 电量（EBE0CCC1 + EBE0CCC4）。
          sync 会写入设备时钟（EBE0CCB7，4 字节小端 Unix 秒），这是唯一改设备的操作。
        """)
        return 0
    case "scan", "clock", "sync", "probe", "sample":
        break
    default:
        print("未知命令：\(command)。用 --help 查看用法。")
        return 2
    }

    let name = option("--name", in: arguments)
    let identifier = option("--id", in: arguments)
    let waitSeconds = Double(option("--wait", in: arguments) ?? "") ?? 25
    let scanSeconds = Double(option("--seconds", in: arguments) ?? "") ?? 12
    let sessionTimeout = Double(option("--timeout", in: arguments) ?? "") ?? 15

    let capture = Capture()
    let scanner = makeScanner(capture)

    if command == "scan" {
        try? await Task.sleep(nanoseconds: UInt64(scanSeconds * 1_000_000_000))
        print("共发现 \(capture.order.count) 台 FE95 设备")
        return capture.order.isEmpty ? 1 : 0
    }

    guard name != nil || identifier != nil else {
        print("需要 --name 或 --id 指定设备（先运行 MiSensorCLI scan 查看）")
        return 2
    }

    guard let target = await waitForDevice(
        capture,
        name: name,
        identifier: identifier,
        seconds: waitSeconds
    ) else {
        print("在 \(Int(waitSeconds)) 秒内没有等到目标设备广播，请确认设备在附近且蓝牙已开启")
        return 3
    }
    print("目标设备：\(target) \(capture.devices[target] ?? "")")

    do {
        if command == "sample" {
            let reading = try await scanner.readCustomSample(for: target, timeout: sessionTimeout)
            let battery = reading.batteryPercent.map { ", battery=\($0)%" } ?? ""
            print(
                "RESULT device=\(target) temperature=\(String(format: "%.2f", reading.temperature))C" +
                String(format: " humidity=%.0f%%", reading.humidity) +
                " millivolts=\(reading.batteryMillivolts ?? 0)\(battery)"
            )
            return 0
        }

        if command == "probe" {
            let timeout = max(sessionTimeout, 20)
            let report = try await scanner.probeGATT(for: target, timeout: timeout)
            print(report)
            return 0
        }

        if command == "clock" {
            let result = try await scanner.readClock(from: target, timeout: sessionTimeout)
            print(result.summary)
            let wall = Int(Date().timeIntervalSince1970)
            print("RESULT device=\(result.deviceID) channel=\(result.channel.rawValue) before=\(result.clockBefore.map(String.init) ?? "-") wall=\(wall) write=false")
            return 0
        }

        let at = isoDate(option("--at", in: arguments)) ?? Date()
        let result = try await scanner.pushClock(to: target, at: at, timeout: sessionTimeout)
        print(result.summary)
        let before = result.clockBefore.map(String.init) ?? "-"
        let after = result.clockAfter.map(String.init) ?? "-"
        let drift = result.driftSeconds.map(String.init) ?? "-"
        let wall = Int(Date().timeIntervalSince1970)
        print("RESULT device=\(result.deviceID) channel=\(result.channel.rawValue) pushed=\(result.pushedUnix) before=\(before) after=\(after) drift=\(drift) wall=\(wall) verified=\(result.verified)")
        return result.verified ? 0 : 1
    } catch {
        print("失败：\(error.localizedDescription)")
        return 2
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
private let exitBox = ExitBox()

Task { @MainActor in
    exitBox.code = await run(arguments: arguments)
}

// 阻塞主线程执行 async 任务：CoreBluetooth 的回调走主队列，必须靠运行循环派发。
let hardDeadline = Date().addingTimeInterval(120)
while exitBox.code == nil, Date() < hardDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
exit(exitBox.code ?? 3)
