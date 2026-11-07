import Foundation

public enum AESCCMError: Error {
    case invalidParameters
    case authenticationFailed
}

/// Minimal AES-128 CCM implementation for MiBeacon's 12-byte nonce and 4-byte MIC.
/// Keeping it here avoids adding a crypto package to the app target.
public enum AESCCM {
    public static func decrypt(
        ciphertext: Data,
        tag: Data,
        key: Data,
        nonce: Data,
        associatedData: Data,
        tagLength: Int
    ) throws -> Data {
        try validate(key: key, nonce: nonce, tag: tag, tagLength: tagLength)
        let plaintext = try applyCTR(ciphertext, key: key, nonce: nonce)
        let mac = try cbcMAC(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData,
            tagLength: tagLength
        )
        let s0 = try ctrBlock(counter: 0, key: key, nonce: nonce)
        var expectedTag = [UInt8](repeating: 0, count: tagLength)
        for index in 0..<tagLength {
            expectedTag[index] = mac[index] ^ s0[index]
        }
        guard constantTimeEqual([UInt8](tag), expectedTag) else {
            throw AESCCMError.authenticationFailed
        }
        return plaintext
    }

    /// Encrypt helper for protocol vectors, diagnostics and fixture generation.
    public static func encrypt(
        plaintext: Data,
        key: Data,
        nonce: Data,
        associatedData: Data,
        tagLength: Int
    ) throws -> Data {
        let empty = Data(repeating: 0, count: tagLength)
        try validate(key: key, nonce: nonce, tag: empty, tagLength: tagLength)
        let mac = try cbcMAC(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData,
            tagLength: tagLength
        )
        let s0 = try ctrBlock(counter: 0, key: key, nonce: nonce)
        var result = try applyCTR(plaintext, key: key, nonce: nonce)
        for index in 0..<tagLength {
            result.append(mac[index] ^ s0[index])
        }
        return result
    }

    private static func validate(
        key: Data,
        nonce: Data,
        tag: Data,
        tagLength: Int
    ) throws {
        guard key.count == 16,
              (7...13).contains(nonce.count),
              tagLength >= 4,
              tagLength <= 16,
              tagLength.isMultiple(of: 2),
              tag.count == tagLength else {
            throw AESCCMError.invalidParameters
        }
    }

    private static func cbcMAC(
        plaintext: Data,
        key: Data,
        nonce: Data,
        associatedData: Data,
        tagLength: Int
    ) throws -> [UInt8] {
        let q = 15 - nonce.count
        if q < 8 {
            guard plaintext.count < (1 << (q * 8)) else { throw AESCCMError.invalidParameters }
        }
        let aes = AES128(key: [UInt8](key))
        let nonceBytes = [UInt8](nonce)

        var b0 = [UInt8]()
        b0.append(UInt8((associatedData.isEmpty ? 0 : 1 << 6) | (((tagLength - 2) / 2) << 3) | (q - 1)))
        b0.append(contentsOf: nonceBytes)
        appendBigEndian(plaintext.count, length: q, to: &b0)

        var state = [UInt8](repeating: 0, count: 16)
        state = aes.encrypt(xor(state, b0))

        if !associatedData.isEmpty {
            var encodedAAD = Data()
            if associatedData.count < 0xFF00 {
                appendBigEndian(associatedData.count, length: 2, to: &encodedAAD)
            } else if UInt64(associatedData.count) <= UInt64(UInt32.max) {
                encodedAAD.append(contentsOf: [0xFF, 0xFE])
                appendBigEndian(associatedData.count, length: 4, to: &encodedAAD)
            } else {
                encodedAAD.append(contentsOf: [0xFF, 0xFF])
                appendBigEndian(associatedData.count, length: 8, to: &encodedAAD)
            }
            encodedAAD.append(associatedData)
            processBlocks(encodedAAD, aes: aes, state: &state)
        }

        processBlocks(plaintext, aes: aes, state: &state)
        return state
    }

