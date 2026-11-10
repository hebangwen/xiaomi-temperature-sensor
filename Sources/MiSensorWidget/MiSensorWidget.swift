import AppIntents
import SwiftUI
import WidgetKit
import os

/// 一次时间线刷新失败的原子里快照：主 App 写入的传感器读数列表。
struct SensorEntry: TimelineEntry {
    let date: Date
    let readings: [SensorReading]
}

/// TimelineProvider 的 completion 回调不是 @Sendable；把它装进 unchecked盒子
/// 交给 Task 一次性回传（实际只回传一次，无并发修改）。
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

struct SensorProvider: TimelineProvider {
    private let logger = Logger(
        subsystem: "com.example.MiSensor", category: "WidgetData"
    )

    func placeholder(in context: Context) -> SensorEntry {
        SensorEntry(date: Date(), readings: [.preview])
    }

    func getSnapshot(in context: Context, completion: @escaping (SensorEntry) -> Void) {
        let box = UncheckedSendableBox(completion)
        Task { box.value(await loadEntry()) }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SensorEntry>) -> Void
    ) {
        let box = UncheckedSendableBox(completion)
        Task {
            let entry = await loadEntry()
            // 主 App 每次读到新数据都会立即落盘；小组件最多 15 分钟落后一次。
            let nextReload = Date().addingTimeInterval(15 * 60)
            box.value(Timeline(entries: [entry], policy: .after(nextReload)))
        }
    }

    /// 通道 1：本机 HTTP 快照。ad-hoc 环境下扩展沙盒拒绝读 App Group 容器
    /// 文件（containermanagerd 要求 group 前缀 == Team ID），cfprefsd 的
    /// group suite 又是各容器私有视图，出站网络也需要显式
    /// `com.apple.security.network.client` entitlement，所以主 App 在
    /// 127.0.0.1 固定端口提供 /snapshot，这里直接拉取。
    /// 通道 2：将来带真实 Team 签名后，App Group 文件可读，走
    /// `SensorSnapshotStore` 文件 / suite 镜像路径。
    private func loadEntry() async -> SensorEntry {
        // App 重启窗口期扩展可能跑到监听就绪之前（连接被拒），
        // 这里的两次尝试用来抹掉那几秒的竞态。
        var readings = await Self.fetchOverLocalHTTP(retryingOnRefused: true)
        var channel = "http"
        if readings.isEmpty {
            let store = SensorSnapshotStore()
            readings = (store?.loadAll() ?? [:]).values
                .filter { $0.hasMeasurements }
                .sorted { $0.updatedAt > $1.updatedAt }
            channel = "store"
        }
        if readings.isEmpty {
            logger.error(
                "widget load: both channels empty (http + App Group store)"
            )
        } else {
            logger.info(
                "widget load: channel=\(channel, privacy: .public) readings=\(readings.count, privacy: .public)"
            )
        }
        return SensorEntry(date: Date(), readings: readings)
    }

    private static func fetchOverLocalHTTP(retryingOnRefused: Bool = false) async -> [SensorReading] {
        guard let url = URL(string: "http://127.0.0.1:\(LocalSnapshotChannel.port)/snapshot") else {
            return []
        }
        let fetchLogger = Logger(
            subsystem: "com.example.MiSensor", category: "WidgetData"
        )
        var config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = retryingOnRefused ? 10 : 4
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let dict = SensorSnapshotStore.decode(data) {
                return dict.values
                    .filter { $0.hasMeasurements }
                    .sorted { $0.updatedAt > $1.updatedAt }
            }
            fetchLogger.error(
                "widget http: status=\(status, privacy: .public) decode failed bytes=\(data.count, privacy: .public)"
            )
            return []
        } catch let error as NSError {
            fetchLogger.error(
                "widget http: error domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
            )
            if retryingOnRefused,
               error.domain == NSURLErrorDomain,
               error.code == NSURLErrorCannotConnectToHost {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return await fetchOverLocalHTTP()
            }
            return []
        }
    }
}

struct MiSensorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SensorEntry

    /// 点击小组件聚焦对应设备（大尺寸聚焦整个列表）。
    private func deepLink(_ deviceID: String?) -> URL? {
        guard let deviceID,
              let encoded = deviceID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
              ) else { return URL(string: "misensor://app") }
        return URL(string: "misensor://device/\(encoded)")
    }

    var body: some View {
        Group {
            if let reading = entry.readings.first {
                switch family {
                case .systemMedium:
                    MediumSensorView(reading: reading, date: entry.date)
                        .widgetURL(deepLink(reading.deviceID))
                case .systemLarge:
                    LargeSensorList(readings: entry.readings, date: entry.date)
                        .widgetURL(URL(string: "misensor://app"))
                default:
                    SmallSensorView(reading: reading, date: entry.date)
                        .widgetURL(deepLink(reading.deviceID))
                }
            } else {
                EmptySensorView()
            }
        }
        .containerBackground(WidgetPalette.background, for: .widget)
    }
}

/// 小组件右上角的「点击刷新」：
/// 扩展进程发分布式通知，主 App 收到后立即对全部设备发起一轮 GATT 采样；
/// 采样成功会落盘并触发本小组件时间线重载（主 App persist() 内置）。
struct RefreshSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "点击刷新"
    static let description = IntentDescription(
        "让菜单栏 App 立即读取一次最新温湿度"
    )

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().post(
                name: NSNotification.Name(RefreshSignal.notificationName),
                object: nil
            )
        return .result()
    }
}

