import Foundation

/// 原厂固件的时间接口。
///
/// 米家温湿度计本身没有联网能力：它的日时钟是**自行计时**的，出厂/重置后从
/// 一个内部基准开始累加。只有网关（米家 App、带蓝牙的网关，或者本项目这种
/// Mac 程序）主动把当前时间写进去，设备才会显示/记录正确日期。
///
/// 实测设备 `LYWSD03MMC` / `MJWSD05MMC`：
///
/// | 特征 | 属性 | 语义 |
/// |---|---|---|
/// | `EBE0CCB7` | read, write | 设备时钟，小端 32 位；`LYWSD03MMC` 4 字节，`MJWSD05MMC` 6 字节（尾部时区+0） |
/// | `EBE0CCBB` | read | 最近一条测量记录，偏移 4 的 4 字节是该记录的时间戳 |
/// | `EBE0CCBC` | notify | 小时级历史，同样带 4 字节时间戳 |
/// | `FE95/0x0020` | —— | 标准 MiBeacon 校时（4 字节秒 + 1 字节时区），这两个固件**未暴露** |
///
/// ## 时钟字段就是 Unix 秒（实测定案）
///
/// 设备内部存 32 位 Unix 秒，**屏幕直接显示这个值**，不做任何时区换算：
///
/// ```text
/// 内部值 1794056715（本地 21:05）→ 屏幕 21:05
/// 内部值 1794027902（= 21:05 − 28 800）→ 屏幕 13:05（慢 8 小时）
/// ```
///
/// 所以写入值就是 `Unix − 0`，`ClockProtocol.deviceClockValue` / `displayUnix`
/// 只是恒等映射，保留它们是为了让调用方显式表达“这里做过时区判断”。
///
/// 曾经踩过的坑：设备出现过「快 8 小时」的状态，写入值却是我们写的真实 Unix——
/// 那次不是本程序写的，而是米家 App 连接时把 `Unix + 8h` 写了进去。
/// 判断时钟对不对**只看设备屏幕**，不要拿米家 App 的显示当依据。
///
/// 未校时的设备读回的值落在 1973 年前后（`≈103 647 534`），因此首次校时前
/// 历史记录里的时间戳全部不可信；校时也不会回溯改写已经写好的历史缓冲。
public enum ClockProtocol {
    /// 自定义服务里可读写的设备时钟。
    public static let customClockCharacteristic = "EBE0CCB7-7A0A-4B0C-8A1A-6FF2997DA3A6"
    /// 最近一条测量记录（含记录时间戳）。
    public static let customRecordCharacteristic = "EBE0CCBB-7A0A-4B0C-8A1A-6FF2997DA3A6"
    /// Mi 服务里的标准校时特征。LYWSD03MMC 原厂固件没有这个特征。
    public static let miTimeCharacteristic = "0020"

    /// 回读值与推送值允许的偏差。写入后立刻回读，正常只有 0–3 秒。
    public static let readbackToleranceSeconds = 30

    /// 低于这个值的时间戳明显不是本世纪的 Unix 时间，说明设备时钟从未被设置。
    public static let plausibleUnixFloor: UInt32 = 1_600_000_000

    // MARK: - 时区换算

    /// 本机当前时区偏移（秒）。UTC+8 为 28 800。
    public static func utcOffsetSeconds(for date: Date) -> Int {
        TimeZone.current.secondsFromGMT(for: date)
    }

    /// 本机时区偏移，单位**小时**：设备 6 字节格式的时区字节实测就是小时数
    /// （UTC+8 设备自报 `08`，不是 `10`）。范围按有符号字节钳制。
    public static func hourOffset(for date: Date) -> Int8 {
        let raw = TimeZone.current.secondsFromGMT(for: date) / 3600
        return Int8(max(-24, min(24, raw)))
    }

    /// Unix 时刻 → 写进设备的数值。设备字段就是 Unix 秒，所以不扣时区。
    /// 保留 `utcOffsetSeconds` 参数是为了让调用方显式声明“这里判断过时区”。
    public static func deviceClockValue(unix: UInt32, utcOffsetSeconds: Int) -> UInt32 {
        unix
    }

