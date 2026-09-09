import Foundation
import ICNativeClient

enum TaggrCandidAdapter {
    typealias FileRef = TaggrCandid.FileRef

    static func emptyArguments() -> CandidArguments {
        CandidArguments()
    }

    static func addPostArguments(
        text: String,
        refs: [FileRef],
        parent: Int?,
        realm: String?,
        extensionBlob: Data?
    ) throws -> CandidArguments {
        let arguments = try addPostModel(
            text: text,
            refs: refs,
            parent: parent,
            realm: realm,
            extensionBlob: extensionBlob
        )
        return try candidArguments(
            arguments.value0,
            arguments.value1,
            arguments.value2,
            arguments.value3,
            arguments.value4
        )
    }

    static func editPostArguments(
        id: Int,
        text: String,
        refs: [FileRef],
        patch: String,
        realm: String?
    ) throws -> CandidArguments {
        let arguments = try editPostModel(id: id, text: text, refs: refs, patch: patch, realm: realm)
        return try candidArguments(
            arguments.value0,
            arguments.value1,
            arguments.value2,
            arguments.value3,
            arguments.value4
        )
    }

    static func accountBalanceArguments(account: Data) throws -> CandidArguments {
        try candidArguments([LedgerAccountBalanceArgs(account: account)])
    }

    static func transferArguments(
        to account: Data,
        amountE8s: UInt64,
        feeE8s: UInt64,
        memo: UInt64
    ) throws -> CandidArguments {
        try candidArguments([transferModel(to: account, amountE8s: amountE8s, feeE8s: feeE8s, memo: memo)])
    }

    static func notifyCreateCanisterArguments(
        blockIndex: UInt64,
        controller: String,
        blackhole: String
    ) throws -> CandidArguments {
        try candidArguments([notifyCreateCanisterModel(
            blockIndex: blockIndex,
            controller: controller,
            blackhole: blackhole
        )])
    }

    static func notifyTopUpArguments(blockIndex: UInt64, canisterId: String) throws -> CandidArguments {
        try candidArguments([CMCNotifyTopUpArgs(
            blockIndex: blockIndex,
            canisterId: try CandidPrincipal(canisterId)
        )])
    }

    static func canisterStatusArguments(canisterId: String) throws -> CandidArguments {
        try candidArguments([ManagementCanisterStatusArgs(canisterId: try CandidPrincipal(canisterId))])
    }

    static func updateSettingsArguments(canisterId: String, controllers: [String]) throws -> CandidArguments {
        try candidArguments([try updateSettingsModel(canisterId: canisterId, controllers: controllers)])
    }

    static func updateInternalControllersArguments(_ controllers: [String]) throws -> CandidArguments {
        try candidArguments([try controllers.map(CandidPrincipal.init)])
    }

    static func installCodeArguments(
        canisterId: String,
        wasm: Data,
        userPrincipal: String,
        mode: ManagementInstallMode
    ) throws -> CandidArguments {
        try candidArguments([try installCodeModel(
            canisterId: canisterId,
            wasm: wasm,
            userPrincipal: userPrincipal,
            mode: mode
        )])
    }

    static func bucketHTTPRequestArguments(offset: UInt64, length: Int) throws -> CandidArguments {
        try candidArguments([bucketHTTPRequestModel(offset: offset, length: length)])
    }

    static func transferResult(_ reply: CandidReply) throws -> UInt64 {
        try transferResult(reply.decode(LedgerTransferResult.self))
    }

    static func canisterStatus(
        _ reply: CandidReply
    ) throws -> (
        status: String,
        controllers: [String],
        moduleHash: Data?,
        memorySize: UInt64,
        cycles: UInt64,
        idleCyclesBurnedPerDay: UInt64
    ) {
        try canisterStatus(reply.decode(ManagementCanisterStatus.self))
    }

    static func httpResponseBody(_ reply: CandidReply) throws -> Data {
        try httpResponseBody(reply.decode(BucketHttpResponse.self))
    }

    static func addPostModel(
        text: String,
        refs: [FileRef],
        parent: Int?,
        realm: String?,
        extensionBlob: Data?
    ) throws -> TaggrAddPostArguments {
        TaggrAddPostArguments(
            value0: text,
            value1: refs.map { TaggrAddPostArgument2Element(field0: $0.id, field1: $0.offset, field2: $0.length) },
            value2: try parent.map(checkedNat64),
            value3: realm,
            value4: extensionBlob
        )
    }

