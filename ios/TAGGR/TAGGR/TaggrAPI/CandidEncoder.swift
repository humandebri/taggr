import Foundation
import ICNativeClient

enum TaggrCandid {
    typealias FileRef = (id: String, offset: UInt64, length: UInt64)
    typealias CanisterStatus = (
        status: String,
        controllers: [String],
        moduleHash: Data?,
        memorySize: UInt64,
        cycles: UInt64,
        idleCyclesBurnedPerDay: UInt64
    )

    private enum CandidType {
        case primitive(Int64)
        case table(Int)
    }

    private enum CandidDefinition {
        case variant([(id: UInt64, type: CandidType)])
        case record([(id: UInt64, type: CandidType)])
        case vector(CandidType)
        case option(CandidType)
        case other
    }

    private indirect enum EncType {
        case primitive(Int64)
        case option(EncType)
        case vector(EncType)
        case record([(String, EncType)])
        case variant([(String, EncType)])
    }

    private indirect enum EncValue {
        case null
        case bool(Bool)
        case nat(UInt64)
        case nat64(UInt64)
        case text(String)
        case blob(Data)
        case principal(String)
        case option(EncValue?)
        case vector([EncValue])
        case record([String: EncValue])
        case variant(String, EncValue)
    }

    private struct Reader {
        var data: Data
        var offset = 0

        mutating func readByte() throws -> UInt8 {
            guard offset < data.count else {
                throw TaggrAPIError.invalidResponse("Candid response ended early.")
            }
            let byte = data[offset]
            offset += 1
            return byte
        }

        mutating func readBytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else {
                throw TaggrAPIError.invalidResponse("Candid response ended early.")
            }
            let value = data[offset..<(offset + count)]
            offset += count
            return Data(value)
        }