private enum WidgetPalette {
    static let background = Color(red: 0.047, green: 0.145, blue: 0.141)
    static let primary = Color(red: 0.93, green: 0.97, blue: 0.95)
    static let secondary = Color(red: 0.63, green: 0.73, blue: 0.69)
    static let accent = Color(red: 0.42, green: 0.87, blue: 0.70)
    static let warning = Color(red: 1.0, green: 0.67, blue: 0.32)
}

private func statusColor(for reading: SensorReading, at date: Date) -> Color {
    reading.freshness(at: date) == .stale ? WidgetPalette.warning : WidgetPalette.accent
}

private struct SmallSensorView: View {
    let reading: SensorReading
    let date: Date

    /// 右上角小刷新按钮（interactive widget）：立即让主 App 采一次数据。
    private var refreshButton: some View {
        Button(intent: RefreshSnapshotIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WidgetPalette.secondary)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(reading.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                refreshButton
                Circle()
                    .fill(statusColor(for: reading, at: date))
                    .frame(width: 7, height: 7)
            }

            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(reading.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text("℃").font(.title3).foregroundStyle(WidgetPalette.secondary)
            }
            .foregroundStyle(WidgetPalette.primary)

            Label(
                reading.humidity.map { String(format: "%.1f%%", $0) } ?? "--.-%",
                systemImage: "humidity.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(WidgetPalette.accent)

            Spacer(minLength: 0)
            SensorFooter(reading: reading, date: date)
        }
    }
}

private struct MediumSensorView: View {
    let reading: SensorReading
    let date: Date

    /// 右上角小刷新按钮（interactive widget）：立即让主 App 采一次数据。
    private var refreshButton: some View {
        Button(intent: RefreshSnapshotIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WidgetPalette.secondary)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(reading.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                    Spacer()
                    refreshButton
                    Circle()
                        .fill(statusColor(for: reading, at: date))
                        .frame(width: 7, height: 7)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(reading.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                    Text("℃").font(.title3).foregroundStyle(WidgetPalette.secondary)
                }
                .foregroundStyle(WidgetPalette.primary)
                Spacer()
                SensorFooter(reading: reading, date: date)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(WidgetPalette.secondary.opacity(0.25))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(reading.humidity.map { String(format: "%.1f%%", $0) } ?? "--.-%")
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                } icon: {
                    Image(systemName: "humidity.fill")
                }
                .foregroundStyle(WidgetPalette.accent)

                if let battery = reading.battery {
                    Label("\(battery)% 电量", systemImage: "battery.50")
                        .font(.callout)
                        .foregroundStyle(WidgetPalette.primary)
                }
                if let rssi = reading.rssi {
                    Label("\(rssi) dBm", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.secondary)
                }
                Spacer()
            }
            .frame(width: 120, alignment: .leading)
        }
    }
}

/// 大尺寸桌面小组件：列出主 App 看到的所有温湿度计。
private struct LargeSensorList: View {
    let readings: [SensorReading]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("米家温湿度")
                    .font(.headline)
                    .foregroundStyle(WidgetPalette.primary)
                Spacer()
                Text("\(readings.count) 台设备")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.secondary)
            }

            ForEach(readings.prefix(4), id: \.deviceID) { reading in
                DeviceRow(reading: reading, date: date)
                if reading.deviceID != readings.prefix(4).last?.deviceID {
                    Divider()
                        .overlay(WidgetPalette.secondary.opacity(0.2))
                }
            }

            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                Text("数据来自菜单栏 App")
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(WidgetPalette.secondary)
        }
    }
}

private struct DeviceRow: View {
    let reading: SensorReading
    let date: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor(for: reading, at: date))
                .frame(width: 6, height: 6)
            Text(reading.displayName)
                .font(.callout.weight(.medium))
                .foregroundStyle(WidgetPalette.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(reading.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("℃")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.secondary)
            }
            .foregroundStyle(WidgetPalette.primary)
            Text(reading.humidity.map { String(format: "%.0f%%", $0) } ?? "--%")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.accent)
        }
    }
}

private struct SensorFooter: View {
    let reading: SensorReading
    let date: Date

    var body: some View {
        HStack(spacing: 5) {
            if reading.freshness(at: date) == .stale {
                Text("数据过期").foregroundStyle(WidgetPalette.warning)
            } else {
                Text(reading.updatedAt, style: .relative)
            }
            Spacer(minLength: 0)
            if let battery = reading.battery {
                Text("\(battery)%")
            }
        }
        .font(.caption2)
        .foregroundStyle(WidgetPalette.secondary)
        .lineLimit(1)
    }
}

private struct EmptySensorView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "thermometer.medium")
                .font(.largeTitle)
                .foregroundStyle(WidgetPalette.accent)
            Spacer()
            Text("等待温湿度数据")
                .font(.headline)
                .foregroundStyle(WidgetPalette.primary)
            Text("打开菜单栏 App 并允许蓝牙权限")
                .font(.caption)
                .foregroundStyle(WidgetPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MiSensorWidget: Widget {
    let kind = "MiSensorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SensorProvider()) { entry in
            MiSensorWidgetView(entry: entry)
        }
        .configurationDisplayName("米家温湿度")
        .description("显示米家温湿度计最近一次广播的温湿度数据。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct MiSensorWidgetBundle: WidgetBundle {
    var body: some Widget {
        MiSensorWidget()
    }
}

private extension SensorReading {
    static var preview: SensorReading {
        SensorReading(
            deviceID: "preview",
            displayName: "客厅",
            temperature: 23.6,
            humidity: 48.2,
            battery: 86,
            rssi: -62,
            updatedAt: Date()
        )
    }
}