    /// 设备数值 → 设备屏幕显示的时间戳。设备直接显示字段值，所以是恒等映射。
    public static func displayUnix(deviceValue: UInt32, utcOffsetSeconds: Int) -> UInt32 {
        deviceValue
    }

    private static func clamped(_ value: Int64) -> UInt32 {
        if value <= 0 { return 0 }
        if value > Int64(UInt32.max) { return .max }
        return UInt32(value)
    }

    // MARK: - 编解码

    /// `EBE0CCB7` 的写入载荷：32 位小端「本地时间数值」。
    ///
    /// 不同固件的这个特征长度不一样，**写入长度必须与设备一致**：
    /// `LYWSD03MMC`（4 字节）只认 4 字节；`MJWSD05MMC`（6 字节）只认 6 字节，
    /// 给它写 4 字节会被 ACK 但整帧被丢弃（实测时钟不动）。
    /// 6 字节格式为 `<u32 数值><u8 时区/小时><u8 0>`，实测设备自报 `08 00`（UTC+8）。
    public static func encodeCustomClock(
        deviceValue: UInt32,
        fieldLength: Int = 4,
        utcOffsetHours: Int8 = 8
    ) -> Data {
        var value = deviceValue.littleEndian
        var payload = Data(bytes: &value, count: 4)
        if fieldLength >= 6 {
            payload.append(UInt8(bitPattern: utcOffsetHours))
            payload.append(0)
        }
        return payload
    }