    static func editPostModel(
        id: Int,
        text: String,
        refs: [FileRef],
        patch: String,
        realm: String?
    ) throws -> TaggrEditPostArguments {
        TaggrEditPostArguments(
            value0: try checkedNat64(id),
            value1: text,
            value2: refs.map { TaggrEditPostArgument3Element(field0: $0.id, field1: $0.offset, field2: $0.length) },
            value3: patch,
            value4: realm
        )
    }

    static func transferModel(
        to account: Data,
        amountE8s: UInt64,
        feeE8s: UInt64,
        memo: UInt64
    ) -> LedgerTransferArgs {
        LedgerTransferArgs(
            to: account,
            fee: LedgerTokens(e8s: feeE8s),
            memo: memo,
            amount: LedgerTokens(e8s: amountE8s)
        )
    }

    static func notifyCreateCanisterModel(
        blockIndex: UInt64,
        controller: String,
        blackhole: String
    ) throws -> CMCNotifyCreateCanisterArgs {
        let controllers = try [controller, blackhole].map(CandidPrincipal.init)
        return CMCNotifyCreateCanisterArgs(
            controller: try CandidPrincipal(controller),
            blockIndex: blockIndex,
            subnetSelection: nil,
            settings: CMCCanisterSettings(
                freezingThreshold: nil,
                wasmMemoryThreshold: nil,
                environmentVariables: nil,
                controllers: controllers,
                reservedCyclesLimit: nil,
                logVisibility: nil,
                logMemoryLimit: nil,
                snapshotVisibility: nil,
                wasmMemoryLimit: nil,
                memoryAllocation: nil,
                computeAllocation: nil
            ),
            subnetType: nil
        )
    }

    static func updateSettingsModel(canisterId: String, controllers: [String]) throws -> ManagementUpdateSettingsArgs {
        ManagementUpdateSettingsArgs(
            canisterId: try CandidPrincipal(canisterId),
            settings: ManagementCanisterSettings(
                freezingThreshold: nil,
                wasmMemoryThreshold: nil,
                environmentVariables: nil,
                controllers: try controllers.map(CandidPrincipal.init),
                reservedCyclesLimit: nil,
                logVisibility: nil,
                snapshotVisibility: nil,
                wasmMemoryLimit: nil,
                memoryAllocation: nil,
                computeAllocation: nil
            ),
            senderCanisterVersion: nil
        )
    }

    static func installCodeModel(
        canisterId: String,
        wasm: Data,
        userPrincipal: String,
        mode: ManagementInstallMode
    ) throws -> ManagementInstallCodeArgs {
        let initArg = try candidArguments([[try CandidPrincipal(userPrincipal)]]).encode()
        return ManagementInstallCodeArgs(
            arg: initArg,
            wasmModule: wasm,
            mode: mode,
            canisterId: try CandidPrincipal(canisterId),
            senderCanisterVersion: nil
        )
    }

    static func installMode(_ value: String) throws -> ManagementInstallMode {
        switch value {
        case "install": .install
        case "reinstall": .reinstall
        case "upgrade": .upgrade(value: nil)
        default: throw TaggrAPIError.rejected("Unsupported install_code mode: \(value).")
        }
    }

    static func bucketHTTPRequestModel(offset: UInt64, length: Int) -> BucketHttpRequest {
        BucketHttpRequest(url: "/image?offset=\(offset)&len=\(length)", headers: [])
    }

    static func transferResult(_ result: LedgerTransferResult) throws -> UInt64 {
        switch result {
        case .ok(let block):
            return block
        case .err(let error):
            switch error {
            case .badFee(let value):
                throw TaggrAPIError.rejected("ICP transfer fee should be \(ICPAmount.format(value.expectedFee.e8s)).")
            case .insufficientFunds(let value):
                throw TaggrAPIError.rejected("ICP balance too low. Current balance: \(ICPAmount.format(value.balance.e8s)).")
            case .txTooOld:
                throw TaggrAPIError.rejected("ICP transfer request is too old.")
            case .txCreatedInFuture:
                throw TaggrAPIError.rejected("ICP transfer request was created in the future.")
            case .txDuplicate(let value):
                throw TaggrAPIError.rejected("ICP transfer was already submitted in block \(value.duplicateOf).")
            }
        }
    }

