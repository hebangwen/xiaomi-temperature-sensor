import SwiftUI
import WidgetKit

struct SensorEntry: TimelineEntry {
    let date: Date
    let reading: SensorReading?
}

struct SensorProvider: TimelineProvider {
    func placeholder(in context: Context) -> SensorEntry {
        SensorEntry(date: Date(), reading: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SensorEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SensorEntry>) -> Void
    ) {
        let entry = loadEntry()
        let nextReload = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextReload)))
    }

    private func loadEntry() -> SensorEntry {
        let reading = SensorSnapshotStore()?.loadAll().values.max {
            $0.updatedAt < $1.updatedAt
        }
        return SensorEntry(date: Date(), reading: reading)
    }
}

struct MiSensorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SensorEntry

    var body: some View {
        Group {
            if let reading = entry.reading {
                switch family {
                case .systemMedium:
                    MediumSensorView(reading: reading, date: entry.date)
                default:
                    SmallSensorView(reading: reading, date: entry.date)
                }
            } else {
                EmptySensorView()
            }
        }
        .containerBackground(WidgetPalette.background, for: .widget)
    }
}

private enum WidgetPalette {
    static let background = Color(red: 0.047, green: 0.145, blue: 0.141)
    static let primary = Color(red: 0.93, green: 0.97, blue: 0.95)
    static let secondary = Color(red: 0.63, green: 0.73, blue: 0.69)
    static let accent = Color(red: 0.42, green: 0.87, blue: 0.70)
    static let warning = Color(red: 1.0, green: 0.67, blue: 0.32)
}

private struct SmallSensorView: View {
    let reading: SensorReading
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(reading.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor)
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

    private var statusColor: Color {
        reading.freshness(at: date) == .stale ? WidgetPalette.warning : WidgetPalette.accent
    }
}

private struct MediumSensorView: View {
    let reading: SensorReading
    let date: Date

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(reading.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                    Spacer()
                    Circle()
                        .fill(reading.freshness(at: date) == .stale ? WidgetPalette.warning : WidgetPalette.accent)
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
            Text("打开主 App 并允许蓝牙权限")
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
        .description("显示原厂米家温湿度计最近一次广播的数据。")
        .supportedFamilies([.systemSmall, .systemMedium])
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
