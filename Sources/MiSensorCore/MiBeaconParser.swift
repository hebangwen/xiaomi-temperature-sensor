import Foundation

public enum MiBeaconError: Error, Equatable, LocalizedError {
    case truncatedFrame
    case noObjectInFrame
    case malformedObject
    case bindkeyRequired
    case invalidBindkeyLength
    case missingMACForDecryption
    case unsupportedEncryptedVersion(UInt8)
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .truncatedFrame: "MiBeacon 帧长度不足"
        case .noObjectInFrame: "该帧只广播设备身份，未携带测量值"
        case .malformedObject: "MiBeacon Object 格式错误"
        case .bindkeyRequired: "该设备使用加密广播，需要 16 字节 bindkey"
        case .invalidBindkeyLength: "bindkey 必须是 16 字节（32 个十六进制字符）"
        case .missingMACForDecryption: "加密帧中没有解密所需的设备 MAC，等待携带 MAC 的广播"
        case .unsupportedEncryptedVersion(let version): "加密广播仅支持 MiBeacon v4/v5，当前为 v\(version)"
        case .authenticationFailed: "解密校验失败，请检查 bindkey 和设备 MAC"
        }
    }
}

public struct MiBeaconObject: Equatable, Sendable {
    public let id: UInt16
    public let value: Data

    public init(id: UInt16, value: Data) {
        self.id = id
        self.value = value
    }
}

public struct MiBeaconIdentity: Equatable, Sendable {
    public let deviceID: String
    public let macInWireOrder: Data?
}

public struct DecodedBeacon: Equatable, Sendable {
    public let deviceID: String
    public let macAddress: String?
    public let productID: UInt16
    public let frameCounter: UInt8
    public let version: UInt8
    public let isEncrypted: Bool
    public let isBound: Bool
    public let receivedAt: Date
    public let objects: [MiBeaconObject]
    public let temperature: Double?
    public let humidity: Double?
    public let battery: Int?
    public let rawFrame: Data

    public var hasObject: Bool { !objects.isEmpty }
}

private struct ParsedFrame {
    enum Payload {
        case none
        case plain(Data)
        case encrypted(ciphertext: Data, random: Data, mic: Data)
    }

    let frameControl: UInt16
    let productID: UInt16
    let frameCounter: UInt8
    let version: UInt8
    let isEncrypted: Bool
    let isBound: Bool
    let macInWireOrder: Data?
    let macAddress: String?
    let payload: Payload
}

public enum MiBeaconParser {
    /// Decodes the Service Data value for UUID 0xFE95. The UUID itself and the
    /// AD type/length bytes are not part of `data` when CoreBluetooth supplies it.
    public static func decode(
        _ data: Data,
        bindkey: Data? = nil,
        fallbackDeviceID: String,
        knownMACInWireOrder: Data? = nil,
        receivedAt: Date = Date()
    ) throws -> DecodedBeacon {
        let frame = try parseFrame(data)
        let identity = try identify(
            data,
            fallbackDeviceID: fallbackDeviceID,
            knownMACInWireOrder: knownMACInWireOrder
        )
        let deviceID = identity.deviceID

        let objectData: Data
        switch frame.payload {
        case .none:
            objectData = Data()
        case .plain(let payload):
            objectData = payload
        case .encrypted(let ciphertext, let random, let mic):
            guard frame.version == 4 || frame.version == 5 else {
                throw MiBeaconError.unsupportedEncryptedVersion(frame.version)
            }
            guard let bindkey else { throw MiBeaconError.bindkeyRequired }
            guard bindkey.count == 16 else { throw MiBeaconError.invalidBindkeyLength }
            guard let mac = frame.macInWireOrder ?? knownMACInWireOrder, mac.count == 6 else {
                throw MiBeaconError.missingMACForDecryption
            }

            var nonce = Data()
            nonce.append(mac)
            nonce.append(UInt8(frame.productID & 0x00FF))
            nonce.append(UInt8(frame.productID >> 8))
            nonce.append(frame.frameCounter)
            nonce.append(random)

            do {
                objectData = try AESCCM.decrypt(
                    ciphertext: ciphertext,
                    tag: mic,
                    key: bindkey,
                    nonce: nonce,
                    associatedData: Data([0x11]),
                    tagLength: 4
                )
            } catch {
                throw MiBeaconError.authenticationFailed
            }
        }

        let objects = try parseObjects(objectData)
        var temperature: Double?
        var humidity: Double?
        var battery: Int?

        for object in objects {
            let value = [UInt8](object.value)
            switch object.id {
            case 0x1004 where value.count == 2:
                let raw = Int16(bitPattern: UInt16(value[0]) | (UInt16(value[1]) << 8))
                temperature = Double(raw) / 10
            case 0x1006 where value.count == 2:
                let raw = UInt16(value[0]) | (UInt16(value[1]) << 8)
                humidity = Double(raw) / 10
            case 0x100A where value.count == 1:
                battery = Int(value[0])
            case 0x100D where value.count == 4:
                let rawTemperature = Int16(
                    bitPattern: UInt16(value[0]) | (UInt16(value[1]) << 8)
                )
                let rawHumidity = UInt16(value[2]) | (UInt16(value[3]) << 8)
                temperature = Double(rawTemperature) / 10
                humidity = Double(rawHumidity) / 10
            default:
                break
            }
        }

        return DecodedBeacon(
            deviceID: deviceID,
            macAddress: identity.macInWireOrder == nil ? nil : deviceID,
            productID: frame.productID,
            frameCounter: frame.frameCounter,
            version: frame.version,
            isEncrypted: frame.isEncrypted,
            isBound: frame.isBound,
            receivedAt: receivedAt,
            objects: objects,
            temperature: temperature,
            humidity: humidity,
            battery: battery,
            rawFrame: data
        )
    }

