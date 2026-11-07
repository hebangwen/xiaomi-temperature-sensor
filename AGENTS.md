# AGENTS.md

面向在本仓库继续开发的 agent 与工程师。记录**项目设计**与**蓝牙通信接口**的事实性细节。
新增能力前先读这里，避免重复踩坑（尤其是 CoreBluetooth 与 MiBeacon 的坑）。

---

## 1. 项目定位

macOS 14+ 菜单栏 App，被动接收小米 / 米家 BLE 温湿度计广播并显示在菜单栏。
不绑定小米账号，不改固件。**唯一会写设备的操作是可选的时间同步**（向 `EBE0CCB7`
写 32 位 Unix 秒，4 或 6 字节按固件而定，见 §4.6），默认关闭，需要用户显式开启或加 `--push-clock` 启动参数。

三条数据通道，优先级从高到低：

| 通道 | 需要 bindkey | 依赖 | 适用场景 |
|---|---|---|---|
| ① MiBeacon 明文广播 | 否 | 设备在广播 `obj=1` 的明文帧 | 未绑定设备 |
| ② MiBeacon 加密广播 | 是（AES-128-CCM） | 设备广播 `enc=1` 帧 | 已绑定设备 |
| ③ 自定义服务 GATT 读取 | 否 | 设备暴露 `EBE0CCB0` 服务 | 广播只发身份帧或加密但无密钥 |

另有**一条写入通道**（不属于数据通道）：`EBE0CCB7` 写设备时钟，即“充当蓝牙网关”。
它只写时间、不写配置、不碰绑定状态，详见 §4.6。

---

## 2. 目录与 Target

```text
Sources/MiSensorCore/          纯逻辑，由主 App 复用
  MiBeaconParser.swift         MiBeacon 帧头 / Object / 解密入口
  AESCCM.swift                 AES-128 CCM（无第三方依赖）
  BLEScanner.swift             被动扫描 + MAC 缓存 + GATT 会话入口
  CustomSampleSession.swift    自定义服务单次采样（免 bindkey）
  CustomServiceParser.swift    自定义服务三种特征的字节解析
  ClockSync.swift              设备时钟编解码 + 校时结果模型（唯一写设备的协议）
  TimeSyncSession.swift        校时会话：读基线 → 写入 → 回读校验
  GATTProbe.swift              完整 GATT 树探测（诊断用）
  SensorReading.swift          共享模型 + 数据年龄 + 原子快照存储

Sources/MiSensorApp/           菜单栏 App（LSUIElement，无 Dock 图标）
  MiSensorApp.swift            MenuBarExtra + Settings 场景
  SensorController.swift       状态合并、GATT 轮询、登录启动
  SensorMenuView.swift         菜单栏界面
  SensorSettingsView.swift     设备 / 密钥 / 探测 / 权限
  BindkeyKeychain.swift        Keychain 读写

Sources/MiSensorCLI/           命令行网关（头less 扫描 / 读时钟 / 推时间）
  main.swift                   MiSensorCLI scan|clock|sync|probe|sample

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
                       │  · 快照落盘                   │
                       └───────┬──────────────────────┘
                               │ 原子写
                               ▼
                App Group / sensor-readings.json
```

**关键分层约束**

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
| `EBE0CCB7` | read, write | 4 或 6 | 设备时钟，`UInt32 LE` Unix 秒（6 字节固件尾部多时区+0），写入即校时，见 §4.6 |
| `EBE0CCBB` | read | 14 | 计数器 4 + 时间戳 4 + (温度 `int16 LE ×0.1℃` + 湿度 `uint8`) ×2 |
| `EBE0CCBC` | notify | 14 | 索引 1 + 计数器 3 + 时间戳 4 + (温度 + 湿度) ×2 |

- `EBE0CCBC` 是**小时级历史**，相邻记录时间戳相差 3600 秒。
- 固件 `1.0.0_0130` 实测 `EBE0CCBB` 只有 `read`（没有 write），校时要用 `EBE0CCB7`。
- 同一条记录内的两组温湿度接近但不相同，按两条采样处理。
- 温度两种刻度并存：实时值 ×0.01，记录值 ×0.1。**不要混用**。

实测验证（两处独立特征互相印证，说明解码正确）：

