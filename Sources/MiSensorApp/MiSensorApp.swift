import SwiftUI

@main
struct MiSensorApp: App {
    @StateObject private var controller = SensorController()

    var body: some Scene {
        MenuBarExtra {
            SensorMenuView()
                .environmentObject(controller)
        } label: {
            if let temperature = controller.sortedReadings()
                .max(by: { $0.updatedAt < $1.updatedAt })?.temperature {
                // 与弹层/小组件同一口径（忽略的设备不参与），
                // 避免菜单图标单独冒出被隐藏的设备。
                Text(String(format: "%.1f°", temperature))
            } else {
                Image(systemName: "thermometer.medium")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SensorSettingsView()
                .environmentObject(controller)
        }
    }
}
