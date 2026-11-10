import Foundation

/// 「点击刷新」的跨沙盒信号：小组件扩展的 AppIntent 只能发这一个分布式通知，
/// 主 App 的 `SensorController.installRefreshSignalObserver()` 收到后执行
/// `refreshAll()`（立即对所有受跟踪设备发起一轮 GATT 采样）。
public enum RefreshSignal {
    public static let notificationName = "com.example.MiSensor.refreshRequest"
}