    /// 从设备读回的时钟原始值（不安全区，语义见类型注释）。
    public static func decodeCustomClock(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    /// 标准 MiBeacon 校时载荷：4 字节小端 Unix 秒 + 1 字节时区（小时，UTC+8 = `8`）。
    /// 这条路径由固件自己换算本地时间，所以**传原始 Unix 秒**，不要减时区。
    public static func encodeMiTime(unix: UInt32, utcOffsetHours: Int8 = 8) -> Data {
        var value = unix.littleEndian
        var payload = Data(bytes: &value, count: 4)
        payload.append(UInt8(bitPattern: utcOffsetHours))
        return payload
    }

    /// 系统时钟 → Unix 秒。设备只认 32 位，越界钳到位域两端。
    public static func unixSeconds(from date: Date) -> UInt32 {
        clamped(Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    /// 设备时钟是否已经是一个可信的当前时间。
    public static func looksSynchronized(_ unix: UInt32) -> Bool {
        unix >= plausibleUnixFloor
    }

    /// 从 `EBE0CCBB` / `EBE0CCBC` 的 14 字节记录里取时间戳（偏移 4）。
    /// 取值同样是「设备数值」，需要 `displayUnix` 换算才是真实时刻。
    public static func recordTimestamp(fromRecord data: Data) -> UInt32? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        return UInt32(bytes[4]) | UInt32(bytes[5]) << 8
            | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
    }
}

public struct ClockSyncResult: Equatable, Sendable {
    public enum Channel: String, Equatable, Sendable {
        case customClock = "EBE0CCB7"
        case miTime = "FE95/0x0020"
    }

    public let deviceID: String
    public let channel: Channel
    /// 实际写进设备的 32 位数值（= Unix − 时区偏移），不是 Unix 秒。
    public let pushedUnix: UInt32
    public let pushedAt: Date
    /// 本机时区偏移（秒），用于把设备数值换算成屏显时间。
    public let utcOffsetSeconds: Int
    /// 写入前设备自报的时钟（设备数值域）。
    public let clockBefore: UInt32?
    /// 写入后回读的时钟（设备数值域）。固件不回读时为 nil。
    public let clockAfter: UInt32?
    /// `EBE0CCBB` 里残留的历史记录时间戳（设备数值域）。
    public let recordUnix: UInt32?
    /// false 表示只读了设备时钟，没有写入。
    public let writePerformed: Bool

    public init(
        deviceID: String,
        channel: Channel,
        pushedUnix: UInt32,
        pushedAt: Date,
        clockBefore: UInt32?,
        clockAfter: UInt32?,
        recordUnix: UInt32?,
        writePerformed: Bool = true,
        utcOffsetSeconds: Int = 0
    ) {
        self.deviceID = deviceID
        self.channel = channel
        self.pushedUnix = pushedUnix
        self.pushedAt = pushedAt
        self.utcOffsetSeconds = utcOffsetSeconds
        self.clockBefore = clockBefore
        self.clockAfter = clockAfter
        self.recordUnix = recordUnix
        self.writePerformed = writePerformed
    }

    /// 设备屏幕会显示的时间（= 设备数值 + 时区偏移）。
    public var displayedUnix: UInt32 {
        let value = clockAfter ?? pushedUnix
        return ClockProtocol.displayUnix(deviceValue: value, utcOffsetSeconds: utcOffsetSeconds)
    }

    /// 写入前设备屏幕上的时间；未校时的设备会给出 1973 年前后的值。
    public var clockBeforeDisplayed: UInt32? {
        clockBefore.map {
            ClockProtocol.displayUnix(deviceValue: $0, utcOffsetSeconds: utcOffsetSeconds)
        }
    }

    /// 回读值与写入值之差（同一数值域，与时区无关）。正数表示设备走得比 Mac 快。
    public var driftSeconds: Int? {
        guard writePerformed, let clockAfter else { return nil }
        return Int(Int64(clockAfter) - Int64(pushedUnix))
    }

    /// 只有当设备回读并被判定为同一个时间点，才算推送成功。
    public var verified: Bool {
        guard let drift = driftSeconds else { return false }
        return abs(drift) <= ClockProtocol.readbackToleranceSeconds
    }

    /// 推送前设备时钟是否本身就是正确的当前时间（无需干预）。
    public var wasAlreadySynchronized: Bool {
        guard let before = clockBefore else { return false }
        // 设备数值域里，未校时的值同样远小于本世纪
        return ClockProtocol.looksSynchronized(before)
    }

    public var summary: String {
        let formatter = DeviceClockFormatter()
        guard writePerformed else {
            guard let deviceValue = clockAfter ?? clockBefore else {
                return "设备没有可读时钟（\(channel.rawValue) 缺失）"
            }
            let shown = ClockProtocol.displayUnix(
                deviceValue: deviceValue,
                utcOffsetSeconds: utcOffsetSeconds
            )
            let state = ClockProtocol.looksSynchronized(deviceValue)
                ? "已校时"
                : "尚未校时，记录里的日期不可信"
            return "设备屏显 \(formatter.string(fromUnix: shown))（未写入，\(state)）"
        }
        let shownAfterWrite = ClockProtocol.displayUnix(
            deviceValue: pushedUnix,
            utcOffsetSeconds: utcOffsetSeconds
        )
        var text = "已向 \(deviceID) 校时：设备屏显 \(formatter.string(fromUnix: shownAfterWrite))"
        text += "（\(channel.rawValue)，写入数值 \(pushedUnix)）"
        if let clockAfter, let drift = driftSeconds {
            if verified {
                text += "，回读一致，数值偏差 \(drift >= 0 ? "+" : "")\(drift) 秒"
            } else {
                let shown = ClockProtocol.displayUnix(
                    deviceValue: clockAfter,
                    utcOffsetSeconds: utcOffsetSeconds
                )
                text += "，回读后屏显 \(formatter.string(fromUnix: shown))，数值偏差 \(drift) 秒，固件未接受"
            }
        } else {
            text += "，固件不提供可回读时钟，写入已确认"
        }
        if let recordUnix, !ClockProtocol.looksSynchronized(recordUnix) {
            let shown = ClockProtocol.displayUnix(
                deviceValue: recordUnix,
                utcOffsetSeconds: utcOffsetSeconds
            )
            text += "；历史缓冲仍保留未校时前的时间戳（\(formatter.string(fromUnix: shown))），下一条记录起才使用新时钟"
        }
        return text
    }
}

/// 设备时钟的固定格式（本机时区），用于日志与界面文案。
public struct DeviceClockFormatter {
    private let formatter: DateFormatter

    public init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
    }

    public func string(fromUnix unix: UInt32) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    public func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
