import Foundation
import Network
import os

/// 本机回环快照服务器。
///
/// 背景（2026-11-08 实测）：小组件扩展进程的沙盒拒绝读 App Group 容器文件
/// （containermanagerd 明文 REJECTED："Group containers identifiers should be
/// prefixed by requestor's team ID"，本机 ad-hoc 签名没有 Team ID）；扩展对
/// group 容器连写也失败；cfprefsd 的 group suite 在沙盒下是各容器私有视图，
/// app / widget / 探针三个进程互不可见。因此改走 127.0.0.1 HTTP：
/// 主 App 监听固定端口，把 `[String: SensorReading]` JSON 暴露在 `/snapshot`，
/// 小组件用 URLSession 拉取。仅绑定回环地址，不向局域网暴露；沙盒默认允许
/// 出站连接、监听需 `com.apple.security.network.server` entitlement。
///
/// 实现说明（2026-11-08）：`NWListener` 在本机 SDK（macOS 27.2 beta）下无论
/// `NWListener(using:on:)` 还是 `requiredLocalEndpoint` 都报
/// `POSIXErrorCode 22 Invalid argument`（沙盒内外一致，见 AGENTS.md §11），
/// 因此直接走 BSD socket，实测沙盒下 bind/listen/accept 全部可用。
///
/// 将来接入真实 Team 签名改回 App Group 文件时，小组件会优先走
/// `SensorSnapshotStore` 的文件/suite 路径，这台服务器只是 ad-hoc 环境的桥。
///
final class SnapshotServer: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.example.MiSensor", category: "SnapshotServer"
    )
    private let provider: () -> [String: SensorReading]
    private let queue = DispatchQueue(label: "com.example.MiSensor.snapshot-server")
    private var serverFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var announcedStart = false

    init(provider: @escaping () -> [String: SensorReading]) {
        self.provider = provider
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.serverFD == -1, self.acceptTask == nil else { return }
            if !self.announcedStart {
                self.logger.fault("snapshot server: start() invoked")
                self.announcedStart = true
            }
            self.listenOn(LocalSnapshotChannel.port)
        }
    }

    private func listenOn(_ port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("snapshot server: socket() failed errno=\(errno, privacy: .public)")
            return
        }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            logger.error("snapshot server: bind 127.0.0.1:\(port, privacy: .public) failed errno=\(errno, privacy: .public)")
            close(fd)
            return
        }
        guard listen(fd, 16) == 0 else {
            logger.error("snapshot server: listen() on \(port, privacy: .public) failed errno=\(errno, privacy: .public)")
            close(fd)
            return
        }
        serverFD = fd
        logger.info("snapshot server: listening on 127.0.0.1:\(port, privacy: .public)")
        acceptTask = Task.detached { [weak self] in
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            while !Task.isCancelled {
                let connectionFD = accept(fd, &address, &length)
                guard connectionFD >= 0 else {
                    if errno == EINTR { continue }
                    break
                }
                self?.respond(connectionFD)
            }
        }
    }

    private func respond(_ connectionFD: Int32) {
        // 请求只需要等到收到首段内容（GET /snapshot 行足够），不做完整解析。
        var buffer = [UInt8](repeating: 0, count: 2048)
        _ = read(connectionFD, &buffer, buffer.count)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload: Data
        do {
            payload = try encoder.encode(provider())
        } catch {
            close(connectionFD)
            return
        }
        var header = (
            "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(payload.count)\r\n"
                + "Connection: close\r\n\r\n"
        ).data(using: .utf8)!
        header.append(payload)
        header.withUnsafeBytes { raw in
            _ = write(connectionFD, raw.baseAddress, header.count)
        }
        close(connectionFD)
    }
}
