import CryptoKit
import Foundation

enum PrincipalBlob {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func parse(_ text: String) -> Data? {
        let cleaned = text.lowercased().filter { $0 != "-" }
        var buffer = 0
        var bits = 0
        var bytes = [UInt8]()
        for character in cleaned {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        guard bytes.count > 4 else { return nil }
        return Data(bytes.dropFirst(4))
    }

    static func selfAuthenticatingPublicKey(_ publicKey: Data) -> Data {
        TaggrSHA224.hash(publicKey) + Data([0x02])
    }

    static func text(from blob: Data) -> String {
        let withChecksum = Data(CRC32.checksum(blob).bigEndianBytes) + blob
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in withChecksum {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 0x1f])
            }
        }
        if bits > 0 {
            output.append(alphabet[(buffer << (5 - bits)) & 0x1f])
        }
        return stride(from: 0, to: output.count, by: 5)
            .map {
                let start = output.index(output.startIndex, offsetBy: $0)
                let length = min(5, output.distance(from: start, to: output.endIndex))
                let end = output.index(start, offsetBy: length)
                return String(output[start..<end])
            }
            .joined(separator: "-")
    }
}

enum TaggrRequestID {
    static func hash(of value: TaggrCBOR.Value) -> Data {
        switch value {
        case .text(let text):
            return sha256(Data(text.utf8))
        case .bytes(let bytes):
            return sha256(bytes)
        case .unsigned(let value):
            return sha256(TaggrCandid.leb128(value))
        case .array(let values):
            return sha256(values.reduce(into: Data()) { $0.append(hash(of: $1)) })
        case .map(let values):
            let hashed = values.map { key, value in
                (hash(of: key), hash(of: value))
            }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
            return sha256(hashed.reduce(into: Data()) {
                $0.append($1.0)
                $0.append($1.1)
            })
        case .tagged(_, let value):
            return hash(of: value)
        }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

enum TaggrSHA224 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> Data {
        var message = data
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        message.append(contentsOf: bitLength.bigEndianBytes)

        var h: [UInt32] = [0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939, 0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4]
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset]) << 24
                words[index] |= UInt32(message[offset + 1]) << 16
                words[index] |= UInt32(message[offset + 2]) << 8
                words[index] |= UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let word15 = words[index - 15]
                let word2 = words[index - 2]
                let s0 = word15.rotatedRight(7) ^ word15.rotatedRight(18) ^ (word15 >> 3)
                let s1 = word2.rotatedRight(17) ^ word2.rotatedRight(19) ^ (word2 >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for index in 0..<64 {
                let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ constants[index] &+ words[index]
                let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ s0 &+ maj
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        return h.prefix(7).reduce(into: Data()) { $0.append(contentsOf: $1.bigEndianBytes) }
    }
}

enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0xffff_ffff)) { partial, byte in
            var crc = partial ^ UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
            return crc
        } ^ 0xffff_ffff
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}

private extension UInt32 {
    func rotatedRight(_ amount: UInt32) -> UInt32 {
        (self >> amount) | (self << (32 - amount))
    }
}