    private static func processBlocks(
        _ data: Data,
        aes: AES128,
        state: inout [UInt8]
    ) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            var block = [UInt8](repeating: 0, count: 16)
            let count = min(16, bytes.count - offset)
            for index in 0..<count { block[index] = bytes[offset + index] }
            state = aes.encrypt(xor(state, block))
            offset += count
        }
    }

    private static func applyCTR(
        _ input: Data,
        key: Data,
        nonce: Data
    ) throws -> Data {
        let bytes = [UInt8](input)
        let aes = AES128(key: [UInt8](key))
        var output = Data()
        output.reserveCapacity(bytes.count)
        var offset = 0
        var counter = 1
        while offset < bytes.count {
            let stream = try ctrBlock(counter: counter, key: key, nonce: nonce, aes: aes)
            let count = min(16, bytes.count - offset)
            for index in 0..<count { output.append(bytes[offset + index] ^ stream[index]) }
            offset += count
            counter += 1
        }
        return output
    }

    private static func ctrBlock(
        counter: Int,
        key: Data,
        nonce: Data,
        aes: AES128? = nil
    ) throws -> [UInt8] {
        let q = 15 - nonce.count
        guard counter >= 0 else { throw AESCCMError.invalidParameters }
        if q < 8 {
            guard counter < (1 << (q * 8)) else { throw AESCCMError.invalidParameters }
        }
        var block = [UInt8(q - 1)]
        block.append(contentsOf: nonce)
        appendBigEndian(counter, length: q, to: &block)
        return (aes ?? AES128(key: [UInt8](key))).encrypt(block)
    }

    private static func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        length: Int,
        to data: inout Data
    ) {
        let raw = UInt64(value)
        for shift in stride(from: (length - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: raw >> shift))
        }
    }

    private static func appendBigEndian(
        _ value: Int,
        length: Int,
        to bytes: inout [UInt8]
    ) {
        let raw = UInt64(value)
        for shift in stride(from: (length - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: raw >> shift))
        }
    }

    private static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        (0..<16).map { lhs[$0] ^ rhs[$0] }
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

private struct AES128 {
    private let roundKeys: [UInt8]

    init(key: [UInt8]) {
        var expanded = [UInt8](repeating: 0, count: 176)
        expanded.replaceSubrange(0..<16, with: key)
        var generated = 16
        var rcon: UInt8 = 1
        var temporary = [UInt8](repeating: 0, count: 4)

        while generated < expanded.count {
            for index in 0..<4 { temporary[index] = expanded[generated - 4 + index] }
            if generated % 16 == 0 {
                temporary = [temporary[1], temporary[2], temporary[3], temporary[0]]
                for index in 0..<4 { temporary[index] = Self.sbox[Int(temporary[index])] }
                temporary[0] ^= rcon
                rcon = xtime(rcon)
            }
            for index in 0..<4 {
                expanded[generated] = expanded[generated - 16] ^ temporary[index]
                generated += 1
            }
        }
        roundKeys = expanded
    }

    func encrypt(_ input: [UInt8]) -> [UInt8] {
        var state = input
        addRoundKey(round: 0, state: &state)
        for round in 1..<10 {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(round: round, state: &state)
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(round: 10, state: &state)
        return state
    }

    private func addRoundKey(round: Int, state: inout [UInt8]) {
        for index in 0..<16 { state[index] ^= roundKeys[round * 16 + index] }
    }

    private func subBytes(_ state: inout [UInt8]) {
        for index in 0..<16 { state[index] = Self.sbox[Int(state[index])] }
    }

    private func shiftRows(_ state: inout [UInt8]) {
        let old = state
        state[1] = old[5]; state[5] = old[9]; state[9] = old[13]; state[13] = old[1]
        state[2] = old[10]; state[6] = old[14]; state[10] = old[2]; state[14] = old[6]
        state[3] = old[15]; state[7] = old[3]; state[11] = old[7]; state[15] = old[11]
    }

    private func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let index = column * 4
            let a0 = state[index]
            let a1 = state[index + 1]
            let a2 = state[index + 2]
            let a3 = state[index + 3]
            let combined = a0 ^ a1 ^ a2 ^ a3
            state[index] ^= combined ^ xtime(a0 ^ a1)
            state[index + 1] ^= combined ^ xtime(a1 ^ a2)
            state[index + 2] ^= combined ^ xtime(a2 ^ a3)
            state[index + 3] ^= combined ^ xtime(a3 ^ a0)
        }
    }

    private static let sbox: [UInt8] = (0...255).map { value in
        let x = inverse(UInt8(value))
        return x ^ rotateLeft(x, by: 1) ^ rotateLeft(x, by: 2)
            ^ rotateLeft(x, by: 3) ^ rotateLeft(x, by: 4) ^ 0x63
    }

    private static func inverse(_ value: UInt8) -> UInt8 {
        guard value != 0 else { return 0 }
        var exponent = 254
        var base = value
        var result: UInt8 = 1
        while exponent > 0 {
            if exponent & 1 == 1 { result = multiply(result, base) }
            base = multiply(base, base)
            exponent >>= 1
        }
        return result
    }

    private static func multiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        var a = lhs
        var b = rhs
        var result: UInt8 = 0
        for _ in 0..<8 {
            if b & 1 == 1 { result ^= a }
            let high = a & 0x80
            a <<= 1
            if high != 0 { a ^= 0x1B }
            b >>= 1
        }
        return result
    }

    private static func rotateLeft(_ value: UInt8, by count: UInt8) -> UInt8 {
        (value << count) | (value >> (8 - count))
    }
}

private func xtime(_ value: UInt8) -> UInt8 {
    (value << 1) ^ ((value & 0x80) != 0 ? 0x1B : 0)
}
