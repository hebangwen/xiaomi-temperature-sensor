import AppKit
import SwiftUI

struct SensorSettingsView: View {
    @EnvironmentObject private var controller: SensorController
    @State private var selectedID = ""
    @State private var displayName = ""
    @State private var bindkey = ""
    @State private var message: String?

    private var selectedReading: SensorReading? {
        controller.readings[selectedID]
    }

    var body: some View {
        Form {
            Section("设备") {
                if controller.readings.isEmpty {
                    Text("尚未收到设备数据。请将温湿度计放在 Mac 附近，并确认系统蓝牙已开启。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("温湿度计", selection: $selectedID) {
                        ForEach(controller.sortedReadings()) { reading in
                            Text(reading.displayName).tag(reading.deviceID)
                        }
                    }
                    Text(selectedID)
                        .font(.caption)
                        .textSelection(.enabled)
                    TextField("显示名称", text: $displayName)
                    Button("保存名称") {
                        controller.rename(deviceID: selectedID, to: displayName)
                        message = "名称已保存"
                    }
                    .disabled(selectedReading == nil)
                }
            }

            Section("加密广播") {
                Text("未绑定设备通常发送明文，无需填写。已绑定设备需要 16 字节 bindkey；密钥只存入本机 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("32 个十六进制字符", text: $bindkey)
                    .disabled(selectedReading == nil)
                HStack {
                    Button("保存 bindkey") { saveKey() }
                        .disabled(selectedReading == nil)
                    Button("删除已存密钥") { removeKey() }
                        .disabled(selectedReading == nil || !controller.hasBindkey(for: selectedID))
                }
                if let problem = controller.problems[selectedID] {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

            Section("连接测试") {
                Text("被动广播没有携带测量值时，可以连接设备读取 GATT 特征。此操作不会写入设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("连接并读取特征") {
                    controller.probeGATT(for: selectedID)
                }
                .disabled(selectedID.isEmpty || controller.isProbingGATT)
                if let result = controller.gattProbeResult {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                Text("Mac 睡眠时采集暂停；唤醒后 CoreBluetooth 会恢复被动扫描。设备始终无需 GATT 连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Widget 数据") {
                LabeledContent("共享存储", value: controller.storageDescription)
                if !controller.sharedStorageAvailable {
                    Text("当前使用 App 私有回退目录。要让 Widget 读取数据，请为两个 Target 配置相同的 App Group。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("小组件默认显示最近更新的设备。新数据主动刷新按 5 分钟节流，时间线每 15 分钟检查一次数据年龄。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("立即刷新小组件") { controller.reloadWidgets() }
            }

            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onAppear { selectInitialDevice() }
        .onChange(of: selectedID) { _, _ in syncFields() }
        .onChange(of: controller.readings.keys.sorted()) { _, _ in
            if controller.readings[selectedID] == nil { selectInitialDevice() }
        }
    }

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