```text
EBE0CCC1 = 0C 07 3B D8 0A  →  18.04℃  59%  2776mV
EBE0CCBB = 67 70 00 00 80 B6 2C 06 B4 00 3B B4 00 3A
           →  18.0℃ 59%   /   18.0℃ 58%
```

#### 2026-11-07 全 GATT 树实测补充（两台真机全树读回，对照 [pvvx 的 MJWSD05MMC UUIDs dump](https://pvvx.github.io/MJWSD05MMC/)）

| 特征 | 固件命名 | 两族布局 | 结论 |
|---|---|---|---|
| `EBE0CCC4` | Battery | **两族都有** | 1 字节电量 0-100。`CustomSampleSession` 已在同会话内读取，随 `CustomSensorSample.batteryPercent` 带出。实测 MJWSD 0x28(40%)@2535mV、LYWSD 0x64(100%)@2866mV，与电压曲线一致 |
| `0x2A19`（180F） | — | 两族都有 | **恒返 0x63=99%，是占位假值，不要用**。读电量只信 `CCC4` |
| `EBE0CCB9` | Data Count | **两族都有** | 8 字节：`u32[0]`=写计数器，与 `CCBB` 头 4 字节完全相等（两台验证）；`u32[1]` 待定（6120/3714，量级像累计小时数） |
| `EBE0CCBA` | 读游标 | **两族都有** | read+write，两台均全 0；疑似历史导出游标 |
| `EBE0CCBE` | Temperature Uint | **两族都有** | 1 字节，实测 0 = ℃ |
| `8EDFFFF0` 镜像服务 | — | 只有 LYWSD03MMC 族 | `8EDFFFEF` 与 `CCC1` **同拍逐字节相等**；镜像不止实时值：`8EDFFFF1` = `CCB9`、`8EDFFFF4` = `CCBA` |

两族固件在 `EBE0CCB0` 下特征集合**不同**：`MJWSD05MMC`(2.0.0_0026) 独有 `CCC2`(Set Notify Size)/`CCD4`(Reset Data)/`CCE4`(Change Time Mode) 及 FE95 的 `0x001A/1B/1C`(spec_rd/spec_wr/扩展)；`LYWSD03MMC`(1.0.0_0130) 独有 `CCD1/CCD7/CCD8/CCD9/CFF1`。共有（可写通用代码）：`CCB7/CB9/CBA/CBB/CBC/CCBE/CCC1/CCC4/CCC8`。

**`EBE0CCBC` notify 是全量历史回放流**：开 notify 后设备从缓冲起点逐条持续推送（40 秒约 100 条，时间戳逐条 +3600，含校时前 1973 段旧时间戳——二次印证"校时不回溯改写历史"）。配合 `CCB9`(总量)+`CCBA`(游标) 可免米家 App 导出全部历史。
**写入白名单不变**：`CCC8`(Disconnect)/`CCD4`(Reset Data)/`CCE4` 是固件级写命令；除 `EBE0CCB7` 时钟外一律不写。

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
| `pushClock` / `readClock` | 12 s | 手动触发，或网关模式每台设备 1 小时一次 |
| `probeGATT` | 20 s | 手动触发，单次 |
| 过滤扫描 → 全量扫描回退 | 12 s | 每轮扫描会话都重新计时 |

- 扫描参数固定 `CBCentralManagerScanOptionAllowDuplicatesKey = true`，去重靠**整帧内容比较**，不靠系统。
- `CBCentralManager` 必须单实例：重复启动会导致后启动的进程拿到 `Unsupported`。
- 每次 GATT 会话结束后必须 `scanIfPossible()` 恢复扫描。
- **多设备轮询必须串行**：`AsyncGate` 保证同一时刻只有一个 `connect` / `stopScan` / 服务发现在进行。两台设备并发 `connect` 会互相中断扫描，并发 `stopScan` 会让对方的服务发现直接失败。
- **会话按 `peripheral.identifier` 隔离**（`sampleSessions` / `probeSessions` 字典），禁止全局单例 session。曾用单一 `sampleSession`：A 连接时把 A 的 `delegate` 指向 B 的 session，B 的 `readCustomSample` 拿到 A 的读数并按 B 落盘，日志表现为 `LYWSD03MMC 19.10C 76%`、`MJWSD05MMC 17.92C 58%` 这类串台。
- `CustomSampleSession` 只接受本会话 `peripheral` 的回调（`isOwn`），外来回调丢弃并记日志，`TimeSyncSession` 同理。
- **校时会话也走 `AsyncGate`**：它要 `stopScan` + `connect`，和采样轮询抢同一把锁。`BLEScanner(restoreIdentifier:)` 传 `nil` 给命令行工具——没有 App bundle 时带状态恢复标识会让 `CBCentralManager` 静默不回调。

