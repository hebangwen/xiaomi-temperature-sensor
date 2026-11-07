# AGENTS.md

面向在本仓库继续开发的 agent 与工程师。记录**项目设计**与**蓝牙通信接口**的事实性细节。
新增能力前先读这里，避免重复踩坑（尤其是 CoreBluetooth 与 MiBeacon 的坑）。

---

## 1. 项目定位

macOS 14+ 菜单栏 App，被动接收小米 / 米家 BLE 温湿度计广播并显示在菜单栏与桌面小组件。
原厂固件不做任何修改，不绑定账号，不写设备。

三条数据通道，优先级从高到低：

| 通道 | 需要 bindkey | 依赖 | 适用场景 |
|---|---|---|---|
| ① MiBeacon 明文广播 | 否 | 设备在广播 `obj=1` 的明文帧 | 未绑定设备 |
| ② MiBeacon 加密广播 | 是（AES-128-CCM） | 设备广播 `enc=1` 帧 | 已绑定设备 |
| ③ 自定义服务 GATT 读取 | 否 | 设备暴露 `EBE0CCB0` 服务 | 广播只发身份帧或加密但无密钥 |

---

## 2. 目录与 Target

```text
Sources/MiSensorCore/          纯逻辑，可被 App 与 Widget 共享
  MiBeaconParser.swift         MiBeacon 帧头 / Object / 解密入口
  AESCCM.swift                 AES-128 CCM（无第三方依赖）
  BLEScanner.swift             被动扫描 + MAC 缓存 + GATT 会话入口
  CustomSampleSession.swift    自定义服务单次采样（免 bindkey）
  CustomServiceParser.swift    自定义服务三种特征的字节解析
  GATTProbe.swift              完整 GATT 树探测（诊断用）
  SensorReading.swift          共享模型 + 数据年龄 + 原子快照存储

Sources/MiSensorApp/           菜单栏 App（LSUIElement，无 Dock 图标）
  MiSensorApp.swift            MenuBarExtra + Settings 场景
  SensorController.swift       状态合并、GATT 轮询、Widget 节流、登录启动
  SensorMenuView.swift         菜单栏界面
  SensorSettingsView.swift     设备 / 密钥 / 探测 / 权限
  BindkeyKeychain.swift        Keychain 读写

Sources/MiSensorWidget/        WidgetKit 扩展（小号 + 中号）
Tests/MiSensorCoreTests/       可独立运行（非 XCTest）的断言执行器
```

Xcode 工程由 `project.yml`（XcodeGen）生成，**不要手改 `.xcodeproj`**，改完 `project.yml` 后：

```bash
xcodegen generate --spec project.yml
```

新增 Swift 文件后**必须重新生成工程**，否则 `xcodebuild` 找不到符号。

---

## 3. 架构与数据流

```text
                       ┌──────────────────────────────┐
   广播 FE95 ─────────►│ BLEScanner                   │
                       │  · 解析 / 解密               │
                       │  · 按外设缓存线序 MAC        │
                       │  · 内容去重（整帧相等）      │
                       └───────┬──────────────────────┘
                               │ onAdvertisement / onProblem / onRawFrame
                               ▼
                       ┌──────────────────────────────┐
                       │ SensorController (@MainActor)│
                       │  · 字段级合并（温/湿/电量独立更新）│
                       │  · 失败自动降级到 GATT 轮询   │
                       │  · 快照落盘 + Widget 节流     │
                       └───────┬──────────────────────┘
                               │ 原子写
                               ▼
                App Group / sensor-readings.json
                               │
                               ▼
                       MiSensorWidget（只读，不扫描蓝牙）
```

**关键分层约束**

- Widget **不拥有** `CBCentralManager`，也不读 Keychain。它只消费明文快照。
- bindkey 只存在于主 App 的 Keychain（service `com.example.MiSensor.bindkey`，account 为设备 ID 大写）。
- 解密在 `MiBeaconParser.decode` 内完成，调用方只拿到明文 Object。

---

## 4. 蓝牙通信接口

### 4.1 广播通道：MiBeacon（Service UUID `0xFE95`）

数据来源：`CBAdvertisementDataServiceDataKey` 中 `CBUUID("FE95")` 对应的 `Data`。
**AD 结构的长度/类型字节不在其中**，不要重复剥离。

#### 帧结构

| 偏移 | 字段 | 长度 | 条件 |
|---|---|---|---|
| 0–1 | Frame Control | 2 | 必有 |
| 2–3 | Product ID（小端） | 2 | 必有 |
| 4 | Frame Counter | 1 | 必有 |
| 5–10 | MAC（**线序**，显示时反序） | 6 | `bit4 = 1` |
| next | Capability | 1 | `bit5 = 1` |
| next | I/O Capability | 2（v5）/ 1（v4 兼容） | `Capability & 0x20` |
| next | Object… | 3+N 每条 | `bit6 = 1` |
| 末 7 | Random(3) + MIC(4) | 7 | `bit3 = 1` |

