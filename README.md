# 米家温湿度 · macOS

原厂米家温湿度计的 macOS 被动采集器与桌面小组件。使用 CoreBluetooth 接收 `0xFE95` MiBeacon 广播，不配对、不连接 GATT、不修改设备固件。

## 已实现

- 持续被动扫描；每次过滤扫描 12 秒后自动扩展到全量 BLE 扫描，再筛选 `0xFE95` Service Data，兼容只携带 Service Data 的固件。
- MiBeacon v4/v5 帧头、MAC、Capability、I/O Capability 和 Object 解析。
- 按 CoreBluetooth 外设缓存线序 MAC，统一有/无 MAC 拆帧的设备 ID，并为无 MAC 加密帧复用 nonce 所需 MAC。
- 温度 `0x1004`、湿度 `0x1006`、电量 `0x100A`、温湿度合并 `0x100D`。
- 加密广播 AES-128-CCM 解密：12 字节 nonce、AAD `0x11`、4 字节 MIC。
- bindkey 存主 App Keychain；Widget 只能读取解密后的传感器快照。
- 跨广播合并温度、湿度和电量；原始帧内容去重；RSSI 独立更新。
- 菜单栏实时读数、多设备列表、自定义名称、原始帧和错误状态。
- App Group 原子 JSON 共享，主 App 与 Widget 进程隔离。
- 温湿度或电量变化时主动刷新 Widget，5 分钟节流；Timeline 每 15 分钟更新数据年龄。
- 小号/中号 Widget、在线/较旧/过期状态、登录启动、Mac 唤醒后恢复扫描。
- 无第三方运行时依赖。

## 架构

```text
米家温湿度计
    │ 原厂 MiBeacon 广播
    ▼
MiSensor 菜单栏 App
    ├─ CoreBluetooth 被动扫描
    ├─ MiBeacon 解析 / AES-CCM 解密
    ├─ 合并读数并保存 App Group JSON
    └─ 节流调用 WidgetCenter
                 ▼
MiSensorWidget Extension
    ├─ 读取共享 JSON
    ├─ 展示温湿度、电量、RSSI、数据年龄
    └─ 定期刷新过期状态
```

Widget 不扫描蓝牙、不保存 bindkey。Mac 睡眠期间采集暂停，唤醒后继续。

## 打开工程

要求 macOS 14 或更高版本，以及完整 Xcode（建议 Xcode 16 或更高版本）。

1. 打开 `MiSensor.xcodeproj`。
2. 在 **MiSensor** 和 **MiSensorWidget** 两个 Target 的 **Signing & Capabilities** 中选择同一开发团队。
3. 默认标识如下，Bundle ID 建议改成自己的反向域名：

   ```text
   主 App      com.example.MiSensor
   Widget      com.example.MiSensor.MiSensorWidget
   App Group   $(DEVELOPMENT_TEAM).com.example.misensor
   ```

   macOS App Group 使用 Team ID 前缀，例如 `ABCDE12345.com.example.misensor`。`DEVELOPMENT_TEAM` 会由 Xcode 按所选团队自动展开。

4. 如果要修改 App Group 的 `com.example.misensor` 后缀，同时修改两个 Target 的 App Groups capability、两个 `.entitlements` 文件，以及两个 `Info.plist` 中的 `MiSensorAppGroupIdentifier`。运行时直接读取 Info.plist，无需修改 Swift 源码。
5. 运行 `MiSensor` scheme。首次启动时允许蓝牙权限。
6. 主 App 出现在菜单栏。收到数据后，在 macOS 的“编辑小组件”中搜索“米家温湿度”，添加小号或中号小组件。

`project.yml` 是工程的源配置。修改后可用 XcodeGen 重新生成：

```bash
brew install xcodegen
xcodegen generate --spec project.yml
```

重新生成会覆盖 `.xcodeproj` 内手动修改的构建设置；团队与标识建议同步写入 `project.yml`。

## 加密设备

未绑定设备通常是明文广播，保存名称即可使用。已绑定米家的设备若发送加密帧，设置页会提示需要 bindkey：

1. 打开菜单栏 → **设备与设置**。
2. 选择目标设备。
3. 输入该设备自己的 16 字节 bindkey，格式为 32 个十六进制字符，支持冒号、空格或连字符分隔。
4. 点击“保存 bindkey”，等待下一帧广播。

解密输入严格按以下顺序构造：

```text
nonce = 帧内 MAC，或同一外设此前广播中缓存的 MAC（6 字节线序）
      + Product ID（2 字节小端）
      + Frame Counter（1 字节）
      + Random（3 字节）
AAD   = 0x11
MIC   = 最后 4 字节
```

设置页可查看最近一帧已成功解析的原始数据，便于核对 Product ID、MAC 和帧格式。


