# 米家温湿度 · macOS

原厂米家温湿度计的 macOS 被动采集器。使用 CoreBluetooth 接收 `0xFE95` MiBeacon 广播，不配对、不修改设备固件；广播无数据时才做一次免密钥 GATT 读取。

## 已实现

- 持续被动扫描；每次过滤扫描 12 秒后自动扩展到全量 BLE 扫描，再筛选 `0xFE95` Service Data，兼容只携带 Service Data 的固件。
- MiBeacon v4/v5 帧头、MAC、Capability、I/O Capability 和 Object 解析。
- 按 CoreBluetooth 外设缓存线序 MAC，统一有/无 MAC 拆帧的设备 ID，并为无 MAC 加密帧复用 nonce 所需 MAC。
- 温度 `0x1004`、湿度 `0x1006`、电量 `0x100A`、温湿度合并 `0x100D`。
- 加密广播 AES-128-CCM 解密：12 字节 nonce、AAD `0x11`、4 字节 MIC。
- bindkey 存主 App Keychain，不随快照落盘。
- 跨广播合并温度、湿度和电量；原始帧内容去重；RSSI 独立更新。
- 菜单栏实时读数、多设备列表、自定义名称、原始帧和错误状态。
- App Group 原子 JSON 快照，重启后恢复菜单栏读数。
- 在线/较旧/过期状态、登录启动、Mac 唤醒后恢复扫描。
- 可选的**时间网关**：把 Mac 当前时间写进设备（`EBE0CCB7`，4 字节 Unix 秒），作用等同于米家网关校时；默认关闭，写后回读校验。
- 无第三方运行时依赖。

## 架构

```text
米家温湿度计
    │ 原厂 MiBeacon 广播 / 自定义服务 GATT 回退
    ▼
MiSensor 菜单栏 App
    ├─ CoreBluetooth 被动扫描
    ├─ MiBeacon 解析 / AES-CCM 解密
    ├─ 免密钥 GATT 采样（广播无数据时）
    └─ 合并读数并保存 App Group JSON
```

Mac 睡眠期间采集暂停，唤醒后继续。

## 打开工程

要求 macOS 14 或更高版本，以及完整 Xcode（建议 Xcode 16 或更高版本）。

1. 打开 `MiSensor.xcodeproj`。
2. 在 **MiSensor** Target 的 **Signing & Capabilities** 中选择开发团队。
3. 默认标识如下，Bundle ID 建议改成自己的反向域名：

   ```text
   主 App      com.example.MiSensor
   App Group   $(DEVELOPMENT_TEAM).com.example.misensor
   ```

   macOS App Group 使用 Team ID 前缀，例如 `ABCDE12345.com.example.misensor`。`DEVELOPMENT_TEAM` 会由 Xcode 按所选团队自动展开。

4. 如果要修改 App Group 的 `com.example.misensor` 后缀，同时修改 Target 的 App Groups capability、`.entitlements` 文件和 `Info.plist` 中的 `MiSensorAppGroupIdentifier`。运行时直接读取 Info.plist，无需修改 Swift 源码。
5. 运行 `MiSensor` scheme。首次启动时允许蓝牙权限。
6. 主 App 出现在菜单栏，收到数据后直接显示读数。

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

连续失败 3 次后暂停该设备的重试并标记“该设备不支持免密钥读取”，直到它再次广播。

### 自定义服务格式（实测 LYWSD03MMC / MJWSD05MMC）

| 特征 | 长度 | 布局 |
|---|---|---|
| `EBE0CCC1`（`8EDFFFEF` 为镜像） | 5 | 温度 `int16 LE ×0.01℃` + 湿度 `uint8 %` + 电压 `uint16 LE mV` |
| `EBE0CCBB` | 14 | 计数器 4 + 时间戳 4 + (温度 `int16 LE ×0.1℃` + 湿度 `uint8`)×2 |
| `EBE0CCBC` | 14 | 记录索引 1 + 计数器 3 + 时间戳 4 + (温度 + 湿度)×2 |

`EBE0CCBC` 为每小时一条的历史记录，每条相差 3600 秒。

设置页的「连接并读取特征」可对任意设备做一次完整 GATT 树探测，结果同时写入 `/tmp/misensor-gatt.txt`（沙盒构建下写入容器的 `tmp` 目录）。

## 时间网关（可选，唯一会写设备的操作）

