import Foundation

/// 本机回环快照通道的**编译期常量**：主 App 的 `SnapshotServer` 监听这个端口，
/// 小组件扩展用同一常量拼 `http://127.0.0.1:<port>/snapshot`。
/// 默认不可更改、可读取；如需修改只能改本文件的字面量并重新编译
/// （设置页只读展示，没有运行时覆盖）。
/// 监听只绑定回环接口，不向局域网暴露（见 `SnapshotServer`）。
public enum LocalSnapshotChannel {
    public static let port: UInt16 = 46193
}