#### Frame Control 位

| bit | 名称 | 说明 |
|---|---|---|
| 3 | isEncrypted | 加密 |
| 4 | MAC Include | 帧内带 MAC |
| 5 | Capability Include | 未绑定时强制为 1 |
| 6 | Object Include | 携带有用数据 |
| 7 | Mesh | 必须 0 |
| 8 | registered | 已绑定 |
| 9 | solicited | 请求绑定 |
| 10–11 | Auth Mode | |
| 12–15 | version | 4 或 5 |

> `obj=0` 表示这一帧**只有身份信息**，不是解析错误。UI 文案必须是“未携带测量值”，不要报成格式错误。

#### Object 表（本项目解析的）

| ID | 含义 | 格式 |
|---|---|---|
| `0x1004` | 温度 | `int16` 小端 ×0.1 ℃ |
| `0x1006` | 湿度 | `uint16` 小端 ×0.1 % |
| `0x100A` | 电量 | `uint8` % |
| `0x100D` | 温湿度合并 | `int16` + `uint16` |

温度**必须用 `Int16`**，否则零下温度会解析成几千度。

#### 加密帧解密（AES-128-CCM）

```text
nonce = MAC_wire(6) + ProductID(2, LE) + FrameCounter(1) + Random(3)
aad   = 0x11
tag   = 帧末 4 字节（MIC）
ct    = Object 起点 .. Random 之前
```

- MAC 优先取帧内 `bit4` 段；帧内没有时使用**同一外设此前帧缓存**的 MAC（`knownMACInWireOrder`）。
- 只支持 v4 / v5；其他版本抛 `unsupportedEncryptedVersion`。
- 校验失败抛 `authenticationFailed`，不要伪装成其他错误。

#### 实测参考向量

```text
明文身份帧（obj=0）  1059322890a698db38c1a4
  FC=0x5910  PID=0x2832  MAC=A4:C1:38:DB:98:A6  bound=1

加密数据帧（obj=1）  58585b05ebab6d4b38c1a43f16dc61bb0200d23c18be
  FC=0x5858  PID=0x055B  enc=1  bound=0
```

### 4.2 GATT 通道 A：自定义传感服务（免 bindkey）

Service `EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6`，全部特征无需认证即可读取。

| 特征 | 属性 | 长度 | 布局 |
|---|---|---|---|
| `EBE0CCC1` | read, notify | 5 | 温度 `int16 LE ×0.01℃` + 湿度 `uint8 %` + 电压 `uint16 LE mV` |
| `8EDFFFEF` | read, notify | 5 | 与 `EBE0CCC1` 同格式（镜像服务） |
| `EBE0CCBB` | read, write | 14 | 计数器 4 + 时间戳 4 + (温度 `int16 LE ×0.1℃` + 湿度 `uint8`) ×2 |
| `EBE0CCBC` | notify | 14 | 索引 1 + 计数器 3 + 时间戳 4 + (温度 + 湿度) ×2 |

- `EBE0CCBC` 是**小时级历史**，相邻记录时间戳相差 3600 秒。
- 同一条记录内的两组温湿度接近但不相同，按两条采样处理。
- 温度两种刻度并存：实时值 ×0.01，记录值 ×0.1。**不要混用**。

实测验证（两处独立特征互相印证，说明解码正确）：

```text
EBE0CCC1 = 0C 07 3B D8 0A  →  18.04℃  59%  2776mV
EBE0CCBB = 67 70 00 00 80 B6 2C 06 B4 00 3B B4 00 3A
           →  18.0℃ 59%   /   18.0℃ 58%
```

### 4.3 GATT 通道 B：Mi Service（`0xFE95`，需认证）

仅用于诊断与未来扩展。**未完成小米认证前设备拒绝业务读写。**

| 特征 | 属性 | 用途 |
|---|---|---|
| `0x0004` | read | 固件版本，如 `1.0.0_0130` |
| `0x0010` | writeNR, notify | 认证 |
| `0x0017` | write, notify | MiOT 下行 |
| `0x0018` | writeNR, notify | MiOT 上行 |
| `0x0019` | writeNR, notify | 扩展 |

对照组（可免密读取的标准服务）：

```text
180A  设备信息  2A24 型号 / 2A25 硬件 / 2A26 固件 / 2A27 软件 / 2A29 厂商
180F  电量      2A19 uint8 %
```

### 4.4 会话时序与参数

| 场景 | 超时 | 重试 |
|---|---|---|
| `readCustomSample` | 12 s | 失败后 120 s 再试，连续 3 次失败即停止并标记不支持 |
| `probeGATT` | 20 s | 手动触发，单次 |
| 过滤扫描 → 全量扫描回退 | 12 s | 每轮扫描会话都重新计时 |

- 扫描参数固定 `CBCentralManagerScanOptionAllowDuplicatesKey = true`，去重靠**整帧内容比较**，不靠系统。
- `CBCentralManager` 必须单实例：重复启动会导致后启动的进程拿到 `Unsupported`。
- 每次 GATT 会话结束后必须 `scanIfPossible()` 恢复扫描。