### 4.5 设备标识

```text
deviceID = 帧内 MAC（大写、冒号分隔、反序显示）
         ↓ 无 MAC 时
         = 同一外设缓存 MAC 推出的 MAC
         ↓ 仍无
         = CBPeripheral.identifier.uuidString
```

`CBPeripheral.identifier` **每台 Mac 不同**，只能作为回退，不能作为跨机器主键，也**不能**替代 nonce 中的 MAC。

#### 4.5.1 设备筛选与重复行（`MiDeviceCatalog` / `SensorSnapshotCleanup`）

订阅 `FE95` 的**不只是**温湿度计：小米生态的灯、开关、车钥匙也会挂这个服务。
未绑定设备的帧还常常不带 MAC，身份只能退回 `CBPeripheral.identifier`；设备地址轮换后
系统会给新的 UUID，于是同一台设备会同时留下「UUID 行 + MAC 行」。

- 建行判据（`SensorController.shouldTrack`）：用户没忽略 → 帧里有测量值 →
  暴露过 `EBE0CCB0` → Product ID 在 `MiDeviceCatalog.knownThermometerProductIDs`
  （实测 `0x055B` = LYWSD03MMC、`0x2832` = MJWSD05MMC）。都不满足就**只记原始帧、不建行、不轮询**。
  实测反例：`lemesh.light.wy0c14`（智能灯，`FE95` 广播，MAC `AC:8C:46:9C:3B:3B`），
  旧版本会把它当温湿度计轮询三次，然后显示“该设备不支持免密钥读取”。
- 重复行：`SensorSnapshotCleanup.dropProvisionalRows` 在启动时清理快照；
  运行期 `sweepProvisionalRows()` 每 30 秒把读数接近（温度 ≤ 1.0 ℃、湿度 ≤ 5%）的
  UUID 行并进 MAC 行。实测 `8827F485-…`（`MJWSD05MMC` 的 UUID 身份行）与
  `A4:C1:38:DB:98:A6` 就是同一台设备的两行。
- 用户可在设置页「忽略此设备」，列表存 `UserDefaults` 的 `MiSensor.ignoredDevices`；
  忽略只影响本机显示与轮询，设备本身不做任何操作，可一键恢复。

### 4.6 时间同步（充当蓝牙网关）

温湿度计没有联网能力，出厂或重置后**自己计时**：从未被校时的设备读回 `103 647 534`
（≈ 1973-04-14）。米家 App / 网关连接后会把当前时间写进设备，本项目用同一条路径实现，
这也是本仓库**唯一会修改设备的操作**，默认关闭。

写入时序（免 bindkey，实测 `LYWSD03MMC` / `1.0.0_0130`）：

| 步骤 | 动作 | 实测字节 |
|---|---|---|
| 1 | 读 `EBE0CCB7` 取基线 | `2E 89 2D 06` → 103 647 534 |
| 2 | 写 4 字节小端 Unix 秒（`.withResponse`） | 写 `62 F9 EE 6A` → 1 794 046 306（21:11:46 本地） |
| 3 | 立刻回读 `EBE0CCB7` 校验 | 回读 = 写入值 + 经过秒数，同数值域比较，与时区无关 |
| 4 | 读 `EBE0CCBB` 看历史缓冲 | 记录时间戳仍是 `103 644 000`，**校时不回溯改写历史** |

#### 时钟字段就是 Unix 秒（已定案）

`EBE0CCB7` 里存的就是 32 位 Unix 秒，**设备屏幕直接显示这个值**，不做任何时区换算。
三次真机观测互相印证：

```text
内部值 1 794 026 866（真实 Unix − 28 800）→ 屏幕 11:41（慢 8 小时）
内部值 1 794 028 504（真实 Unix − 28 800）→ 屏幕 13:0x（慢 8 小时）
写入真实 Unix 1 794 057 314（21:15）      → 屏幕 21:15（正确）
```