温湿度计没有联网能力，出厂或重置后**自己计时**：从未被校时的设备读回 `103647534`，
也就是 1973 年（`MJWSD05MMC` 这类停过表的设备则停在 2022 年）。米家 App / 网关配对后会把当前时间写进设备，本项目实现的是同一条路径，
**不需要 bindkey，也不需要小米账号**。

```text
连接设备 → 读 EBE0CCB7 取基线，顺便记下该特征长度（4 或 6 字节）
        → 等长写入当前时间的 Unix 秒小端
        → 立刻回读 EBE0CCB7 校验（偏差 ≤ 30 秒才算被固件接受）
        → 顺带读 EBE0CCBB，告知历史缓冲还没被改写
```

实测（`LYWSD03MMC` / `MJWSD05MMC`，固件 `1.0.0_0130`）：

```text
LYWSD03MMC（4 字节）
  读取基线   EBE0CCB7 = 2E 89 2D 06        → 103 647 534（1973-04-14，从未校时）

MJWSD05MMC（6 字节，尾部是时区小时数 + 0）
  写入       EBE0CCB7 ← 3D 8D EE 6A 08 00  → 1 794 018 621
  回读校验   EBE0CCB7 = 43 8D EE 6A 08 00  → 1 794 018 627（6 秒后）

  命令行输出：verified=true，before/after/drift 一并打印
```

### 时钟字段存的是「本地时间数值」，不是 Unix 秒

这是第一版实现踩过的坑，也是最容易再犯的地方：

```text
写入 Unix 1 794 046 207（本地 18:10）        → 设备屏幕显示 02:10 次日（快 8 小时）
写入 1 794 046 207 − 28 800 = 1 794 017 407  → 设备屏幕显示 18:10（正确）
```

设备**直接显示这个字段值**，不做时区换算，所以：

- 写入值 = 真实 Unix 秒，不要扣时区；
- 读回的时钟、`EBE0CCBB/EBE0CCBC` 的记录时间戳都是 Unix 秒，不要加时区；
- 6 字节固件的时区字节单位是小时（`08` = UTC+8），只影响固件内部换算；
- 标准 `FE95/0x0020` 校时路径同样是 Unix 秒 + 1 字节时区；
- 回读校验只保证「数值进去了」，**发现不了 8 小时显示偏差**——必须拿设备屏幕核对一次。

> 设备曾出现「内部值是真实 Unix、屏幕却快 8 小时」的状态，那是**米家 App 连接时写入了 `Unix + 8h`**。
> 米家 App 与本程序会互相覆盖，判断时钟只看设备屏幕。

> 给 6 字节固件写 4 字节会被 ACK 但**整帧丢弃**（时钟一动不动），所以必须先读基线拿长度再等长写。

两种用法：

1. **图形界面**：设备与设置 →「时间网关」→ 打开开关（每台设备每小时校时一次），或点「立即推送时间」手动写一次；「只读设备时间」只看不写。
2. **命令行**：

   ```bash
   swift build --product MiSensorCLI
   .build/debug/MiSensorCLI scan                    # 列出附近 FE95 设备
   .build/debug/MiSensorCLI clock --name LYWSD03MMC # 只读设备时钟
   .build/debug/MiSensorCLI sync  --name LYWSD03MMC # 写入并回读校验
   ```

   > 用 `swift run MiSensorCLI …` 时收不到广播：蓝牙授权记在 `swift` 驱动进程上，子进程拿不到；直接跑 `.build/debug/MiSensorCLI` 正常。

要点与边界：

- 该固件的 `FE95` 没有 `0x0020`（标准 MiBeacon 校时特征），所以必须走 `EBE0CCB7`；代码里保留了 `0x0020` 分支给别的固件，但那条路无法回读校验。
- 校时**不会**回溯改写已经写好的历史记录**，但之后的每小时记录都会带真实日期。实测同一条 `EBE0CCBB`：

  ```text
  校时前（15:37）  75 70 00 00 60 7B 2D 06 …  → 记录时间戳 103 644 000（1973-04-14）
  校时后（16:35）  76 70 00 00 80 DA EE 6A …  → 记录时间戳 1 794 038 400（2026-11-07 16:00）
  ```

- 原厂固件时钟会持续漂移：实测 24 分钟差 3 秒、38 分钟差 5–6 秒（约 0.2% ≈ 7–10 秒/小时），所以网关要周期性校时（本项目每小时一次，界面开关只管开关，不写别的配置，也不碰绑定标记）。
- 除这一条以外，本 App 仍然只读设备。

## 验证

