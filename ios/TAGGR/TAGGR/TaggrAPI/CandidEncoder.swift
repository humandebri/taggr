import Foundation

enum TaggrCandid {
    static func encodeAddPost(text: String, parent: Int?, realm: String?) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("066d7b6c02007101006d016e786e716e00057102030405"))
        bytes.append(leb128(UInt64(text.utf8.count)))
        bytes.append(Data(text.utf8))
        bytes.append(0)
        appendOptionalNat64(parent.map(UInt64.init), to: &bytes)
        appendOptionalText(realm, to: &bytes)
        bytes.append(0)
        return bytes
    }

    static func encodeEditPost(id: Int, text: String, patch: String, realm: String?) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("046d7b6c02007101006d016e710578027103"))
        appendNat64(UInt64(id), to: &bytes)
        bytes.append(leb128(UInt64(text.utf8.count)))
        bytes.append(Data(text.utf8))
        bytes.append(0)
        bytes.append(leb128(UInt64(patch.utf8.count)))
        bytes.append(Data(patch.utf8))
        appendOptionalText(realm, to: &bytes)
        return bytes
    }

    static func encodePostData(text: String, realm: String?) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("036e716d7b6e0103710002"))
        bytes.append(leb128(UInt64(text.utf8.count)))
        bytes.append(Data(text.utf8))
        appendOptionalText(realm, to: &bytes)
        bytes.append(0)
        return bytes
    }

    static func encodePostBlob(id: String, blob: Data) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("016d7b027100"))
        bytes.append(leb128(UInt64(id.utf8.count)))
        bytes.append(Data(id.utf8))
        bytes.append(leb128(UInt64(blob.count)))
        bytes.append(blob)
        return bytes
    }

    static func encodeEmpty() -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(0)
        bytes.append(0)
        return bytes
    }

    static func jsonArguments(_ values: [Any?]) throws -> Data {
        let compact = values.compactMap { $0 }
        let object: Any
        if compact.isEmpty {
            object = NSNull()
        } else if compact.count == 1 {
            object = compact[0]
        } else {
            object = compact
        }
        // TAGGR の JSON query/update は単一の primitive や null も引数に使う。
        // JSONSerialization の標準設定は top-level fragment を拒否するため、
        // Swift 側で Objective-C 例外にせず通常の throw 経路へ閉じる。
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    static func leb128(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private static func appendOptionalNat64(_ value: UInt64?, to bytes: inout Data) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        appendNat64(value, to: &bytes)
    }

    private static func appendOptionalText(_ value: String?, to bytes: inout Data) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        bytes.append(leb128(UInt64(value.utf8.count)))
        bytes.append(Data(value.utf8))
    }

    private static func appendNat64(_ value: UInt64, to bytes: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func hex(_ value: String) -> Data {
        Data(hex: value) ?? Data()
    }
}
