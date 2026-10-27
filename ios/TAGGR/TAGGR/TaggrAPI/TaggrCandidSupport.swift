import Foundation

/// App-owned values for TAGGR's JSON transport and post attachment model.
/// Binary Candid encoding/decoding belongs to the generated bindings.
enum TaggrCandid {
    typealias FileRef = (id: String, offset: UInt64, length: UInt64)

    static func jsonArguments(_ values: [Any?]) throws -> Data {
        let object: Any
        if values.isEmpty {
            object = NSNull()
        } else if values.count == 1 {
            object = values[0] ?? NSNull()
        } else {
            object = values.map { $0 ?? NSNull() }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}
