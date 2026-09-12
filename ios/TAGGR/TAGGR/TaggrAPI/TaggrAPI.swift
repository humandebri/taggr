import Foundation
@preconcurrency import ICNativeClient

enum TaggrAPIError: Error, LocalizedError {
    static let signInRequiredMessage = "Sign in to use this action."

    case invalidCanisterId
    case invalidIdentity(String)
    case emptyResponse
    case invalidResponse(String)
    case backendUnavailable(String)
    case missingIdentity
    case rejected(String)
    case pollTimeout

    var errorDescription: String? {
        switch self {
        case .invalidCanisterId:
            return "Invalid TAGGR canister id."
        case .invalidIdentity(let message):
            return message
        case .emptyResponse:
            return "The TAGGR backend returned no response."
        case .invalidResponse(let context):
            return "The TAGGR backend response could not be decoded: \(context)."
        case .backendUnavailable(let context):
            return "TAGGR backend is unavailable. Check your connection and try again. (\(context))"
        case .missingIdentity:
            return Self.signInRequiredMessage
        case .rejected(let message):
            return message
        case .pollTimeout:
            return "TAGGR update polling timed out."
        }
    }
}

struct TaggrICPInvoice: Decodable, Equatable, Sendable {
    let e8s: UInt64
    let paidE8s: UInt64
    let paid: Bool
    let account: [UInt8]

    enum CodingKeys: String, CodingKey {
        case e8s
        case paidE8s = "paid_e8s"
        case paid
        case account
    }

    var accountHex: String {
        Data(account).icHexString
    }

    var amountICP: String {
        let whole = e8s / 100_000_000
        let fraction = e8s % 100_000_000
        guard fraction > 0 else {
            return "\(whole)"
        }
        var fractionText = String(format: "%08llu", fraction)
        while fractionText.last == "0" {
            fractionText.removeLast()
        }
        return "\(whole).\(fractionText)"
    }
}

private struct TaggrUpdateResult<T: Decodable>: Decodable {
    let ok: T?
    let err: String?

    enum CodingKeys: String, CodingKey {
        case ok = "Ok"
        case err = "Err"
    }
}

