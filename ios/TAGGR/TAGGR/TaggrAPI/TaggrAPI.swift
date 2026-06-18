import Foundation
import CryptoKit

enum TaggrAPIError: Error, LocalizedError {
    case invalidCanisterId
    case emptyResponse
    case invalidResponse(String)
    case missingIdentity
    case rejected(String)
    case pollTimeout

    var errorDescription: String? {
        switch self {
        case .invalidCanisterId:
            return "Invalid TAGGR canister id."
        case .emptyResponse:
            return "The TAGGR backend returned no response."
        case .invalidResponse(let context):
            return "The TAGGR backend response could not be decoded: \(context)."
        case .missingIdentity:
            return "Sign in with Internet Identity before sending updates."
        case .rejected(let message):
            return message
        case .pollTimeout:
            return "TAGGR update polling timed out."
        }
    }
}

final class TaggrAPI {
    static var canisterId: String { TaggrRuntimeConfig.current.canisterId }
    static var domain: String { TaggrRuntimeConfig.current.domain }
    private let session: URLSession
    private let config: TaggrRuntimeConfig

    var domain: String { config.domain }

    init(session: URLSession = .shared, config: TaggrRuntimeConfig = .current) {
        self.session = session
        self.config = config
    }

    func apiURL(for requestType: String) -> URL {
        config.apiURL(for: requestType)
    }

    func query<T: Decodable>(_ method: String, _ args: Any?..., as type: T.Type) async throws -> T? {
        try await query(method, args: args, as: type)
    }

    func query<T: Decodable>(_ method: String, args: [Any?], as type: T.Type) async throws -> T? {
        let arg = try TaggrCandid.jsonArguments(args)
        let response = try await queryRaw(method, arg: arg, identity: nil)
        guard !response.isEmpty else { return nil }
        return try decode(T.self, from: response, method: method)
    }

    func signedQuery<T: Decodable>(_ method: String, args: [Any?], identity: TaggrAuthSession, as type: T.Type) async throws -> T? {
        let arg = try TaggrCandid.jsonArguments(args)
        let response = try await queryRaw(method, arg: arg, identity: identity)
        guard !response.isEmpty else { return nil }
        return try decode(T.self, from: response, method: method)
    }

    func updateJSON(_ method: String, _ args: Any?..., identity: TaggrAuthSession?) async throws -> Data {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        let arg = try TaggrCandid.jsonArguments(args)
        return try await updateRaw(method, arg: arg, identity: identity)
    }

    func addPost(text: String, parent: Int?, realm: String?, identity: TaggrAuthSession?) async throws -> Data {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        let arg = TaggrCandid.encodeAddPost(text: text, parent: parent, realm: realm)
        return try await updateRaw("add_post", arg: arg, identity: identity)
    }

    func editPost(id: Int, text: String, patch: String, realm: String?, identity: TaggrAuthSession?) async throws -> Data {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        let arg = TaggrCandid.encodeEditPost(id: id, text: text, patch: patch, realm: realm)
        return try await updateRaw("edit_post", arg: arg, identity: identity)
    }

    func addPostData(text: String, realm: String?, identity: TaggrAuthSession?) async throws -> Data {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        return try await updateRaw("add_post_data", arg: TaggrCandid.encodePostData(text: text, realm: realm), identity: identity)
    }

    func addPostBlob(id: String, blob: Data, identity: TaggrAuthSession?) async throws -> Data {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        return try await updateRaw("add_post_blob", arg: TaggrCandid.encodePostBlob(id: id, blob: blob), identity: identity)
    }

    func commitPost(identity: TaggrAuthSession?) async throws -> Data {
        guard let identity else {
            throw TaggrAPIError.missingIdentity
        }
        return try await updateRaw("commit_post", arg: TaggrCandid.encodeEmpty(), identity: identity)
    }

