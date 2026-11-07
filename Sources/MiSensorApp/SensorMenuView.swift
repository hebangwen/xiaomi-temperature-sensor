import AppKit
import SwiftUI

private let sensorAccent = Color(red: 0.20, green: 0.65, blue: 0.52)

struct SensorMenuView: View {
    @EnvironmentObject private var controller: SensorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.problems.isEmpty && controller.hasReceivedFrame
                          ? sensorAccent : .orange)
                    .frame(width: 8, height: 8)
                Text(controller.status)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
            }
            .padding(16)

            Divider()

            if controller.readings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 30))
                        .foregroundStyle(sensorAccent)
                    Text(controller.hasReceivedFrame ? "收到广播但未能解析" : "等待温湿度计广播")
                        .font(.headline)
                    if let problem = controller.problems.values.first {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(controller.hasReceivedFrame
                         ? "打开“设备与设置”查看最近一帧原始数据和设备标识。"
                         : "保持设备在 Mac 附近。原厂固件无需配对，也无需保持蓝牙连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.sortedReadings()) { reading in
                        SensorRow(reading: reading, problem: controller.problems[reading.deviceID])
                        if reading.deviceID != controller.sortedReadings().last?.deviceID {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }

            Divider()
            HStack {
                SettingsLink {
                    Label("设备与设置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()
                Button {
                    controller.reloadWidgets()
                } label: {
                    Label("刷新小组件", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("退出")
            }
            .padding(14)
        }
        .frame(width: 350)
        .tint(sensorAccent)
    }
}

private struct SensorRow: View {
    let reading: SensorReading
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(reading.displayName).font(.headline)
                Spacer()
                freshnessLabel
            }

            HStack(alignment: .firstTextBaseline, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(reading.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                        .font(.system(size: 42, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("℃").font(.title3).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(reading.humidity.map { String(format: "%.1f", $0) } ?? "--.-")
                        .font(.system(size: 25, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label {
                    if reading.hasMeasurements {
                        Text(reading.updatedAt, style: .relative)
                    } else {
                        Text("等待可解密广播")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
                if let battery = reading.battery {
                    Label("\(battery)%", systemImage: batteryIcon(level: battery))
                }
                if let rssi = reading.rssi {
                    Text("\(rssi) dBm")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var freshnessLabel: some View {
        if !reading.hasMeasurements {
            Label("连接读取中", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        } else {
            measuredFreshness
        }
    }

    @ViewBuilder
    private var measuredFreshness: some View {
        switch reading.freshness() {
        case .fresh:
            Label("在线", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(sensorAccent)
        case .aging:
            Label("较旧", systemImage: "circle.fill").foregroundStyle(.yellow)
        case .stale:
            Label("过期", systemImage: "circle.fill").foregroundStyle(.orange)
        }
    }

    private func batteryIcon(level: Int) -> String {
        if level > 75 { return "battery.100" }
        if level > 50 { return "battery.75" }
        if level > 25 { return "battery.50" }
        return "battery.25"
    }
}