        mutating func readULEB() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try readByte()
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 {
                    return result
                }
                shift += 7
                if shift >= 64 {
                    throw TaggrAPIError.invalidResponse("Candid unsigned LEB128 is too large.")
                }
            }
        }

        mutating func readSLEB() throws -> Int64 {
            var result: Int64 = 0
            var shift: Int64 = 0
            var byte: UInt8
            repeat {
                byte = try readByte()
                result |= Int64(byte & 0x7f) << shift
                shift += 7
            } while byte & 0x80 != 0
            if shift < 64, byte & 0x40 != 0 {
                result |= -1 << shift
            }
            return result
        }

        mutating func readType() throws -> CandidType {
            let value = try readSLEB()
            if value < 0 {
                return .primitive(value)
            }
            guard value <= Int64(Int.max) else {
                throw TaggrAPIError.invalidResponse("Candid type reference is too large.")
            }
            return .table(Int(value))
        }

        mutating func readNat64() throws -> UInt64 {
            let bytes = try readBytes(8)
            return bytes.enumerated().reduce(UInt64(0)) { value, item in
                value | (UInt64(item.element) << UInt64(item.offset * 8))
            }
        }

        mutating func readNat16() throws -> UInt16 {
            let bytes = try readBytes(2)
            return bytes.enumerated().reduce(UInt16(0)) { value, item in
                value | (UInt16(item.element) << UInt16(item.offset * 8))
            }
        }

        mutating func readNat() throws -> UInt64 {
            try readULEB()
        }

        mutating func readBool() throws -> Bool {
            let value = try readByte()
            guard value == 0 || value == 1 else {
                throw TaggrAPIError.invalidResponse("Candid bool is invalid.")
            }
            return value == 1
        }

        mutating func readText() throws -> String {
            let length = Int(try readULEB())
            let data = try readBytes(length)
            guard let text = String(data: data, encoding: .utf8) else {
                throw TaggrAPIError.invalidResponse("Candid text is invalid UTF-8.")
            }
            return text
        }

        mutating func readPrincipal() throws -> String {
            let tag = try readByte()
            guard tag == 1 else {
                throw TaggrAPIError.invalidResponse("Candid principal reference is unsupported.")
            }
            let length = Int(try readULEB())
            let data = try readBytes(length)
            return ICPrincipal.text(from: data)
        }
    }

    static func encodeAddPost(
        text: String,
        refs: [FileRef] = [],
        parent: Int?,
        realm: String?,
        extensionBlob: Data? = nil
    ) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("066c030071017802786d006e786e716d7b6e04057101020305"))
        bytes.append(leb128(UInt64(text.utf8.count)))
        bytes.append(Data(text.utf8))
        appendFileRefs(refs, to: &bytes)
        appendOptionalNat64(parent.map(UInt64.init), to: &bytes)
        appendOptionalText(realm, to: &bytes)
        appendOptionalBlob(extensionBlob, to: &bytes)
        return bytes
    }

    static func throwIfRejectedResult(_ data: Data) throws {
        guard let message = try rejectedMessage(from: data) else {
            return
        }
        throw TaggrAPIError.rejected(message)
    }

    static func decodeResultNat64(_ data: Data) throws -> UInt64 {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("Candid result is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1 else {
            throw TaggrAPIError.invalidResponse("Candid result must contain exactly one value.")
        }
        let resultType = try reader.readType()
        guard let fields = variantFields(for: resultType, definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("Candid result is not a variant.")
        }
        let selected = Int(try reader.readULEB())
        guard fields.indices.contains(selected) else {
            throw TaggrAPIError.invalidResponse("Candid variant index is invalid.")
        }
        let field = fields[selected]
        if field.id == candidFieldId("Err") {
            guard case .primitive(-15) = field.type else {
                throw TaggrAPIError.rejected("TAGGR update rejected.")
            }
            let length = Int(try reader.readULEB())
            let message = try reader.readBytes(length)
            throw TaggrAPIError.rejected(String(data: message, encoding: .utf8) ?? "TAGGR update rejected.")
        }
        guard field.id == candidFieldId("Ok"), case .primitive(-8) = field.type else {
            throw TaggrAPIError.invalidResponse("Candid result Ok value is not nat64.")
        }
        return try reader.readNat64()
    }

    static func encodeEditPost(id: Int, text: String, refs: [FileRef] = [], patch: String, realm: String?) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("036c030071017802786d006e71057871017102"))
        appendNat64(UInt64(id), to: &bytes)
        bytes.append(leb128(UInt64(text.utf8.count)))
        bytes.append(Data(text.utf8))
        appendFileRefs(refs, to: &bytes)
        bytes.append(leb128(UInt64(patch.utf8.count)))
        bytes.append(Data(patch.utf8))
        appendOptionalText(realm, to: &bytes)
        return bytes
    }

    static func encodeRepostExtension(postId: Int) -> Data {
        Data(#"{"Repost":\#(postId)}"#.utf8)
    }

    static func encodeBucketWasmHash() -> Data {
        encodeEmpty()
    }

    static func encodeBucketWasm() -> Data {
        encodeEmpty()
    }

    static func encodeSetBucket(_ bucket: String) throws -> Data {
        try jsonArguments([bucket])
    }

    static func encodeCanisterStatus(canisterId: String) throws -> Data {
        try encodeCandid(
            types: [
                .record([
                    ("canister_id", .primitive(-24)),
                ]),
            ],
            values: [
                .record(["canister_id": .principal(canisterId)]),
            ]
        )
    }

    static func encodeNotifyCreateCanister(blockIndex: UInt64, controller: String, blackhole: String) throws -> Data {
        try encodeCandid(
            types: [
                .record([
                    ("block_index", .primitive(-8)),
                    ("controller", .primitive(-24)),
                    ("settings", .option(.record([
                        ("controllers", .option(.vector(.primitive(-24)))),
                        ("compute_allocation", .option(.primitive(-3))),
                        ("freezing_threshold", .option(.primitive(-3))),
                        ("log_visibility", .option(.variant([
                            ("controllers", .primitive(-1)),
                            ("public", .primitive(-1)),
                        ]))),
                        ("memory_allocation", .option(.primitive(-3))),
                        ("reserved_cycles_limit", .option(.primitive(-3))),
                        ("wasm_memory_limit", .option(.primitive(-3))),
                        ("wasm_memory_threshold", .option(.primitive(-3))),
                    ]))),
                    ("subnet_selection", .option(.variant([
                        ("Filter", .record([("subnet_type", .option(.primitive(-15)))])),
                        ("Subnet", .record([("subnet", .primitive(-24))])),
                    ]))),
                ]),
            ],
            values: [
                .record([
                    "block_index": .nat64(blockIndex),
                    "controller": .principal(controller),
                    "settings": .option(.record([
                        "controllers": .option(.vector([.principal(controller), .principal(blackhole)])),
                        "compute_allocation": .option(nil),
                        "freezing_threshold": .option(nil),
                        "log_visibility": .option(nil),
                        "memory_allocation": .option(nil),
                        "reserved_cycles_limit": .option(nil),
                        "wasm_memory_limit": .option(nil),
                        "wasm_memory_threshold": .option(nil),
                    ])),
                    "subnet_selection": .option(nil),
                ]),
            ]
        )
    }

    static func encodeNotifyTopUp(blockIndex: UInt64, canisterId: String) throws -> Data {
        try encodeCandid(
            types: [
                .record([
                    ("block_index", .primitive(-8)),
                    ("canister_id", .primitive(-24)),
                ]),
            ],
            values: [
                .record([
                    "block_index": .nat64(blockIndex),
                    "canister_id": .principal(canisterId),
                ]),
            ]
        )
    }

    static func encodeInstallBucketCode(canisterId: String, wasm: Data, userPrincipal: String, mode: String) throws -> Data {
        let initArg = try encodeCandid(
            types: [.vector(.primitive(-24))],
            values: [.vector([.principal(userPrincipal)])]
        )
        return try encodeCandid(
            types: [
                .record([
                    ("arg", .vector(.primitive(-5))),
                    ("canister_id", .primitive(-24)),
                    ("mode", .variant([
                        ("install", .primitive(-1)),
                        ("reinstall", .primitive(-1)),
                        ("upgrade", .option(.record([
                            ("skip_pre_upgrade", .option(.primitive(-2))),
                            ("wasm_memory_persistence", .option(.variant([
                                ("keep", .primitive(-1)),
                                ("replace", .primitive(-1)),
                            ]))),
                        ]))),
                    ])),
                    ("sender_canister_version", .option(.primitive(-8))),
                    ("wasm_module", .vector(.primitive(-5))),
                ]),
            ],
            values: [
                .record([
                    "arg": .blob(mode == "install" || mode == "reinstall" ? initArg : Data()),
                    "canister_id": .principal(canisterId),
                    "mode": .variant(mode, mode == "upgrade" ? .option(nil) : .null),
                    "sender_canister_version": .option(nil),
                    "wasm_module": .blob(wasm),
                ]),
            ]
        )
    }

    static func encodeUpdateSettings(canisterId: String, controllers: [String]) throws -> Data {
        try encodeCandid(
            types: [
                .record([
                    ("canister_id", .primitive(-24)),
                    ("sender_canister_version", .option(.primitive(-8))),
                    ("settings", .record([
                        ("controllers", .option(.vector(.primitive(-24)))),
                        ("compute_allocation", .option(.primitive(-3))),
                        ("freezing_threshold", .option(.primitive(-3))),
                        ("log_visibility", .option(.variant([
                            ("controllers", .primitive(-1)),
                            ("public", .primitive(-1)),
                        ]))),
                        ("memory_allocation", .option(.primitive(-3))),
                        ("reserved_cycles_limit", .option(.primitive(-3))),
                        ("wasm_memory_limit", .option(.primitive(-3))),
                        ("wasm_memory_threshold", .option(.primitive(-3))),
                    ])),
                ]),
            ],
            values: [
                .record([
                    "canister_id": .principal(canisterId),
                    "sender_canister_version": .option(nil),
                    "settings": .record([
                        "controllers": .option(.vector(controllers.map { .principal($0) })),
                        "compute_allocation": .option(nil),
                        "freezing_threshold": .option(nil),
                        "log_visibility": .option(nil),
                        "memory_allocation": .option(nil),
                        "reserved_cycles_limit": .option(nil),
                        "wasm_memory_limit": .option(nil),
                        "wasm_memory_threshold": .option(nil),
                    ]),
                ]),
            ]
        )
    }

    static func encodeUpdateInternalControllers(_ controllers: [String]) throws -> Data {
        try encodeCandid(
            types: [.vector(.primitive(-24))],
            values: [.vector(controllers.map { .principal($0) })]
        )
    }

    static func encodeEmpty() -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(0)
        bytes.append(0)
        return bytes
    }

    static func encodeICPAccountBalance(account: Data) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(leb128(2))
        bytes.append(sleb128(-19))
        bytes.append(sleb128(-5))
        bytes.append(sleb128(-20))
        bytes.append(leb128(1))
        bytes.append(leb128(candidFieldId("account")))
        bytes.append(sleb128(0))
        bytes.append(leb128(1))
        bytes.append(sleb128(1))
        appendBlob(account, to: &bytes)
        return bytes
    }

    static func encodeICPTransfer(to account: Data, amountE8s: UInt64, feeE8s: UInt64, memo: UInt64 = 0) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(leb128(3))
        bytes.append(sleb128(-19))
        bytes.append(sleb128(-5))
        bytes.append(sleb128(-20))
        bytes.append(leb128(1))
        bytes.append(leb128(candidFieldId("e8s")))
        bytes.append(sleb128(-8))
        bytes.append(sleb128(-20))
        bytes.append(leb128(4))
        bytes.append(leb128(candidFieldId("to")))
        bytes.append(sleb128(0))
        bytes.append(leb128(candidFieldId("fee")))
        bytes.append(sleb128(1))
        bytes.append(leb128(candidFieldId("memo")))
        bytes.append(sleb128(-8))
        bytes.append(leb128(candidFieldId("amount")))
        bytes.append(sleb128(1))
        bytes.append(leb128(1))
        bytes.append(sleb128(2))
        appendBlob(account, to: &bytes)
        appendNat64(feeE8s, to: &bytes)
        appendNat64(memo, to: &bytes)
        appendNat64(amountE8s, to: &bytes)
        return bytes
    }

    static func decodeICPTokens(_ data: Data) throws -> UInt64 {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("ICP tokens response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        _ = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1 else {
            throw TaggrAPIError.invalidResponse("ICP tokens response must contain exactly one value.")
        }
        _ = try reader.readType()
        return try reader.readNat64()
    }

    static func decodeICPTransferResult(_ data: Data) throws -> UInt64 {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("ICP transfer response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1 else {
            throw TaggrAPIError.invalidResponse("ICP transfer response must contain exactly one value.")
        }
        let resultType = try reader.readType()
        guard let resultFields = variantFields(for: resultType, definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("ICP transfer response is not a result variant.")
        }
        let selected = Int(try reader.readULEB())
        guard resultFields.indices.contains(selected) else {
            throw TaggrAPIError.invalidResponse("ICP transfer result index is invalid.")
        }
        let field = resultFields[selected]
        if field.id == candidFieldId("Ok") {
            return try reader.readNat64()
        }
        guard field.id == candidFieldId("Err"),
              let errorFields = variantFields(for: field.type, definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("ICP transfer response has an unknown result shape.")
        }
        let errorIndex = Int(try reader.readULEB())
        guard errorFields.indices.contains(errorIndex) else {
            throw TaggrAPIError.invalidResponse("ICP transfer error index is invalid.")
        }
        let error = errorFields[errorIndex]
        switch error.id {
        case candidFieldId("BadFee"):
            throw TaggrAPIError.rejected("ICP transfer fee should be \(ICPAmount.format(try readSingleE8sRecord(type: error.type, definitions: definitions, reader: &reader))).")
        case candidFieldId("InsufficientFunds"):
            throw TaggrAPIError.rejected("ICP balance too low. Current balance: \(ICPAmount.format(try readSingleE8sRecord(type: error.type, definitions: definitions, reader: &reader))).")
        case candidFieldId("TxTooOld"):
            _ = try readSingleNat64Record(type: error.type, definitions: definitions, reader: &reader)
            throw TaggrAPIError.rejected("ICP transfer request is too old.")
        case candidFieldId("TxCreatedInFuture"):
            throw TaggrAPIError.rejected("ICP transfer request was created in the future.")
        case candidFieldId("TxDuplicate"):
            throw TaggrAPIError.rejected("ICP transfer was already submitted in block \(try readSingleNat64Record(type: error.type, definitions: definitions, reader: &reader)).")
        default:
            throw TaggrAPIError.rejected("ICP transfer failed.")
        }
    }

    static func decodeBlob(_ data: Data, label: String) throws -> Data {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("\(label) response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1 else {
            throw TaggrAPIError.invalidResponse("\(label) response must contain exactly one value.")
        }
        let type = try reader.readType()
        guard case .table(let index) = type,
              definitions.indices.contains(index),
              case .vector(.primitive(-5)) = definitions[index] else {
            throw TaggrAPIError.invalidResponse("\(label) response is not a byte vector.")
        }
        return try reader.readBytes(Int(try reader.readULEB()))
    }

    static func encodeBucketHTTPRequest(offset: UInt64, length: Int) -> Data {
        var bytes = Data("DIDL".utf8)
        bytes.append(contentsOf: hex("036c02007101716d006c02efd6e40271c6a4a19806010102"))
        let path = "/image?offset=\(offset)&len=\(length)"
        bytes.append(leb128(UInt64(path.utf8.count)))
        bytes.append(Data(path.utf8))
        bytes.append(0)
        return bytes
    }

    static func decodeBucketHTTPResponseBody(_ data: Data) throws -> Data {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("bucket http_request response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1,
              let fields = recordFields(for: try reader.readType(), definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("bucket http_request response is not a record.")
        }

        var statusCode: UInt16?
        var body: Data?
        for field in fields {
            switch field.id {
            case candidFieldId("status_code"):
                statusCode = try reader.readNat16()
            case candidFieldId("body"):
                body = try readBlob(type: field.type, definitions: definitions, reader: &reader)
            default:
                try skipValue(type: field.type, definitions: definitions, reader: &reader)
            }
        }

        guard let statusCode, (200..<300).contains(Int(statusCode)) else {
            throw TaggrAPIError.invalidResponse("bucket http_request returned status \(statusCode.map(String.init) ?? "unknown").")
        }
        guard let body else {
            throw TaggrAPIError.invalidResponse("bucket http_request response is missing body.")
        }
        return body
    }

    static func decodeText(_ data: Data, label: String) throws -> String {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("\(label) response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        _ = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1 else {
            throw TaggrAPIError.invalidResponse("\(label) response must contain exactly one value.")
        }
        guard case .primitive(-15) = try reader.readType() else {
            throw TaggrAPIError.invalidResponse("\(label) response is not text.")
        }
        return try reader.readText()
    }

    static func decodeNotifyCreateCanister(_ data: Data) throws -> String {
        try decodeResult(data, label: "notify_create_canister") { type, definitions, reader in
            guard case .primitive(-24) = type else {
                throw TaggrAPIError.invalidResponse("notify_create_canister Ok is not principal.")
            }
            return try reader.readPrincipal()
        }
    }

    static func decodeNotifyTopUp(_ data: Data) throws -> UInt64 {
        try decodeResult(data, label: "notify_top_up") { type, _, reader in
            guard case .primitive(-3) = type else {
                throw TaggrAPIError.invalidResponse("notify_top_up Ok is not nat.")
            }
            return try reader.readNat()
        }
    }

    static func decodeCanisterStatus(_ data: Data) throws -> CanisterStatus {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("canister_status response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1,
              let fields = recordFields(for: try reader.readType(), definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("canister_status response is not a record.")
        }

        var status = "unknown"
        var controllers: [String] = []
        var moduleHash: Data?
        var memorySize: UInt64 = 0
        var cycles: UInt64 = 0
        var idleCyclesBurnedPerDay: UInt64 = 0

        for field in fields {
            switch field.id {
            case candidFieldId("status"):
                status = try readVariantLabel(type: field.type, definitions: definitions, reader: &reader)
            case candidFieldId("settings"):
                controllers = try readControllersFromSettings(type: field.type, definitions: definitions, reader: &reader)
            case candidFieldId("module_hash"):
                moduleHash = try readOptionalBlob(type: field.type, definitions: definitions, reader: &reader)
            case candidFieldId("memory_size"):
                memorySize = try reader.readNat()
            case candidFieldId("cycles"):
                cycles = try reader.readNat()
            case candidFieldId("idle_cycles_burned_per_day"):
                idleCyclesBurnedPerDay = try reader.readNat()
            default:
                try skipValue(type: field.type, definitions: definitions, reader: &reader)
            }
        }

        return (status, controllers, moduleHash, memorySize, cycles, idleCyclesBurnedPerDay)
    }

    static func jsonArguments(_ values: [Any?]) throws -> Data {
        let object: Any
        if values.isEmpty {
            object = NSNull()
        } else if values.count == 1 {
            object = values[0] ?? NSNull()
        } else {
            object = values.map { $0 ?? NSNull() }
        }
        // TAGGR の JSON query/update は単一の primitive や null も引数に使う。
        // JSONSerialization の標準設定は top-level fragment を拒否するため、
        // Swift 側で Objective-C 例外にせず通常の throw 経路へ閉じる。
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    private static func encodeCandid(types: [EncType], values: [EncValue]) throws -> Data {
        var table: [EncType] = []
        var indices: [String: Int] = [:]
        for type in types {
            _ = collect(type, table: &table, indices: &indices)
        }

        var bytes = Data("DIDL".utf8)
        bytes.append(leb128(UInt64(table.count)))
        for type in table {
            appendTypeDefinition(type, table: table, indices: indices, to: &bytes)
        }
        bytes.append(leb128(UInt64(types.count)))
        for type in types {
            appendTypeReference(type, table: table, indices: indices, to: &bytes)
        }
        for (type, value) in zip(types, values) {
            try appendValue(value, type: type, table: table, indices: indices, to: &bytes)
        }
        return bytes
    }

    @discardableResult
    private static func collect(_ type: EncType, table: inout [EncType], indices: inout [String: Int]) -> Int? {
        switch type {
        case .primitive:
            return nil
        case .option(let wrapped), .vector(let wrapped):
            _ = collect(wrapped, table: &table, indices: &indices)
        case .record(let fields), .variant(let fields):
            for (_, child) in sorted(fields) {
                _ = collect(child, table: &table, indices: &indices)
            }
        }

        let key = signature(type)
        if let index = indices[key] {
            return index
        }
        let index = table.count
        table.append(type)
        indices[key] = index
        return index
    }

    private static func appendTypeDefinition(_ type: EncType, table: [EncType], indices: [String: Int], to bytes: inout Data) {
        switch type {
        case .primitive:
            break
        case .option(let wrapped):
            bytes.append(sleb128(-18))
            appendTypeReference(wrapped, table: table, indices: indices, to: &bytes)
        case .vector(let wrapped):
            bytes.append(sleb128(-19))
            appendTypeReference(wrapped, table: table, indices: indices, to: &bytes)
        case .record(let fields):
            bytes.append(sleb128(-20))
            let fields = sorted(fields)
            bytes.append(leb128(UInt64(fields.count)))
            for (label, fieldType) in fields {
                bytes.append(leb128(candidFieldId(label)))
                appendTypeReference(fieldType, table: table, indices: indices, to: &bytes)
            }
        case .variant(let fields):
            bytes.append(sleb128(-21))
            let fields = sorted(fields)
            bytes.append(leb128(UInt64(fields.count)))
            for (label, fieldType) in fields {
                bytes.append(leb128(candidFieldId(label)))
                appendTypeReference(fieldType, table: table, indices: indices, to: &bytes)
            }
        }
    }

    private static func appendTypeReference(_ type: EncType, table: [EncType], indices: [String: Int], to bytes: inout Data) {
        switch type {
        case .primitive(let code):
            bytes.append(sleb128(code))
        default:
            bytes.append(sleb128(Int64(indices[signature(type)] ?? 0)))
        }
    }

    private static func appendValue(_ value: EncValue, type: EncType, table: [EncType], indices: [String: Int], to bytes: inout Data) throws {
        switch (type, value) {
        case (.primitive(-1), .null):
            return
        case (.primitive(-2), .bool(let value)):
            bytes.append(value ? 1 : 0)
        case (.primitive(-3), .nat(let value)):
            bytes.append(leb128(value))
        case (.primitive(-5), .nat(let value)):
            bytes.append(UInt8(value))
        case (.primitive(-8), .nat64(let value)):
            appendNat64(value, to: &bytes)
        case (.primitive(-15), .text(let value)):
            bytes.append(leb128(UInt64(value.utf8.count)))
            bytes.append(Data(value.utf8))
        case (.primitive(-24), .principal(let value)):
            guard let principal = ICPrincipal.parse(value) else {
                throw TaggrAPIError.invalidResponse("Invalid principal \(value).")
            }
            bytes.append(1)
            bytes.append(leb128(UInt64(principal.count)))
            bytes.append(principal)
        case (.option(let wrapped), .option(let optional)):
            guard let optional else {
                bytes.append(0)
                return
            }
            bytes.append(1)
            try appendValue(optional, type: wrapped, table: table, indices: indices, to: &bytes)
        case (.vector(.primitive(-5)), .blob(let value)):
            appendBlob(value, to: &bytes)
        case (.vector(let element), .vector(let values)):
            bytes.append(leb128(UInt64(values.count)))
            for value in values {
                try appendValue(value, type: element, table: table, indices: indices, to: &bytes)
            }
        case (.record(let fields), .record(let values)):
            for (label, fieldType) in sorted(fields) {
                guard let fieldValue = values[label] else {
                    throw TaggrAPIError.invalidResponse("Missing Candid field \(label).")
                }
                try appendValue(fieldValue, type: fieldType, table: table, indices: indices, to: &bytes)
            }
        case (.variant(let fields), .variant(let label, let associated)):
            let fields = sorted(fields)
            guard let index = fields.firstIndex(where: { $0.0 == label }) else {
                throw TaggrAPIError.invalidResponse("Missing Candid variant \(label).")
            }
            bytes.append(leb128(UInt64(index)))
            try appendValue(associated, type: fields[index].1, table: table, indices: indices, to: &bytes)
        default:
            throw TaggrAPIError.invalidResponse("Unsupported Candid value.")
        }
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

    private static func appendOptionalBlob(_ value: Data?, to bytes: inout Data) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        bytes.append(leb128(UInt64(value.count)))
        bytes.append(value)
    }

    private static func appendFileRefs(_ refs: [FileRef], to bytes: inout Data) {
        bytes.append(leb128(UInt64(refs.count)))
        for ref in refs {
            bytes.append(leb128(UInt64(ref.id.utf8.count)))
            bytes.append(Data(ref.id.utf8))
            appendNat64(ref.offset, to: &bytes)
            appendNat64(ref.length, to: &bytes)
        }
    }

    private static func appendBlob(_ value: Data, to bytes: inout Data) {
        bytes.append(leb128(UInt64(value.count)))
        bytes.append(value)
    }

    private static func appendNat64(_ value: UInt64, to bytes: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func sleb128(_ value: Int64) -> Data {
        var value = value
        var bytes = Data()
        var more = true
        while more {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            let signBitSet = byte & 0x40 != 0
            more = !((value == 0 && !signBitSet) || (value == -1 && signBitSet))
            if more {
                byte |= 0x80
            }
            bytes.append(byte)
        }
        return bytes
    }

    private static func hex(_ value: String) -> Data {
        Data(icHex: value) ?? Data()
    }

    private static func sorted(_ fields: [(String, EncType)]) -> [(String, EncType)] {
        fields.sorted { lhs, rhs in
            let left = candidFieldId(lhs.0)
            let right = candidFieldId(rhs.0)
            return left == right ? lhs.0 < rhs.0 : left < right
        }
    }

    private static func signature(_ type: EncType) -> String {
        switch type {
        case .primitive(let code):
            return "p\(code)"
        case .option(let wrapped):
            return "o(\(signature(wrapped)))"
        case .vector(let wrapped):
            return "v(\(signature(wrapped)))"
        case .record(let fields):
            return "r{\(sorted(fields).map { "\($0.0):\(signature($0.1))" }.joined(separator: ","))}"
        case .variant(let fields):
            return "x{\(sorted(fields).map { "\($0.0):\(signature($0.1))" }.joined(separator: ","))}"
        }
    }

    private static func rejectedMessage(from data: Data) throws -> String? {
        guard data.starts(with: Data("DIDL".utf8)) else {
            return nil
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1 else {
            return nil
        }
        let resultType = try reader.readType()
        guard let fields = variantFields(for: resultType, definitions: definitions) else {
            return nil
        }
        let selected = Int(try reader.readULEB())
        guard fields.indices.contains(selected) else {
            throw TaggrAPIError.invalidResponse("Candid variant index is invalid.")
        }
        let field = fields[selected]
        guard field.id == candidFieldId("Err") else {
            return nil
        }
        guard case .primitive(-15) = field.type else {
            return "TAGGR update rejected."
        }
        let length = Int(try reader.readULEB())
        let message = try reader.readBytes(length)
        return String(data: message, encoding: .utf8) ?? "TAGGR update rejected."
    }

    private static func decodeResult<T>(
        _ data: Data,
        label: String,
        ok: (CandidType, [CandidDefinition], inout Reader) throws -> T
    ) throws -> T {
        guard data.starts(with: Data("DIDL".utf8)) else {
            throw TaggrAPIError.invalidResponse("\(label) response is missing DIDL header.")
        }
        var reader = Reader(data: data, offset: 4)
        let definitions = try readDefinitions(from: &reader)
        let argCount = try reader.readULEB()
        guard argCount == 1,
              let fields = variantFields(for: try reader.readType(), definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("\(label) response is not a result variant.")
        }
        let selected = Int(try reader.readULEB())
        guard fields.indices.contains(selected) else {
            throw TaggrAPIError.invalidResponse("\(label) result index is invalid.")
        }
        let field = fields[selected]
        if field.id == candidFieldId("Ok") {
            return try ok(field.type, definitions, &reader)
        }
        if field.id == candidFieldId("Err") {
            throw TaggrAPIError.rejected("\(label) failed.")
        }
        throw TaggrAPIError.invalidResponse("\(label) response has unknown result field.")
    }

    private static func readVariantLabel(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> String {
        guard let fields = variantFields(for: type, definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("Candid value is not a variant.")
        }
        let selected = Int(try reader.readULEB())
        guard fields.indices.contains(selected) else {
            throw TaggrAPIError.invalidResponse("Candid variant index is invalid.")
        }
        try skipValue(type: fields[selected].type, definitions: definitions, reader: &reader)
        return knownLabel(for: fields[selected].id)
    }

    private static func readControllersFromSettings(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> [String] {
        guard let fields = recordFields(for: type, definitions: definitions) else {
            throw TaggrAPIError.invalidResponse("canister_status settings is not a record.")
        }
        var controllers: [String] = []
        for field in fields {
            if field.id == candidFieldId("controllers") {
                controllers = try readPrincipalVector(type: field.type, definitions: definitions, reader: &reader)
            } else {
                try skipValue(type: field.type, definitions: definitions, reader: &reader)
            }
        }
        return controllers
    }

    private static func readPrincipalVector(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> [String] {
        guard case .table(let index) = type,
              definitions.indices.contains(index),
              case .vector(.primitive(-24)) = definitions[index] else {
            throw TaggrAPIError.invalidResponse("Candid value is not vec principal.")
        }
        let count = Int(try reader.readULEB())
        return try (0..<count).map { _ in try reader.readPrincipal() }
    }

    private static func readOptionalBlob(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> Data? {
        guard case .table(let index) = type,
              definitions.indices.contains(index),
              case .option(let wrapped) = definitions[index] else {
            throw TaggrAPIError.invalidResponse("Candid value is not opt blob.")
        }
        let present = try reader.readByte()
        guard present == 0 || present == 1 else {
            throw TaggrAPIError.invalidResponse("Candid opt marker is invalid.")
        }
        guard present == 1 else { return nil }
        guard case .table(let vectorIndex) = wrapped,
              definitions.indices.contains(vectorIndex),
              case .vector(.primitive(-5)) = definitions[vectorIndex] else {
            throw TaggrAPIError.invalidResponse("Candid opt value is not blob.")
        }
        return try reader.readBytes(Int(try reader.readULEB()))
    }

    private static func readBlob(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> Data {
        guard case .table(let index) = type,
              definitions.indices.contains(index),
              case .vector(.primitive(-5)) = definitions[index] else {
            throw TaggrAPIError.invalidResponse("Candid value is not blob.")
        }
        return try reader.readBytes(Int(try reader.readULEB()))
    }

    private static func skipValue(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws {
        switch type {
        case .primitive(-1):
            return
        case .primitive(-2):
            _ = try reader.readBool()
        case .primitive(-3):
            _ = try reader.readNat()
        case .primitive(-5):
            _ = try reader.readByte()
        case .primitive(-6):
            _ = try reader.readBytes(2)
        case .primitive(-8):
            _ = try reader.readNat64()
        case .primitive(-15):
            _ = try reader.readText()
        case .primitive(-24):
            _ = try reader.readPrincipal()
        case .table(let index):
            guard definitions.indices.contains(index) else {
                throw TaggrAPIError.invalidResponse("Candid type reference is invalid.")
            }
            switch definitions[index] {
            case .option(let wrapped):
                let present = try reader.readByte()
                if present == 1 {
                    try skipValue(type: wrapped, definitions: definitions, reader: &reader)
                }
            case .vector(let wrapped):
                let count = Int(try reader.readULEB())
                for _ in 0..<count {
                    try skipValue(type: wrapped, definitions: definitions, reader: &reader)
                }
            case .record(let fields):
                for field in fields {
                    try skipValue(type: field.type, definitions: definitions, reader: &reader)
                }
            case .variant(let fields):
                let selected = Int(try reader.readULEB())
                guard fields.indices.contains(selected) else {
                    throw TaggrAPIError.invalidResponse("Candid variant index is invalid.")
                }
                try skipValue(type: fields[selected].type, definitions: definitions, reader: &reader)
            case .other:
                throw TaggrAPIError.invalidResponse("Unsupported Candid value.")
            }
        default:
            throw TaggrAPIError.invalidResponse("Unsupported Candid primitive.")
        }
    }

    private static func knownLabel(for id: UInt64) -> String {
        [
            "running",
            "stopping",
            "stopped",
            "controllers",
            "public",
            "allowed_viewers",
            "Ok",
            "Err",
        ].first { candidFieldId($0) == id } ?? "\(id)"
    }

    private static func readDefinitions(from reader: inout Reader) throws -> [CandidDefinition] {
        let count = Int(try reader.readULEB())
        var definitions: [CandidDefinition] = []
        definitions.reserveCapacity(count)
        for _ in 0..<count {
            let code = try reader.readSLEB()
            switch code {
            case -21:
                definitions.append(.variant(try readFields(from: &reader)))
            case -20:
                definitions.append(.record(try readFields(from: &reader)))
            case -19:
                definitions.append(.vector(try reader.readType()))
            case -18:
                definitions.append(.option(try reader.readType()))
            default:
                definitions.append(.other)
            }
        }
        return definitions
    }

    private static func readFields(from reader: inout Reader) throws -> [(id: UInt64, type: CandidType)] {
        let count = Int(try reader.readULEB())
        var fields: [(id: UInt64, type: CandidType)] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            let id = try reader.readULEB()
            let type = try reader.readType()
            fields.append((id, type))
        }
        return fields
    }

    private static func variantFields(for type: CandidType, definitions: [CandidDefinition]) -> [(id: UInt64, type: CandidType)]? {
        guard case .table(let index) = type,
              definitions.indices.contains(index),
              case .variant(let fields) = definitions[index] else {
            return nil
        }
        return fields
    }

    private static func recordFields(for type: CandidType, definitions: [CandidDefinition]) -> [(id: UInt64, type: CandidType)]? {
        guard case .table(let index) = type,
              definitions.indices.contains(index),
              case .record(let fields) = definitions[index] else {
            return nil
        }
        return fields
    }

    private static func readSingleE8sRecord(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> UInt64 {
        guard let fields = recordFields(for: type, definitions: definitions),
              fields.count == 1,
              fields[0].id == candidFieldId("e8s") || fields[0].id == candidFieldId("expected_fee") || fields[0].id == candidFieldId("balance") else {
            throw TaggrAPIError.invalidResponse("ICP transfer error record is invalid.")
        }
        return try reader.readNat64()
    }

    private static func readSingleNat64Record(type: CandidType, definitions: [CandidDefinition], reader: inout Reader) throws -> UInt64 {
        guard let fields = recordFields(for: type, definitions: definitions),
              fields.count == 1 else {
            throw TaggrAPIError.invalidResponse("ICP transfer error record is invalid.")
        }
        return try reader.readNat64()
    }

    private static func candidFieldId(_ label: String) -> UInt64 {
        var hash: UInt32 = 0
        for byte in label.utf8 {
            hash = hash &* 223 &+ UInt32(byte)
        }
        return UInt64(hash)
    }
}