    public static func identify(
        _ data: Data,
        fallbackDeviceID: String,
        knownMACInWireOrder: Data? = nil
    ) throws -> MiBeaconIdentity {
        let frame = try parseFrame(data)
        if let mac = frame.macInWireOrder {
            return MiBeaconIdentity(
                deviceID: frame.macAddress ?? fallbackDeviceID,
                macInWireOrder: mac
            )
        }
        if let mac = knownMACInWireOrder, mac.count == 6 {
            let deviceID = mac.reversed()
                .map { String(format: "%02X", $0) }
                .joined(separator: ":")
            return MiBeaconIdentity(deviceID: deviceID, macInWireOrder: mac)
        }
        return MiBeaconIdentity(deviceID: fallbackDeviceID, macInWireOrder: nil)
    }

    public static func deviceID(
        of data: Data,
        fallbackDeviceID: String,
        knownMACInWireOrder: Data? = nil
    ) throws -> String {
        try identify(
            data,
            fallbackDeviceID: fallbackDeviceID,
            knownMACInWireOrder: knownMACInWireOrder
        ).deviceID
    }

    public static func parseBindkey(_ text: String) -> Data? {
        let hex = text.filter { !$0.isWhitespace && $0 != "-" && $0 != ":" }
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data()
        data.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func parseFrame(_ data: Data) throws -> ParsedFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { throw MiBeaconError.truncatedFrame }

        let frameControl = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let productID = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let frameCounter = bytes[4]
        let isEncrypted = frameControl & (1 << 3) != 0
        let hasMAC = frameControl & (1 << 4) != 0
        let hasCapability = frameControl & (1 << 5) != 0
        let hasObject = frameControl & (1 << 6) != 0
        let isBound = frameControl & (1 << 8) != 0
        let version = UInt8(frameControl >> 12)

        var index = 5
        var macInWireOrder: Data?
        var macAddress: String?

        if hasMAC {
            guard bytes.count >= index + 6 else { throw MiBeaconError.truncatedFrame }
            let macBytes = Array(bytes[index..<(index + 6)])
            macInWireOrder = Data(macBytes)
            macAddress = macBytes.reversed()
                .map { String(format: "%02X", $0) }
                .joined(separator: ":")
            index += 6
        }

        if hasCapability {
            guard index < bytes.count else { throw MiBeaconError.truncatedFrame }
            let capability = bytes[index]
            index += 1
            if capability & 0x20 != 0 {
                // MiBeacon v5 defines Base I/O + Reserved as two bytes. Older
                // community frames only carry the one-byte Base I/O field.
                let ioCapabilityLength = version >= 5 ? 2 : 1
                guard bytes.count >= index + ioCapabilityLength else {
                    throw MiBeaconError.truncatedFrame
                }
                index += ioCapabilityLength
            }
        }

        guard hasObject else {
            return ParsedFrame(
                frameControl: frameControl,
                productID: productID,
                frameCounter: frameCounter,
                version: version,
                isEncrypted: isEncrypted,
                isBound: isBound,
                macInWireOrder: macInWireOrder,
                macAddress: macAddress,
                payload: .none
            )
        }

        let payload: ParsedFrame.Payload
        if isEncrypted {
            guard bytes.count >= index + 7 else { throw MiBeaconError.truncatedFrame }
            let randomStart = bytes.count - 7
            let micStart = bytes.count - 4
            guard randomStart >= index else { throw MiBeaconError.truncatedFrame }
            payload = .encrypted(
                ciphertext: Data(bytes[index..<randomStart]),
                random: Data(bytes[randomStart..<micStart]),
                mic: Data(bytes[micStart..<bytes.count])
            )
        } else {
            payload = .plain(Data(bytes[index..<bytes.count]))
        }

        return ParsedFrame(
            frameControl: frameControl,
            productID: productID,
            frameCounter: frameCounter,
            version: version,
            isEncrypted: isEncrypted,
            isBound: isBound,
            macInWireOrder: macInWireOrder,
            macAddress: macAddress,
            payload: payload
        )
    }

    private static func parseObjects(_ data: Data) throws -> [MiBeaconObject] {
        let bytes = [UInt8](data)
        var result: [MiBeaconObject] = []
        var offset = 0

        while offset < bytes.count {
            guard offset + 3 <= bytes.count else { throw MiBeaconError.malformedObject }
            let id = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let length = Int(bytes[offset + 2])
            let start = offset + 3
            let end = start + length
            guard end <= bytes.count else { throw MiBeaconError.malformedObject }
            result.append(MiBeaconObject(id: id, value: Data(bytes[start..<end])))
            offset = end
        }
        return result
    }
}