## 广播无数据时的 GATT 回退

部分固件不在广播里发送测量值：有的把 Object 加密（`enc=1` 且无 bindkey），有的只发身份帧（`obj=0`）。这两种情况会自动转为连接读取，**不需要 bindkey**：

```text
连接设备 → 发现 EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6
        → 读 EBE0CCC1（实时值，5 字节）
        → 断开，每 120 秒重复
```

连续失败 3 次后停止重试并标记“该设备不支持免密钥读取”。

### 自定义服务格式（实测 LYWSD03MMC / MJWSD05MMC）

| 特征 | 长度 | 布局 |
|---|---|---|
| `EBE0CCC1`（`8EDFFFEF` 为镜像） | 5 | 温度 `int16 LE ×0.01℃` + 湿度 `uint8 %` + 电压 `uint16 LE mV` |
| `EBE0CCBB` | 14 | 计数器 4 + 时间戳 4 + (温度 `int16 LE ×0.1℃` + 湿度 `uint8`)×2 |
| `EBE0CCBC` | 14 | 记录索引 1 + 计数器 3 + 时间戳 4 + (温度 + 湿度)×2 |

`EBE0CCBC` 为每小时一条的历史记录，每条相差 3600 秒。

设置页的「连接并读取特征」可对任意设备做一次完整 GATT 树探测，结果同时写入 `/tmp/misensor-gatt.txt`。

## 验证

```bash
# 实际执行协议与存储断言
swift run MiSensorCoreTests

# 同时执行测试、App/Widget 类型检查和 plist 校验
./Scripts/validate.sh

# 验证所有 SwiftPM Target 的优化构建
swift build -c release
```

当前测试覆盖：

- 明文温度、湿度、电量；
- 负温度与合并 Object；
- Capability 和 v4/v5 I/O Capability 偏移；
- 加密 MiBeacon 往返、错误 bindkey 与明确的旧版加密版本错误；
- 有/无 MAC 拆帧的身份统一与缓存 MAC 解密；
- RFC 3610 AES-CCM 标准测试向量；
- malformed Object 与 bindkey 格式；
- App Group 快照编码/解码。

## 文件结构

```text
Sources/MiSensorCore/
  MiBeaconParser.swift   协议解析与 Object 解码
  AESCCM.swift           AES-128 CCM，无外部依赖
  BLEScanner.swift       CoreBluetooth 被动扫描与内容去重
  SensorReading.swift    共享模型、数据年龄、原子 JSON 存储
Sources/MiSensorApp/
  SensorController.swift 状态合并、Widget 节流、登录启动
  BindkeyKeychain.swift  主 App 私有密钥存储
  SensorMenuView.swift   菜单栏实时界面
  SensorSettingsView.swift 设备、密钥与权限设置
Sources/MiSensorWidget/
  MiSensorWidget.swift   小号/中号 Widget 与 Timeline
Tests/MiSensorCoreTests/
  MiBeaconParserTests.swift 可独立运行的测试执行器
```

## 调试与边界

- **菜单栏一直等待数据**：确认“系统设置 → 隐私与安全性 → 蓝牙”中已允许主 App；让设备靠近 Mac；按一下设备侧键触发广播。
- **提示需要 bindkey**：广播已加密，填入正确密钥。CoreBluetooth UUID 只用于关联外设；解密 nonce 使用帧内 MAC，或同一外设此前帧中缓存的 MAC。
- **数值暂时只有一项**：温度、湿度和电量可能分属不同广播，收到后续包后会自动合并。
- **Widget 不逐秒变化**：这是 WidgetKit 的刷新机制；菜单栏显示实时值，Widget 用于概览。
- **Widget 无数据但菜单栏有数据**：检查两个 Target 的 App Group 是否完全一致；未配置 App Group 时主 App 使用私有回退目录，Widget 无法读取该目录。
- **多设备**：菜单栏支持多设备；当前 Widget 默认显示最近更新的一台。
- 当前环境完成了协议测试和全部 Swift 源码类型检查；真实温湿度计广播与最终签名后的 WidgetKit 集成仍需在装有完整 Xcode 和实体设备的 Mac 上验证。

## 协议参考

- [MiBeacon protocol v5：帧字段、2 字节 I/O Capability 与拆帧规则](https://github.com/pvvx/ATC_MiThermometer/blob/master/InfoMijiaBLE/Mijia%20BLE%20MiBeacon%20protocol%20v5.md)
- [ble_monitor Xiaomi Parser：v4/v5 nonce、AES-CCM 和 Object 对照实现](https://github.com/custom-components/ble_monitor/blob/master/custom_components/ble_monitor/ble_parser/xiaomi.py)
