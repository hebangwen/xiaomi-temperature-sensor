import SwiftUI

@main
struct MiSensorApp: App {
    @StateObject private var controller = SensorController()

    var body: some Scene {
        MenuBarExtra {
            SensorMenuView()
                .environmentObject(controller)
        } label: {
            if let temperature = controller.readings.values
                .max(by: { $0.updatedAt < $1.updatedAt })?.temperature {
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