因此：

- **写入值 = Unix 秒**，不要扣时区（`ClockProtocol.deviceClockValue` 是恒等映射，
  保留参数只是为了让调用方显式声明“这里判断过时区”）；
- 回读的时钟、`EBE0CCBB/BCBC` 的记录时间戳都是 Unix 秒，**不要加时区**；
- 6 字节固件的时区字节单位是**小时**（设备自报 `08` = UTC+8），
  但它只影响设备内部换算，不改变“字段是 Unix 秒”这个事实；
- `FE95/0x0020` 那条标准 MiBeacon 路径同样是 Unix 秒 + 1 字节时区。

#### 为什么会看到“快 8 小时”的假象

设备出现过一次「内部值 = 真实 Unix，屏幕却快 8 小时（02:28）」的状态，写入值本身是对的。
唯一能解释的是**别的客户端写入了 `Unix + 8h`**——最可能是米家 App 连接设备时的校时
（小米账号侧按本地时间当 UTC 写入）。它和本程序会互相覆盖，判断时钟对不对**只看设备屏幕**，
并且要知道「米家 App 打开过」会让时间跳 +8h。

本程序在 18:57 曾错误地把「Unix − 8h」当成正确值写入（依据是那次 +8h 的假象），
于是设备慢了 8 小时；21:12 已改回写真实 Unix，并在 §10 第 10 条留下约束。

- 判定标准：回读值与写入值偏差 ≤ 30 秒（`ClockProtocol.readbackToleranceSeconds`）才算固件接受。
  固件忽略写入时回读仍是旧值，必须报“未接受”，不能当成功。
- 该固件的 `FE95` 只有 `0004/0010/0017/0018/0019`，**没有 `0x0020`**，标准 MiBeacon 校时走不通。
  `TimeSyncSession` 保留 `0x0020` 分支（4 字节秒 + 1 字节时区，UTC+8 = `0x08`）给别的固件，
  但那条路不可回读校验，只能报“写入已确认”。
- 记录时间戳不是独立时钟：它是“写记录时把当前设备时钟按小时对齐”。设备时钟还是 1973 年时
  写下的历史记录永久保留 1973 年的时间戳，只有校时之后的新记录才带真实日期。
  实测对照（同一条 `EBE0CCBB`，校时前后）：

  ```text
  校时前（15:37） 75 70 00 00 60 7B 2D 06 …  → 记录时间戳 103 644 000（1973-04-14）
  校时后（16:35） 76 70 00 00 80 DA EE 6A …  → 记录时间戳 1 794 038 400（2026-11-07 16:00）
  ```

  校时前后计数器（偏移 1–3）只从 `0x7075` 走到 `0x7076`：它数的是设备开机小时数，
  与墙上时钟无关，**不要拿它当时间戳**。
- **写入长度必须等于设备特征长度**：`LYWSD03MMC` 的 `EBE0CCB7` 是 4 字节；
  `MJWSD05MMC` 是 6 字节（`<u32 数值><u8 时区/小时=08><u8 00>`）。给 6 字节固件写 4 字节，
  固件会回 ACK 但整帧丢弃，时钟一动不动——必须读基线拿长度再等长写。
  实测：`MJWSD05MMC` 写 `9D 0E EF 6A 08 00`（真实 Unix 秒）→ 回读 `A3 0E EF 6A 08 00`，通过校验。
- 原厂固件没有 RTC 校准，时钟会持续漂移：实测 24 分钟窗口内差 3 秒、38 分钟窗口内差 5–6 秒，
  量级约 **0.2%（7–10 秒/小时，方向随个体与温度而变）**。所以网关必须周期性校时。
  本项目每台设备 **1 小时**校时一次（`SensorController.clockSyncInterval`），
  手动按钮和 `--push-clock` 启动参数不受该节流限制；这样记录时间戳的误差能压在十几秒内。
- 测量方法：`MiSensorCLI clock` 输出的 `before` 与同一行的 `wall` 对比（BLE 读延迟 1–2 秒，同一方法两次取值相减可抵消大部分偏差）。
- 命令行侧同一套代码：`MiSensorCLI sync|clock`，见 §8。

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
- 快照只保存 `hasMeasurements == true` 的设备，占位设备不写入快照。

