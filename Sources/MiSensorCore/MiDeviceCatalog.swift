import Foundation

/// 设备筛选与身份归一。
///
/// 扫描器订阅的是 `FE95` 服务数据，而小米生态里**不只是温湿度计**会用它：
/// 灯、开关、门锁、车钥匙都可能在 `FE95` 上广播。加上未绑定设备的帧里常常没有
/// MAC 段，身份只能退回 `CBPeripheral.identifier`，于是同一台设备会因为地址轮换
/// 出现「UUID 行 + MAC 行」两行。这个类型把两条规则集中起来，便于测试。
public enum MiDeviceCatalog {
    /// 实测确认的米家温湿度计 Product ID：
    /// `0x055B` = LYWSD03MMC（温湿度计 2），`0x2832` = MJWSD05MMC（温湿度计 3）。
    /// 新增型号时在这里补充，并同步补测试向量。
    public static let knownThermometerProductIDs: Set<UInt16> = [0x055B, 0x2832]

    public static func isKnownThermometer(productID: UInt16) -> Bool {
        knownThermometerProductIDs.contains(productID)
    }

    /// 身份是否只是 CoreBluetooth UUID 兜底（帧里没给出 MAC）。
    /// 这种 ID 每台 Mac 不同，地址轮换后还会再变，不能当稳定主键。
    public static func isProvisionalIdentity(_ deviceID: String) -> Bool {
        UUID(uuidString: deviceID) != nil
    }

    /// 判定两行读数是否像同一台设备。UUID 行与 MAC 行会同时存在，
    /// 数值相差一个采样间隔以内且行名是默认名时按同一台处理。
    public static let provisionalTemperatureTolerance = 1.0
    public static let provisionalHumidityTolerance = 5.0

    public static func looksLikeDuplicateRow(
        temperatureA: Double?,
        humidityA: Double?,
        temperatureB: Double?,
        humidityB: Double?
    ) -> Bool {
        guard let temperatureA, let humidityA,
              let temperatureB, let humidityB else { return false }
        return abs(temperatureA - temperatureB) <= provisionalTemperatureTolerance
            && abs(humidityA - humidityB) <= provisionalHumidityTolerance
    }
}