```bash
# 实际执行协议与存储断言
swift run MiSensorCoreTests

# 命令行网关（需要实体设备；必须先 build 再直接运行二进制）
swift build --product MiSensorCLI
.build/debug/MiSensorCLI clock --name LYWSD03MMC

# 同时执行测试、App 类型检查和 plist 校验
./Scripts/validate.sh

# 验证所有 SwiftPM Target 的优化构建
swift build -c release

# 构建 App（xcode-select 指向 CLT 时需显式指定 Xcode）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MiSensor.xcodeproj -scheme MiSensor \
  -configuration Debug -destination 'platform=macOS' build
```

当前测试覆盖：

- 明文温度、湿度、电量；
- 负温度与合并 Object；
- Capability 和 v4/v5 I/O Capability 偏移；
- 加密 MiBeacon 往返、错误 bindkey 与明确的旧版加密版本错误；
- 有/无 MAC 拆帧的身份统一与缓存 MAC 解密；
- RFC 3610 AES-CCM 标准测试向量；
- malformed Object 与 bindkey 格式；
- App Group 快照编码/解码；
- 设备时钟编码与回读判定（真实抓包向量：写入 `B2 D0 EE 6A`、回读 `B5 D0 EE 6A`、未校时基线 `2E 89 2D 06`）。

> 小组件为 WidgetKit 目标 `MiSensorWidget`（systemSmall / systemMedium / systemLarge），
> 通过 App Group `com.example.misensor` 读取主 App 的 `sensor-readings.json`；主 App
> 每次落盘快照都会立刻刷新小组件时间线。设计细节见 `AGENTS.md` §9 / §11。

## 文件结构

```text
Sources/MiSensorCore/
  MiBeaconParser.swift   协议解析与 Object 解码
  AESCCM.swift           AES-128 CCM，无外部依赖
  BLEScanner.swift       CoreBluetooth 被动扫描与内容去重
  ClockSync.swift        设备时钟编解码与校时结果
  TimeSyncSession.swift  校时会话（读基线 → 写入 → 回读校验）
  SensorReading.swift    共享模型、数据年龄、原子 JSON 存储
Sources/MiSensorCLI/
  main.swift             命令行网关：scan / clock / sync
Sources/MiSensorApp/
  SensorController.swift 状态合并、GATT 轮询、登录启动
  BindkeyKeychain.swift  主 App 私有密钥存储
  SensorMenuView.swift   菜单栏实时界面
  SensorSettingsView.swift 设备、密钥与权限设置
Tests/MiSensorCoreTests/
  MiBeaconParserTests.swift 可独立运行的测试执行器
```

## 调试与边界

- **菜单栏一直等待数据**：确认“系统设置 → 隐私与安全性 → 蓝牙”中已允许主 App；让设备靠近 Mac；按一下设备侧键触发广播。
- **提示需要 bindkey**：广播已加密，填入正确密钥。CoreBluetooth UUID 只用于关联外设；解密 nonce 使用帧内 MAC，或同一外设此前帧中缓存的 MAC。
- **数值暂时只有一项**：温度、湿度和电量可能分属不同广播，收到后续包后会自动合并。
- **多设备**：菜单栏并列显示所有设备，按名称排序。
- **列表里出现不是温湿度计的设备**（例如共用 `FE95` 广播的智能灯）：新版只在「帧里有测量值 / 暴露过 `EBE0CCB0` / Product ID 是已知温湿度计」时才建行，其它设备仅记录原始帧。仍想手动清掉时，在设置页点「忽略此设备」。
- **同一台设备出现两行**（一行是 MAC、一行是 `温湿度计（身份未识别）`）：未绑定设备的广播常常不带 MAC，身份退回 CoreBluetooth UUID，地址轮换就会多出一行。程序启动时会清理、运行时每 30 秒把读数接近的 UUID 行并进 MAC 行。
- 当前环境完成了协议测试和全部 Swift 源码类型检查；真实温湿度计广播仍需在装有完整 Xcode 和实体设备的 Mac 上验证。

## 协议参考

- [MiBeacon protocol v5：帧字段、2 字节 I/O Capability 与拆帧规则](https://github.com/pvvx/ATC_MiThermometer/blob/master/InfoMijiaBLE/Mijia%20BLE%20MiBeacon%20protocol%20v5.md)
- [ble_monitor Xiaomi Parser：v4/v5 nonce、AES-CCM 和 Object 对照实现](https://github.com/custom-components/ble_monitor/blob/master/custom_components/ble_monitor/ble_parser/xiaomi.py)