    static func notifyErrorMessage(_ error: CMCNotifyError) -> String {
        switch error {
        case .refunded(let value):
            return value.blockIndex.map { "CMC refunded the payment in block \($0): \(value.reason)" }
                ?? "CMC refunded the payment: \(value.reason)"
        case .invalidTransaction(let reason):
            return "CMC rejected the transaction: \(reason)"
        case .transactionTooOld(let block):
            return "CMC transaction is too old; oldest accepted block is \(block)."
        case .processing:
            return "CMC is already processing this payment."
        case .other(let value):
            return "CMC error \(value.errorCode): \(value.errorMessage)"
        }
    }

    static func checkedUInt64(_ value: CandidNat, field: String) throws -> UInt64 {
        guard let converted = UInt64(value.decimal) else {
            throw TaggrAPIError.invalidResponse("\(field) exceeds UInt64.")
        }
        return converted
    }

    static func canisterStatus(
        _ status: ManagementCanisterStatus
    ) throws -> (
        status: String,
        controllers: [String],
        moduleHash: Data?,
        memorySize: UInt64,
        cycles: UInt64,
        idleCyclesBurnedPerDay: UInt64
    ) {
        let statusText = switch status.status {
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "stopped"
        }
        return (
            statusText,
            status.settings.controllers.map(\.text),
            status.moduleHash,
            try checkedUInt64(status.memorySize, field: "canister_status.memory_size"),
            try checkedUInt64(status.cycles, field: "canister_status.cycles"),
            try checkedUInt64(status.idleCyclesBurnedPerDay, field: "canister_status.idle_cycles_burned_per_day")
        )
    }

    static func httpResponseBody(_ response: BucketHttpResponse) throws -> Data {
        guard (200..<300).contains(Int(response.statusCode)) else {
            throw TaggrAPIError.invalidResponse("bucket http_request returned status \(response.statusCode).")
        }
        return response.body
    }

    private static func checkedNat64(_ value: Int) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw TaggrAPIError.invalidResponse("negative value cannot be encoded as nat64")
        }
        return converted
    }

    private static func candidArguments<T: CandidConvertible>(_ values: [T]) throws -> CandidArguments {
        CandidArguments(try values.map(CandidTypedValue.init))
    }

    private static func candidArguments(
        _ value0: some CandidConvertible,
        _ value1: some CandidConvertible,
        _ value2: some CandidConvertible,
        _ value3: some CandidConvertible,
        _ value4: some CandidConvertible
    ) throws -> CandidArguments {
        CandidArguments([
            try CandidTypedValue(value0),
            try CandidTypedValue(value1),
            try CandidTypedValue(value2),
            try CandidTypedValue(value3),
            try CandidTypedValue(value4),
        ])
    }
}

enum TaggrCanisterAdapters {
    struct Taggr: Sendable {
        let client: ICClient

        private var canister: TaggrCanister {
            TaggrCanister(client: client, canisterId: client.configuration.canisterId)
        }

        func bucketWasm() async throws -> Data {
            try await canister.bucketWasm()
        }

        func addPost(
            text: String,
            refs: [TaggrCandid.FileRef],
            parent: Int?,
            realm: String?,
            extensionBlob: Data?,
            identity: ICAuthSession
        ) async throws -> UInt64 {
            let result = try await canister.addPost(
                TaggrCandidAdapter.addPostModel(
                    text: text,
                    refs: refs,
                    parent: parent,
                    realm: realm,
                    extensionBlob: extensionBlob
                ),
                identity: identity
            )
            switch result {
            case .ok(let id): return id
            case .err(let message): throw TaggrAPIError.rejected(message)
            }
        }

        func editPost(
            id: Int,
            text: String,
            refs: [TaggrCandid.FileRef],
            patch: String,
            realm: String?,
            identity: ICAuthSession
        ) async throws -> Data {
            let result = try await canister.editPost(
                TaggrCandidAdapter.editPostModel(id: id, text: text, refs: refs, patch: patch, realm: realm),
                identity: identity
            )
            if case .err(let message) = result {
                throw TaggrAPIError.rejected(message)
            }
            return try CandidArguments([CandidTypedValue(result)]).encode()
        }
    }

    struct Ledger: Sendable {
        static let canisterId = "ryjl3-tyaaa-aaaaa-aaaba-cai"
        let client: ICClient

