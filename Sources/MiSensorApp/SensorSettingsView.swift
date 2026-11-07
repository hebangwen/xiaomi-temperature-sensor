import AppKit
import SwiftUI

/// Terminal.app 风格的设置页：顶部一排图标 tab，选中项为强调色填充，
/// 下方即该 tab 的面板。所有 tab 共享同一台被选中的设备。
struct SensorSettingsView: View {
    @EnvironmentObject private var controller: SensorController
    @State private var selectedID = ""
    @State private var displayName = ""
    @State private var bindkey = ""
    @State private var message: String?
    @State private var tab: SettingsTab = .devices

    private var selectedReading: SensorReading? {
        controller.readings[selectedID]
    }

    /// 选中的 tab 是否依赖某台具体设备。
    private var tabNeedsDevice: Bool {
        tab != .general
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .frame(width: 580, height: 720)
        .onAppear { selectInitialDevice() }
        .onChange(of: selectedID) { _, _ in syncFields() }
        .onChange(of: controller.readings.keys.sorted()) { _, _ in
            if controller.readings[selectedID] == nil { selectInitialDevice() }
        }
    }

    // MARK: - Tab bar（Terminal.app 式图标 tab）

    private var tabBar: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { item in
                    tabButton(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let isSelected = tab == item
        return Button {
            tab = item
        } label: {
            HStack(spacing: 5) {
                item.icon
                Text(item.title)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(nsColor: .controlAccentColor) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.tip)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .devices: devicesPane
        case .bindkey: bindkeyPane
        case .gattTest: gattPane
        case .timeGateway: timeGatewayPane
        case .general: generalPane
        }
    }

    /// 除「通用」外的 tab 都操作当前选中的设备，共享同一个设备选择器。
    @ViewBuilder
    private var deviceHeader: some View {
        if controller.readings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未收到设备数据", systemImage: "wifi.slash")
                    .font(.headline)
                Text("请将温湿度计放在 Mac 附近，并确认系统蓝牙已开启。广播到达后这里会自动列出设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("温湿度计", selection: $selectedID) {
                ForEach(controller.sortedReadings()) { reading in
                    Text(reading.displayName).tag(reading.deviceID)
                }
            }
            Text(selectedID)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var deviceRequiredNote: some View {
        if selectedID.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("先在「设备」tab 选择或接入一台温湿度计", systemImage: "cursorarrow.click.2")
                    .font(.headline)
                Text("这些设置按设备保存；没有设备时不可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 设备 tab

    private var devicesPane: some View {
        Form {
            Section {
                deviceHeader
            }
            if selectedReading != nil {
                Section("重命名") {
                    TextField("显示名称", text: $displayName)
                    Button("保存名称") {
                        controller.rename(deviceID: selectedID, to: displayName)
                        message = "名称已保存"
                    }
                }
                Section("忽略") {
                    HStack {
                        Button("忽略此设备") {
                            controller.ignoreDevice(selectedID)
                            message = "已忽略该设备；可在「设备」tab 恢复显示"
                            selectInitialDevice()
                        }
                        .disabled(selectedID.isEmpty)
                        Button("恢复被忽略的设备") {
                            controller.restoreIgnoredDevices()
                            message = "已恢复；设备再次广播后会重新出现"
                        }
                        .disabled(controller.ignoredDeviceIDs.isEmpty)
                    }
                    Text("共用 FE95 广播但不是温湿度计的设备（例如智能灯）会自动不显示；也可以手动忽略。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !controller.ignoredDeviceIDs.isEmpty {
                        Text("已忽略 \(controller.ignoredDeviceIDs.count) 台：\(controller.ignoredDeviceIDs.sorted().joined(separator: "、"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let frame = controller.lastFrameHex[selectedID] {
                    Section("最近一帧原始数据") {
                        if let note = controller.lastRawFrameNote[selectedID] {
                            Label(note, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(frame)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("共 \(frame.split(separator: " ").count) 字节")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let message { footer(message) }
        }
        .formStyle(.grouped)
    }

    // MARK: - 加密广播 tab

    private var bindkeyPane: some View {
        Form {
            if tabNeedsDevice { Section { deviceHeader } }
            if selectedReading != nil {
                Section("bindkey（16 字节）") {
                    Text("未绑定设备通常发送明文广播，这条通道无需任何 key，直接走「连接测试」或等待广播。已绑定设备的加密广播需要 16 字节 bindkey；密钥只存入本机 Keychain。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("32 个十六进制字符", text: $bindkey)
                    HStack {
                        Button("保存 bindkey") { saveKey() }
                        Button("删除已存密钥") { removeKey() }
                            .disabled(!controller.hasBindkey(for: selectedID))
                    }
                    if controller.hasBindkey(for: selectedID) {
                        Label("本机已保存该设备的 bindkey", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(controller.sharedStorageAvailable ? .green : .orange)
                    }
                    if let problem = controller.problems[selectedID] {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                deviceRequiredNote
            }
            if let message { footer(message) }
        }
        .formStyle(.grouped)
    }

    // MARK: - 连接测试 tab

    private var gattPane: some View {
        Form {
            if tabNeedsDevice { Section { deviceHeader } }
            if selectedReading != nil {
                Section("连接并读取特征") {
                    Text("被动广播没有携带测量值时，可以连接设备读取 GATT 特征。此操作不会写入设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(controller.isProbingGATT ? "正在连接…" : "连接并读取特征") {
                        controller.probeGATT(for: selectedID)
                    }
                    .disabled(controller.isProbingGATT)
                    if let result = controller.gattProbeResult {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                deviceRequiredNote
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 时间网关 tab

    private var timeGatewayPane: some View {
        Form {
            Section("时间网关") {
                Toggle("向温湿度计推送当前时间", isOn: $controller.timeGatewayEnabled)
                Text("温湿度计没有联网能力，出厂或重置后自己计时，日期停在 1973 年前后。开启后本项目充当蓝牙网关：把 Mac 的当前时间写进设备的 EBE0CCB7 特征（按固件实际长度写 4 或 6 字节），每台设备最多每小时写一次。这是本项目唯一会修改设备的操作，原厂固件无需配对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if tabNeedsDevice { Section { deviceHeader } }
            if selectedReading != nil {
                Section("这台设备") {
                    HStack {
                        Button("立即推送时间") { controller.pushClock(for: selectedID) }
                        Button("只读设备时间") { controller.readClock(for: selectedID) }
                    }
                    .disabled(controller.isSyncingClock.contains(selectedID))
                    if let report = controller.clockReports[selectedID] {
                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let last = controller.lastClockSync[selectedID] {
                        LabeledContent(
                            "上次成功校时",
                            value: last.formatted(date: .numeric, time: .standard)
                        )
                    }
                }
            } else if selectedID.isEmpty {
                deviceRequiredNote
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 通用 tab

    private var generalPane: some View {
        Form {
            Section("后台与权限") {
                Toggle("登录时启动", isOn: Binding(
                    get: { controller.loginItemEnabled },
                    set: { enabled in
                        do {
                            try controller.setLoginItem(enabled: enabled)
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                ))
                Button("打开蓝牙权限设置") { controller.openBluetoothSettings() }
                Text("Mac 睡眠时采集暂停；唤醒后 CoreBluetooth 会恢复被动扫描。广播无数据时才做免密钥 GATT 读取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("数据存储") {
                LabeledContent("快照路径", value: controller.storageDescription)
                Text("读数快照只用于本机重启后恢复菜单栏显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message { footer(message) }
        }
        .formStyle(.grouped)
    }

    private func footer(_ text: String) -> some View {
        Section {
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 状态

    private func selectInitialDevice() {
        selectedID = controller.sortedReadings().first?.deviceID ?? ""
        syncFields()
    }

    private func syncFields() {
        displayName = selectedReading?.displayName ?? ""
        bindkey = ""
    }

    private func saveKey() {
        do {
            try controller.saveBindkey(bindkey, for: selectedID)
            bindkey = ""
            message = "bindkey 已存入 Keychain，等待设备下一帧广播。"
        } catch {
            message = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try controller.removeBindkey(for: selectedID)
            message = "已删除该设备的 bindkey。"
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Terminal.app 偏好设置的 tab 分组。
private enum SettingsTab: String, CaseIterable, Identifiable {
    case devices
    case bindkey
    case gattTest
    case timeGateway
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: "设备"
        case .bindkey: "加密广播"
        case .gattTest: "连接测试"
        case .timeGateway: "时间网关"
        case .general: "通用"
        }
    }

    var tip: String {
        switch self {
        case .devices: "设备列表、重命名与原始帧"
        case .bindkey: "加密广播的 bindkey 管理"
        case .gattTest: "连接设备读取 GATT 特征"
        case .timeGateway: "时间网关开关与手动校时"
        case .general: "登录启动、权限与存储"
        }
    }

    var icon: Image {
        switch self {
        case .devices: Image(systemName: "thermometer.medium")
        case .bindkey: Image(systemName: "lock.shield")
        case .gattTest: Image(systemName: "dot.radiowaves.left.and.right")
        case .timeGateway: Image(systemName: "clock.badge.checkmark")
        case .general: Image(systemName: "gearshape")
        }
    }
}