| 触发 | 写盘 |
|---|---|
| 整帧重复 | 否 |
| 仅 RSSI 变化 | 30 s 节流 |
| 温湿度或电量变化 | 立即 |
| GATT 采样成功 | 立即 |

---

## 6. 错误类型

`MiBeaconError`：`truncatedFrame` / `noObjectInFrame` / `malformedObject` / `bindkeyRequired` / `invalidBindkeyLength` / `missingMACForDecryption` / `unsupportedEncryptedVersion(UInt8)` / `authenticationFailed`

`GATTProbeError`：`notScanning` / `peripheralUnavailable` / `disconnected(String)` / `noCharacteristic(String)`

`ClockSyncError`：`noClockCharacteristic` / `writeFailed(String)` / `timedOut`

文案要求：说清“发生了什么 + 下一步做什么”。`noObjectInFrame` 不能说成格式错误。

---

## 7. 已知设备实测行为

| 设备 | 广播 | GATT | 结论 |
|---|---|---|---|
| `MJWSD05MMC`（温湿度计 3，PID `0x2832`） | 只发身份帧 `obj=0`、`bound=1` | 可连接，自定义服务可读 | 需走通道 ③ |
| `LYWSD03MMC`（PID `0x055B`） | 加密 `enc=1` 与身份帧交替 | 可连接，自定义服务可读 | 通道 ② 或 ③ |
| 时间写入（两者） | 无关 | `EBE0CCB7` 可写 | `LYWSD03MMC` 4 字节、`MJWSD05MMC` 6 字节，均可回读校验 |
| `lemesh.light.wy0c14`（智能灯） | `FE95` 广播，无测量值 | 无 `EBE0CCB0` | **不是温湿度计**，按 §4.5.1 过滤，不建行 |

- 米家 App 删除设备**不会**清除设备 Flash 里的绑定标记，`bound` 位仍为 1；只有设备端长按重置才会归零。
- 绑定状态下若固件不在广播给数据，被动扫描永远拿不到读数——这时必须走 GATT，而不是去猜 bindkey。

---

## 8. 构建、测试与验证

```bash
# SwiftPM 路径，用 Command Line Tools 即可
swift run MiSensorCoreTests     # 19 项协议与存储断言
./Scripts/validate.sh           # 测试 + CLI 构建 + App 类型检查 + plist 校验
swift build -c release

# 时间网关（命令行）
swift build --product MiSensorCLI
.build/debug/MiSensorCLI scan                   # 列出附近 FE95 设备
.build/debug/MiSensorCLI clock --name LYWSD03MMC # 只读设备时钟
.build/debug/MiSensorCLI sync  --name LYWSD03MMC # 写入当前时间并回读校验
.build/debug/MiSensorCLI probe --id 58:C1:A4:38:98:A6  # 全 GATT 树探测（只读）
.build/debug/MiSensorCLI sample --name MJWSD05MMC     # 读一次实时温湿度+电量（CCC1+CCC4）

# xcodebuild 必须显式指向 Xcode：xcode-select 仍指向 CLT
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MiSensor.xcodeproj -scheme MiSensor \
  -configuration Debug -destination 'platform=macOS' build
```

### 本机工具链（实测状态）

| 项 | 值 |
|---|---|
| Xcode | `/Applications/Xcode.app`，**Xcode 27.2 (27B52)** |
| 选中工具链 | `xcode-select -p` → `/Library/Developer/CommandLineTools` |
| SDK | Xcode 自带 macOS 27.2；CLT 为 26.5 |
| XcodeGen | `/opt/homebrew/bin/xcodegen` |

- `xcode-select` 没有切到 Xcode，所以裸跑 `xcodebuild` 会报 `xcodebuild: error: tool 'xcodebuild' requires Xcode`。两种解法，任选其一：
  - 单条命令加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（推荐，不动全局配置）；
  - 或 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