actor TaggrAPI {
    static var canisterId: String { TaggrRuntimeConfig.current.canisterId }
    static var domain: String { TaggrRuntimeConfig.current.domain }
    static let icpLedgerCanisterId = TaggrCanisterAdapters.Ledger.canisterId
    static let cmcCanisterId = TaggrCanisterAdapters.CMC.canisterId
    static let managementCanisterId = TaggrCanisterAdapters.Management.canisterId
    static let blackholeCanisterId = "e3mmv-5qaaa-aaaah-aadma-cai"
    static let memoCreateCanister: UInt64 = 0x41455243
    static let memoTopUpCanister: UInt64 = 0x50555054
    private nonisolated let config: TaggrRuntimeConfig
    private let icClient: ICClient

    nonisolated var domain: String { config.domain }

    init(
        session: URLSession = .shared,
        config: TaggrRuntimeConfig = .current,
        trustRoot: ICTrustRoot = .mainnet
    ) {
        self.config = config
        self.icClient = ICClient(configuration: config.icClientConfiguration(trustRoot: trustRoot), session: session)
    }

    nonisolated func apiURL(for requestType: String) -> URL {
        do {
            return try config.icClientConfiguration.apiURL(for: requestType)
        } catch {
            preconditionFailure("Invalid IC API request path: \(error)")
        }
    }

    nonisolated func apiURL(for requestType: String, canisterId: String) -> URL {
        do {
            return try config.icClientConfiguration.apiURL(for: requestType, canisterId: canisterId)
        } catch {
            preconditionFailure("Invalid IC API request path: \(error)")
        }
    }

    func query<T: Decodable & Sendable>(_ method: String, as type: T.Type) async throws -> T? {
        try await query(method, args: [], as: type)
    }

    func query<T: Decodable & Sendable>(_ method: String, args: sending [Any?], as type: T.Type) async throws -> T? {
        let arg = try TaggrCandid.jsonArguments(args)
        let response = try await queryRaw(method, arg: arg, identity: nil)
        guard !response.isEmpty else { return nil }
        return try decode(T.self, from: response, method: method)
    }

    func signedQuery<T: Decodable & Sendable>(_ method: String, args: sending [Any?], identity: ICAuthSession, as type: T.Type) async throws -> T? {
        let arg = try TaggrCandid.jsonArguments(args)
        let response = try await queryRaw(method, arg: arg, identity: identity)
        guard !response.isEmpty else { return nil }
        return try decode(T.self, from: response, method: method)
    }

    func closeMediaStorage(_ bucket: String, identity: ICAuthSession) async throws {
        let status = try await storageCanisterStatus(bucket, identity: identity)
        let moduleHash = status.moduleHash?.icHexString.lowercased()
        // Rebuilt from bucket source at 4ee528a1 with the repository release/shrink/Oz pipeline.
        let knownLegacyHash = "418202879263a81a9479620628be4e0543367c178addb92d5fd5873ba23bde10"
        if moduleHash == knownLegacyHash {
            guard status.controllers.contains(identity.principal) else {
                throw TaggrAPIError.rejected("Storage upgrade requires its controller. Deletion remains in progress.")
            }
            try await installBucketCode(canisterId: bucket, wasm: try await bucketWasm(), userPrincipal: identity.principal, mode: "upgrade", identity: identity)
        }
        // Unknown modules are never overwritten. A supported close operation can still be retried.
        do {
            _ = try await updateRaw("close_media", arg: TaggrCandidAdapter.emptyArguments().encode(), canisterId: bucket, identity: identity)
        } catch {
            throw TaggrAPIError.rejected("Image storage could not be closed. Unknown modules are not automatically upgraded. Storage: \(bucket). \(error.localizedDescription)")
        }
    }

    func updateJSON(_ method: String, args: sending [Any?] = [], identity: ICAuthSession?) async throws -> Data {
        let identity = try Self.requireIdentity(identity)
        let arg = try TaggrCandid.jsonArguments(args)
        let response = try await updateRaw(method, arg: arg, identity: identity)
        try Self.throwIfRejectedJSON(response)
        return response
    }

    func setRealmMembership(name: String, joined: Bool, identity: ICAuthSession?) async throws {
        let response = try await updateJSON("toggle_realm_membership", args: [name], identity: identity)
        let actualState: Bool
        do {
            actualState = try JSONDecoder().decode(Bool.self, from: response)
        } catch {
            throw TaggrAPIError.invalidResponse("toggle_realm_membership: \(error.localizedDescription)")
        }
        guard actualState == joined else {
            throw TaggrAPIError.rejected("Realm membership could not be updated.")
        }
    }

    func editRealm(name: String, payload: sending [String: Any], identity: ICAuthSession?) async throws {
        _ = try await updateJSON("edit_realm", args: [name, payload], identity: identity)
    }

    func createUser(name: String, invite: String, identity: ICAuthSession?) async throws -> Data {
        try await updateJSON("create_user", args: [name, invite], identity: identity)
    }

    func mintCreditsWithICP(kiloCredits: Int = 0, identity: ICAuthSession?) async throws -> TaggrICPInvoice {
        let response = try await updateJSON("mint_credits_with_icp", args: [kiloCredits], identity: identity)
        let result: TaggrUpdateResult<TaggrICPInvoice>
        do {
            result = try JSONDecoder().decode(TaggrUpdateResult<TaggrICPInvoice>.self, from: response)
        } catch {
            throw TaggrAPIError.invalidResponse("mint_credits_with_icp: \(error.localizedDescription)")
        }
        if let message = result.err {
            throw TaggrAPIError.rejected(message)
        }
        guard let invoice = result.ok else {
            throw TaggrAPIError.invalidResponse("mint_credits_with_icp: missing Ok invoice")
        }
        return invoice
    }

    func icpAccountBalance(ownerPrincipal: String) async throws -> UInt64 {
        let account = try ICPAccountIdentifier.defaultAccount(for: ownerPrincipal)
        return try await mapICClientErrors {
            try await TaggrCanisterAdapters.Ledger(client: icClient).accountBalance(account: account)
        }
    }

    func tagsCost(_ tags: [String]) async throws -> Int {
        try await query("tags_cost", args: [tags], as: Int.self) ?? 0
    }

    func transferICP(to recipient: String, e8s: UInt64, memo: UInt64 = 0, identity: ICAuthSession?) async throws -> UInt64 {
        let identity = try Self.requireIdentity(identity)
        let account = try ICPAccountIdentifier.parse(recipient)
        return try await transferICP(toAccount: account, e8s: e8s, memo: memo, identity: identity)
    }

    func transferICP(toAccount account: Data, e8s: UInt64, memo: UInt64 = 0, identity: ICAuthSession?) async throws -> UInt64 {
        let identity = try Self.requireIdentity(identity)
        return try await mapICClientErrors {
            try await TaggrCanisterAdapters.Ledger(client: icClient).transfer(
                to: account, amountE8s: e8s, feeE8s: ICPAmount.feeE8s, memo: memo, identity: identity
            )
        }
    }

    func bucketWasm() async throws -> Data {
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.Taggr(client: icClient).bucketWasm()
        }
    }

    func bucketWasmHash() async throws -> String {
        try await query("bucket_wasm_hash", as: String.self) ?? ""
    }

    func setBucket(_ bucketId: String, identity: ICAuthSession?) async throws {
        _ = try await updateJSON("set_bucket", args: [bucketId], identity: identity)
    }

    func notifyCreateCanister(blockIndex: UInt64, controller: String, identity: ICAuthSession) async throws -> String {
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.CMC(client: icClient).notifyCreateCanister(
                blockIndex: blockIndex, controller: controller, blackhole: Self.blackholeCanisterId, identity: identity
            )
        }
    }

    func notifyTopUp(blockIndex: UInt64, canisterId: String, identity: ICAuthSession) async throws -> UInt64 {
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.CMC(client: icClient).notifyTopUp(
                blockIndex: blockIndex, canisterId: canisterId, identity: identity
            )
        }
    }

    func installBucketCode(
        canisterId: String,
        wasm: Data,
        userPrincipal: String,
        mode: String,
        identity: ICAuthSession
    ) async throws {
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.Management(client: icClient).installCode(
                canisterId: canisterId, wasm: wasm, userPrincipal: userPrincipal, mode: mode, identity: identity
            )
        }
    }

    func storageCanisterStatus(_ canisterId: String, identity: ICAuthSession) async throws -> TaggrStorageCanisterStatus {
        let decoded = try await mapICClientErrors {
            try await TaggrCanisterAdapters.Management(client: icClient).canisterStatus(
                canisterId: canisterId, identity: identity
            )
        }
        return TaggrStorageCanisterStatus(
            status: decoded.status,
            controllers: decoded.controllers,
            moduleHash: decoded.moduleHash,
            memorySize: decoded.memorySize,
            cycles: decoded.cycles,
            idleCyclesBurnedPerDay: decoded.idleCyclesBurnedPerDay
        )
    }

    func updateStorageControllers(canisterId: String, controllers: [String], identity: ICAuthSession) async throws {
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.Management(client: icClient).updateSettings(
                canisterId: canisterId, controllers: controllers, identity: identity
            )
        }
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.Bucket(client: icClient, canisterId: canisterId)
                .updateInternalControllers(controllers, identity: identity)
        }
    }

    func addPost(
        text: String,
        refs: [TaggrCandid.FileRef] = [],
        parent: Int?,
        realm: String?,
        extensionBlob: Data? = nil,
        identity: ICAuthSession?
    ) async throws -> UInt64 {
        let identity = try Self.requireIdentity(identity)
        return try await mapICClientErrors {
            try await TaggrCanisterAdapters.Taggr(client: icClient).addPost(
                text: text, refs: refs, parent: parent, realm: realm, extensionBlob: extensionBlob, identity: identity
            )
        }
    }

    func editPost(id: Int, text: String, refs: [TaggrCandid.FileRef] = [], patch: String, realm: String?, identity: ICAuthSession?) async throws -> Data {
        let identity = try Self.requireIdentity(identity)
        return try await mapICClientErrors {
            try await TaggrCanisterAdapters.Taggr(client: icClient).editPost(
                id: id, text: text, refs: refs, patch: patch, realm: realm, identity: identity
            )
        }
    }

    func toggleBookmark(postId: Int, identity: ICAuthSession?) async throws -> Data {
        try await updateJSON("toggle_bookmark", args: [postId], identity: identity)
    }

    func toggleFollowingPost(postId: Int, identity: ICAuthSession?) async throws -> Data {
        try await updateJSON("toggle_following_post", args: [postId], identity: identity)
    }

    func bucketWrite(bucketId: String, blob: Data, identity: ICAuthSession) async throws -> UInt64 {
        try validateIdentity(identity, requestCanisterId: bucketId)
        let response = try await updateRaw("write", arg: blob, canisterId: bucketId, identity: identity)
        guard response.count >= 8 else {
            throw TaggrAPIError.invalidResponse("bucket.write returned a short reply.")
        }
        return response.prefix(8).reduce(UInt64(0)) { value, byte in
            (value << 8) | UInt64(byte)
        }
    }

    func bucketImage(bucketId: String, offset: UInt64, length: Int) async throws -> Data {
        try await mapICClientErrors {
            try await TaggrCanisterAdapters.Bucket(client: icClient, canisterId: bucketId)
                .image(offset: offset, length: length)
        }
    }

    func repost(postId: Int, text: String, realm: String?, identity: ICAuthSession?) async throws -> UInt64 {
        try await addPost(
            text: text,
            refs: [],
            parent: nil,
            realm: realm,
            extensionBlob: Data(#"{"Repost":\#(postId)}"#.utf8),
            identity: identity
        )
    }

    private func queryRaw(_ method: String, arg: Data, identity: ICAuthSession?) async throws -> Data {
        try await queryRaw(method, arg: arg, canisterId: config.canisterId, identity: identity)
    }

    private func queryRaw(_ method: String, arg: Data, canisterId: String, identity: ICAuthSession?) async throws -> Data {
        try await mapICClientErrors {
            try await icClient.queryRaw(method: method, arg: arg, canisterId: canisterId, identity: identity)
        }
    }

    private func updateRaw(_ method: String, arg: Data, identity: ICAuthSession) async throws -> Data {
        try await updateRaw(method, arg: arg, canisterId: config.canisterId, identity: identity)
    }

    private func updateRaw(_ method: String, arg: Data, canisterId: String, identity: ICAuthSession) async throws -> Data {
        try await updateRaw(method, arg: arg, canisterId: canisterId, effectiveCanisterId: canisterId, identity: identity)
    }

    private func updateRaw(
        _ method: String,
        arg: Data,
        canisterId: String,
        effectiveCanisterId: String,
        identity: ICAuthSession
    ) async throws -> Data {
        try await mapICClientErrors {
            try await icClient.callRaw(
                method: method,
                arg: arg,
                canisterId: canisterId,
                effectiveCanisterId: effectiveCanisterId,
                identity: identity
            )
        }
    }

    func validateIdentity(_ identity: ICAuthSession, requestCanisterId: String) throws {
        do {
            try icClient.validateIdentity(identity, requestCanisterId: requestCanisterId)
        } catch {
            throw Self.taggrError(from: error)
        }
    }

    private func mapICClientErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw Self.taggrError(from: error)
        }
    }

    private static func taggrError(from error: Error) -> Error {
        guard let error = error as? ICClientError else {
            return error
        }
        switch error {
        case .invalidCanisterId:
            return TaggrAPIError.invalidCanisterId
        case .invalidIdentity(let message):
            return TaggrAPIError.invalidIdentity(message)
        case .emptyResponse:
            return TaggrAPIError.emptyResponse
        case .invalidResponse(let context):
            return TaggrAPIError.invalidResponse(context)
        case .backendUnavailable(let context):
            return TaggrAPIError.backendUnavailable(context)
        case .rejected(let reject):
            return TaggrAPIError.rejected(reject.message)
        case .pollTimeout:
            return TaggrAPIError.pollTimeout
        case .invalidPayload:
            return TaggrAPIError.invalidIdentity("Internet Identity session is not valid for this canister.")
        default:
            return error
        }
    }

    private static func throwIfRejectedJSON(_ data: Data) throws {
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = value as? [String: Any],
              let error = object["Err"] else {
            return
        }
        if let message = error as? String {
            throw TaggrAPIError.rejected(message)
        }
        if let data = try? JSONSerialization.data(withJSONObject: error, options: [.fragmentsAllowed]),
           let message = String(data: data, encoding: .utf8) {
            throw TaggrAPIError.rejected(message)
        }
        throw TaggrAPIError.rejected("TAGGR update rejected.")
    }

    private static func requireIdentity(_ identity: ICAuthSession?) throws -> ICAuthSession {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        return identity
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, from response: Data, method: String) throws -> T {
        do {
            return try JSONDecoder.taggr.decode(T.self, from: response)
        } catch {
            throw TaggrAPIError.invalidResponse("\(method): \(error.localizedDescription)")
        }
    }
}

extension JSONDecoder {
    static var taggr: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