    private func queryRaw(_ method: String, arg: Data, identity: TaggrAuthSession?) async throws -> Data {
        guard let canister = PrincipalBlob.parse(config.canisterId) else {
            throw TaggrAPIError.invalidCanisterId
        }
        let envelope: Data
        if let identity {
            let content = requestContent(type: "query", canister: canister, method: method, arg: arg, identity: identity)
            envelope = try Self.signedEnvelope(content: content, identity: identity)
        } else {
            envelope = TaggrCBOR.queryEnvelope(canisterId: canister, method: method, arg: arg, ingressExpiry: Self.ingressExpiry())
        }
        let url = apiURL(for: "query")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.httpBody = envelope
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw TaggrAPIError.invalidResponse(Self.httpFailureContext("query \(method)", data: data, response: response))
        }
        guard let arg = TaggrCBOR.decodeReplyArg(data) else {
            throw TaggrAPIError.emptyResponse
        }
        return arg
    }

    private func updateRaw(_ method: String, arg: Data, identity: TaggrAuthSession) async throws -> Data {
        guard let canister = PrincipalBlob.parse(config.canisterId) else {
            throw TaggrAPIError.invalidCanisterId
        }
        let content = requestContent(type: "call", canister: canister, method: method, arg: arg, identity: identity)
        let requestId = TaggrRequestID.hash(of: content)
        let envelope = try Self.signedEnvelope(content: content, identity: identity)
        let url = apiURL(for: "call")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.httpBody = envelope
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 202 else {
            throw TaggrAPIError.invalidResponse(Self.httpFailureContext("update \(method)", data: data, response: response))
        }
        if let arg = TaggrCBOR.decodeReplyArg(data) {
            return arg
        }
        return try await poll(requestId: requestId, identity: identity)
    }

    private func poll(requestId: Data, identity: TaggrAuthSession) async throws -> Data {
        let url = apiURL(for: "read_state")
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let content: TaggrCBOR.Value = .map([
                (.text("request_type"), .text("read_state")),
                (.text("paths"), .array([.array([.bytes(Data("request_status".utf8)), .bytes(requestId)])])),
                (.text("sender"), .bytes(PrincipalBlob.selfAuthenticatingPublicKey(identity.delegation.publicKey))),
                (.text("ingress_expiry"), .unsigned(Self.ingressExpiry())),
            ])
            let envelope = try Self.signedEnvelope(content: content, identity: identity)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
            request.httpBody = envelope
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                throw TaggrAPIError.invalidResponse(Self.httpFailureContext("read_state", data: data, response: response))
            }
            if let result = try TaggrCBOR.certificateStatusArg(from: data, requestId: requestId) {
                if let reply = try result.get() {
                    return reply
                }
            }
        }
        throw TaggrAPIError.pollTimeout
    }

    private func requestContent(type: String, canister: Data, method: String, arg: Data, identity: TaggrAuthSession) -> TaggrCBOR.Value {
        .map([
            (.text("request_type"), .text(type)),
            (.text("canister_id"), .bytes(canister)),
            (.text("method_name"), .text(method)),
            (.text("arg"), .bytes(arg)),
            (.text("sender"), .bytes(PrincipalBlob.selfAuthenticatingPublicKey(identity.delegation.publicKey))),
            (.text("ingress_expiry"), .unsigned(Self.ingressExpiry())),
        ])
    }

    static func signedEnvelope(content: TaggrCBOR.Value, identity: TaggrAuthSession) throws -> Data {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.sessionPrivateKey)
        let requestId = TaggrRequestID.hash(of: content)
        let challenge = Data([0x0a]) + Data("ic-request".utf8) + requestId
        let signature = try privateKey.signature(for: challenge)
        return TaggrCBOR.signedEnvelope(
            content: content,
            publicKey: identity.sessionPublicKey,
            signature: signature,
            delegation: identity.delegation
        )
    }

    private static func ingressExpiry() -> UInt64 {
        UInt64((Date().timeIntervalSince1970 + 300) * 1_000_000_000)
    }

    private static func httpFailureContext(_ operation: String, data: Data, response: URLResponse) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data.prefix(1_000), encoding: .utf8) ?? data.prefix(128).map { String(format: "%02x", $0) }.joined()
        return "\(operation) HTTP \(status): \(body)"
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: Data, method: String) throws -> T {
        do {
            return try JSONDecoder.taggr.decode(T.self, from: response)
        } catch {
            throw TaggrAPIError.invalidResponse("\(method): \(error.localizedDescription)")
        }
    }
}

private extension JSONDecoder {
    static var taggr: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