        func accountBalance(account: Data) async throws -> UInt64 {
            try await LedgerCanister(client: client)
                .accountBalance(LedgerAccountBalanceArgs(account: account))
                .e8s
        }

        func transfer(
            to account: Data,
            amountE8s: UInt64,
            feeE8s: UInt64,
            memo: UInt64,
            identity: ICAuthSession
        ) async throws -> UInt64 {
            let result = try await LedgerCanister(client: client).transfer(
                TaggrCandidAdapter.transferModel(
                    to: account,
                    amountE8s: amountE8s,
                    feeE8s: feeE8s,
                    memo: memo
                ),
                identity: identity
            )
            return try TaggrCandidAdapter.transferResult(result)
        }
    }

    struct CMC: Sendable {
        static let canisterId = "rkp4c-7iaaa-aaaaa-aaaca-cai"
        let client: ICClient

        func notifyCreateCanister(
            blockIndex: UInt64,
            controller: String,
            blackhole: String,
            identity: ICAuthSession
        ) async throws -> String {
            let result = try await CMCCanister(client: client).notifyCreateCanister(
                TaggrCandidAdapter.notifyCreateCanisterModel(
                    blockIndex: blockIndex,
                    controller: controller,
                    blackhole: blackhole
                ),
                identity: identity
            )
            switch result {
            case .ok(let canisterId): return canisterId.text
            case .err(let error): throw TaggrAPIError.rejected(TaggrCandidAdapter.notifyErrorMessage(error))
            }
        }

        func notifyTopUp(blockIndex: UInt64, canisterId: String, identity: ICAuthSession) async throws -> UInt64 {
            let result = try await CMCCanister(client: client).notifyTopUp(
                CMCNotifyTopUpArgs(blockIndex: blockIndex, canisterId: try CandidPrincipal(canisterId)),
                identity: identity
            )
            switch result {
            case .ok(let cycles):
                return try TaggrCandidAdapter.checkedUInt64(cycles, field: "notify_top_up result")
            case .err(let error):
                throw TaggrAPIError.rejected(TaggrCandidAdapter.notifyErrorMessage(error))
            }
        }
    }

    struct Management: Sendable {
        static let canisterId = "aaaaa-aa"
        let client: ICClient

        func installCode(
            canisterId: String,
            wasm: Data,
            userPrincipal: String,
            mode: String,
            identity: ICAuthSession
        ) async throws {
            let mode = try TaggrCandidAdapter.installMode(mode)
            try await ManagementCanister(client: client).installCode(
                TaggrCandidAdapter.installCodeModel(
                    canisterId: canisterId,
                    wasm: wasm,
                    userPrincipal: userPrincipal,
                    mode: mode
                ),
                identity: identity,
                effectiveCanisterId: canisterId
            )
        }

        func canisterStatus(
            canisterId: String,
            identity: ICAuthSession
        ) async throws -> (
            status: String,
            controllers: [String],
            moduleHash: Data?,
            memorySize: UInt64,
            cycles: UInt64,
            idleCyclesBurnedPerDay: UInt64
        ) {
            let status = try await ManagementCanister(client: client).canisterStatus(
                ManagementCanisterStatusArgs(canisterId: try CandidPrincipal(canisterId)),
                identity: identity,
                effectiveCanisterId: canisterId
            )
            return try TaggrCandidAdapter.canisterStatus(status)
        }

        func updateSettings(canisterId: String, controllers: [String], identity: ICAuthSession) async throws {
            try await ManagementCanister(client: client).updateSettings(
                TaggrCandidAdapter.updateSettingsModel(canisterId: canisterId, controllers: controllers),
                identity: identity,
                effectiveCanisterId: canisterId
            )
        }
    }

    struct Bucket: Sendable {
        let client: ICClient
        let canisterId: String

        func updateInternalControllers(_ controllers: [String], identity: ICAuthSession) async throws {
            try await BucketCanister(client: client, canisterId: canisterId).updateInternalControllers(
                try controllers.map(CandidPrincipal.init),
                identity: identity
            )
        }

        func image(offset: UInt64, length: Int) async throws -> Data {
            let response = try await BucketCanister(client: client, canisterId: canisterId).httpRequest(
                TaggrCandidAdapter.bucketHTTPRequestModel(offset: offset, length: length)
            )
            return try TaggrCandidAdapter.httpResponseBody(response)
        }
    }
}