- `Scripts/validate.sh` 走 `xcrun --sdk macosx --show-sdk-path`，跟随当前选中工具链；类型检查用 `-target arm64-apple-macos14.0` 固定部署版本，与 CLT / Xcode 的 SDK 版本无关。
- 本机 Command Line Tools 环境**没有 XCTest**，所以测试是可执行 Target，用 `expect/expectEqual` 断言。
- 每次 `xcodebuild` 都会产生新的 ad-hoc 签名，macOS 因此把 App 当作新程序重新询问蓝牙权限（TCC `AUTHREQ_PROMPTING`），点“允许”即可；这不是权限配置被破坏。
- 测试必须使用**真实抓包字节**作为向量，不要只构造理想帧。
- 诊断：设置页「连接并读取特征」写入 `/tmp/misensor-gatt.txt`；`--dump-samples` 启动参数把采样值追加到 `/tmp/misensor-sample.txt`；每次校时成功追加一行到 `misensor-clock.txt`（沙盒签名下都落在容器 `~/Library/Containers/com.example.MiSensor/Data/tmp/`）。
- **`swift run MiSensorCLI` 收不到任何广播**：TCC 把蓝牙授权记到 `swift` 驱动进程上，子进程拿不到。直接跑 `.build/debug/MiSensorCLI` 正常。同理 CLI 必须 `BLEScanner(restoreIdentifier: nil)`，否则 `CBCentralManager` 静默不回调。

---

## 9. 签名与 App Group

- macOS App Group 必须以签名 Team ID 前缀，格式 `$(DEVELOPMENT_TEAM).com.example.misensor`，否则 `containermanagerd` 拒绝访问。
- entitlements 与 `Info.plist` 的 `MiSensorAppGroupIdentifier` 必须**同步**；运行时代码直接读 Info.plist，不需要改 Swift 常量。
- 主 App 需要 `com.apple.security.device.bluetooth`。
- 用 ad-hoc 重签名调试时若漏掉 `--entitlements`，蓝牙会静默失效（`tccRequired` 后没有 `TCCDone`）。
- 本机没有 `Mac Development` 签名证书（`xcodegen` 生成的工程无 `DEVELOPMENT_TEAM`，ad-hoc 构建）：`$(DEVELOPMENT_TEAM)` 展开成空前缀，`configuredAppGroup` 因前导 `.` 判定无效，快照**回退**到 `~/Library/Containers/com.example.MiSensor/Data/Library/Application Support/MiSensor/sensor-readings.json`。这是当前机器的预期路径；仅当出现真实签名证书且 `DEVELOPMENT_TEAM` 配进 `project.yml` 后才会回到 App Group 共享路径。给缺失 Team 的 project.yml 强行填 Team ID 会让 xcodebuild 直接报 "No signing certificate Mac Development found"。

---

## 10. 修改约束

1. 不要用 `peripheral.identifier` 替代 nonce 中的 MAC。
2. 不要在 `didDiscover` 里丢掉“没有 Service Data”的帧而不记录——诊断能力依赖它。
3. 不要把 `obj=0` 当成错误，也不要因为它去猜 bindkey。
4. 新增 Object ID 时同步补测试向量。
5. 新增 Swift 文件后重新 `xcodegen generate`。
6. 不提交 `.build`、`xcuserdata`、任何 bindkey 或真实账号凭据。
7. 写设备只允许写 `EBE0CCB7` 的时间（4 或 6 字节，按特征长度等长写），且必须由用户开启「时间网关」或显式命令触发；不要顺手写别的特征。
8. 校时结果以**回读校验**为准，没回读一致就不要在界面/日志里显示成功。
9. 不要把 `EBE0CCBB` / `EBE0CCBC` 里的历史时间戳当成“校时后的当前时间”；它们同样是 Unix 秒，**不要加时区**。
10. 设备时钟字段就是 **Unix 秒**，写入不要扣时区（18:57 那版扣了 8 小时，设备直接慢 8 小时）。判断时钟是否正确只看**设备屏幕**；米家 App 可能写入 `Unix + 8h`，不要拿它的显示当判据。
11. 别把共用 `FE95` 的设备（灯、开关……）当温湿度计：建行前先过 `shouldTrack`；也不要为了“看起来干净”丢掉原始帧——诊断依赖它。
12. 见到 UUID 身份的行，先想“这是不是某台 MAC 行的重复行”，用 `SensorSnapshotCleanup` / `sweepProvisionalRows()` 合并，而不是新加一台设备。