### 4.5 设备标识

```text
deviceID = 帧内 MAC（大写、冒号分隔、反序显示）
         ↓ 无 MAC 时
         = 同一外设缓存 MAC 推出的 MAC
         ↓ 仍无
         = CBPeripheral.identifier.uuidString
```

`CBPeripheral.identifier` **每台 Mac 不同**，只能作为回退，不能作为跨机器主键，也**不能**替代 nonce 中的 MAC。

---

## 5. 数据模型与刷新策略

```swift
SensorReading {
    deviceID, displayName
    temperature / humidity / battery / rssi / productID / lastFrameCounter
    updatedAt, temperatureUpdatedAt, humidityUpdatedAt, batteryUpdatedAt
}
```

- `hasMeasurements`：任一测量值存在即 true。占位设备（只发现未取到数据）为 false。
- 数据年龄：≤10 分钟 fresh，≤30 分钟 aging，超过 stale。
- 快照只保存 `hasMeasurements == true` 的设备，占位设备不污染 Widget。

| 触发 | 写盘 | 主动刷新 Widget |
|---|---|---|
| 整帧重复 | 否 | 否 |
| 仅 RSSI 变化 | 30 s 节流 | 否 |
| 温湿度或电量变化 | 立即 | 5 分钟节流 |
| GATT 采样成功 | 立即 | 5 分钟节流 |
| Widget 时间线 | — | 每 15 分钟重算年龄 |

Widget 刷新预算有限，不要改成每个广播都 `reloadTimelines`。

---

## 6. 错误类型

`MiBeaconError`：`truncatedFrame` / `noObjectInFrame` / `malformedObject` / `bindkeyRequired` / `invalidBindkeyLength` / `missingMACForDecryption` / `unsupportedEncryptedVersion(UInt8)` / `authenticationFailed`

`GATTProbeError`：`notScanning` / `peripheralUnavailable` / `disconnected(String)` / `noCharacteristic(String)`

文案要求：说清“发生了什么 + 下一步做什么”。`noObjectInFrame` 不能说成格式错误。

---

## 7. 已知设备实测行为

| 设备 | 广播 | GATT | 结论 |
|---|---|---|---|
| `MJWSD05MMC`（温湿度计 3，PID `0x2832`） | 只发身份帧 `obj=0`、`bound=1` | 可连接，自定义服务可读 | 需走通道 ③ |
| `LYWSD03MMC`（PID `0x055B`） | 加密 `enc=1` 与身份帧交替 | 可连接，自定义服务可读 | 通道 ② 或 ③ |

- 米家 App 删除设备**不会**清除设备 Flash 里的绑定标记，`bound` 位仍为 1；只有设备端长按重置才会归零。
- 绑定状态下若固件不在广播给数据，被动扫描永远拿不到读数——这时必须走 GATT，而不是去猜 bindkey。

---

## 8. 构建、测试与验证

```bash
swift run MiSensorCoreTests     # 14 项协议与存储断言，无需 Xcode
./Scripts/validate.sh           # 测试 + App/Widget 类型检查 + plist 校验
swift build -c release
xcodebuild -project MiSensor.xcodeproj -scheme MiSensor \
  -configuration Debug -destination 'platform=macOS' build
```

- 本机 Command Line Tools 环境**没有 XCTest**，所以测试是可执行 Target，用 `expect/expectEqual` 断言。
- 测试必须使用**真实抓包字节**作为向量，不要只构造理想帧。
- 诊断：设置页「连接并读取特征」写入 `/tmp/misensor-gatt.txt`；`--dump-samples` 启动参数把采样值追加到 `/tmp/misensor-sample.txt`。

---

## 9. 签名与 App Group

- macOS App Group 必须以签名 Team ID 前缀，格式 `$(DEVELOPMENT_TEAM).com.example.misensor`，否则 `containermanagerd` 拒绝访问。
- entitlements 与两个 `Info.plist` 的 `MiSensorAppGroupIdentifier` 必须**同步**；运行时代码直接读 Info.plist，不需要改 Swift 常量。
- 主 App 需要 `com.apple.security.device.bluetooth`；Widget **不需要**。
- 用 ad-hoc 重签名调试时若漏掉 `--entitlements`，蓝牙会静默失效（`tccRequired` 后没有 `TCCDone`）。

---

## 10. 修改约束

1. 不要让 Widget 扫描蓝牙或持有密钥。
2. 不要用 `peripheral.identifier` 替代 nonce 中的 MAC。
3. 不要在 `didDiscover` 里丢掉“没有 Service Data”的帧而不记录——诊断能力依赖它。
4. 不要把 `obj=0` 当成错误，也不要因为它去猜 bindkey。
5. 新增 Object ID 时同步补测试向量。
6. 新增 Swift 文件后重新 `xcodegen generate`。
7. 不提交 `.build`、`xcuserdata`、任何 bindkey 或真实账号凭据。
