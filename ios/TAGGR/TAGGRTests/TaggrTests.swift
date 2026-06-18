import XCTest
import CryptoKit
import UIKit
@testable import TAGGR

final class TaggrTests: XCTestCase {
    func testRoutesUniversalLinks() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/post/12")!), .post(12))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice")!), .profile("alice"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/realm/DEV")!), .realm("DEV"))
    }

    func testRoutesCustomScheme() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "taggr://post/99")!), .post(99))
    }

    func testReadOnlyCryptoRoutes() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transaction/12")!), .readOnlyNotice)
    }

    func testRejectsExternalHosts() {
        XCTAssertNil(TaggrNavigation.route(from: URL(string: "https://example.com/post/1")!))
    }

    func testRuntimeConfigUsesProductionDefaults() {
        let config = TaggrRuntimeConfig.from(info: [:])
        XCTAssertEqual(config.canisterId, TaggrRuntimeConfig.productionCanisterId)
        XCTAssertEqual(config.apiBaseURL, TaggrRuntimeConfig.productionAPIBaseURL)
        XCTAssertEqual(config.domain, TaggrRuntimeConfig.productionDomain)
        XCTAssertEqual(config.identityURL, TaggrRuntimeConfig.productionIdentityURL)
        XCTAssertEqual(config.authOrigin, TaggrRuntimeConfig.productionAuthOrigin)
    }

    func testRuntimeConfigReadsInfoOverrides() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "http://127.0.0.1:8000",
            "TAGGR_DOMAIN": "localhost",
            "TAGGR_II_URL": "http://id.ai.localhost:8000/#authorize",
            "TAGGR_AUTH_ORIGIN": "http://bkyz2-fmaaa-aaaaa-qaaaq-cai.localhost:8000",
            "TAGGR_AUTOMATE_LOCAL_II": "1",
        ])
        XCTAssertEqual(config.canisterId, "bkyz2-fmaaa-aaaaa-qaaaq-cai")
        XCTAssertEqual(config.apiURL(for: "query").absoluteString, "http://127.0.0.1:8000/api/v2/canister/bkyz2-fmaaa-aaaaa-qaaaq-cai/query")
        XCTAssertEqual(config.domain, "localhost")
        XCTAssertEqual(config.identityURL.absoluteString, "http://id.ai.localhost:8000/#authorize")
        XCTAssertEqual(config.authOrigin, "http://bkyz2-fmaaa-aaaaa-qaaaq-cai.localhost:8000")
        XCTAssertTrue(config.automateLocalIdentity)
    }

    func testRuntimeConfigIgnoresBuildSettingPlaceholders() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "$(TAGGR_CANISTER_ID)",
            "TAGGR_API_BASE_URL": "$(TAGGR_API_BASE_URL)",
            "TAGGR_DOMAIN": "$(TAGGR_DOMAIN)",
            "TAGGR_II_URL": "$(TAGGR_II_URL)",
            "TAGGR_AUTH_ORIGIN": "$(TAGGR_AUTH_ORIGIN)",
            "TAGGR_AUTOMATE_LOCAL_II": "$(TAGGR_AUTOMATE_LOCAL_II)",
        ])
        XCTAssertEqual(config, TaggrRuntimeConfig.from(info: [:]))
    }

    func testAPIURLUsesRuntimeConfig() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "http://127.0.0.1:8000/",
        ])
        let api = TaggrAPI(config: config)
        XCTAssertEqual(api.apiURL(for: "read_state").absoluteString, "http://127.0.0.1:8000/api/v2/canister/bkyz2-fmaaa-aaaaa-qaaaq-cai/read_state")
    }

    func testIdentityBridgeScriptUsesRuntimeAuthOrigin() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_AUTH_ORIGIN": "http://bkyz2-fmaaa-aaaaa-qaaaq-cai.localhost:8000",
        ])
        let coordinator = IdentityWebView.Coordinator(onComplete: { _ in })
        XCTAssertTrue(coordinator.bridgeScript(config: config).contains(#"origin: "http://bkyz2-fmaaa-aaaaa-qaaaq-cai.localhost:8000""#))
    }

    func testIdentityBridgeScriptCanAutomateLocalIdentity() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_AUTOMATE_LOCAL_II": "true",
        ])
        let coordinator = IdentityWebView.Coordinator(onComplete: { _ in })
        let script = coordinator.bridgeScript(config: config)
        XCTAssertTrue(script.contains("const TAGGR_AUTOMATE_LOCAL_II = true;"))
        XCTAssertTrue(script.contains("clickViewport(0.5, 0.69)"))
        guard let signUpRange = script.range(of: #"bodyText.includes("want a new identity?")"#),
              let signInRange = script.range(of: #"bodyText.includes("sign in with passkey")"#) else {
            return XCTFail("Local identity automation branches are missing.")
        }
        XCTAssertLessThan(signUpRange.lowerBound, signInRange.lowerBound)
    }

    func testIdentityBridgeScriptDeliversAuthorizeRequestToOpener() {
        let coordinator = IdentityWebView.Coordinator(onComplete: { _ in })
        let script = coordinator.bridgeScript()
        XCTAssertTrue(script.contains("source: openerWindow"))
        XCTAssertTrue(script.contains("window.onmessage.call(window, event)"))
        XCTAssertTrue(script.contains("scheduleDeliver()"))
    }

    func testJsonArgumentEncoding() throws {
        let data = try TaggrCandid.jsonArguments(["domain", 0, true])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"domain\",0,true]")
    }

    func testJsonArgumentFragments() throws {
        let empty = try TaggrCandid.jsonArguments([])
        let single = try TaggrCandid.jsonArguments([12])
        let singleNil = try TaggrCandid.jsonArguments([nil])
        let nullPreserved = try TaggrCandid.jsonArguments(["domain", nil, 1])
        XCTAssertEqual(String(data: empty, encoding: .utf8), "null")
        XCTAssertEqual(String(data: single, encoding: .utf8), "12")
        XCTAssertEqual(String(data: singleNil, encoding: .utf8), "null")
        XCTAssertEqual(String(data: nullPreserved, encoding: .utf8), "[\"domain\",null,1]")
    }

    func testCandidGoldenFixtures() {
        XCTAssertEqual(TaggrCandid.encodeEmpty().hexString, "4449444c0000")
        XCTAssertEqual(
            TaggrCandid.encodeAddPost(text: "hello", parent: 1, realm: "DEV").hexString,
            "4449444c066d7b6c02007101006d016e786e716e000571020304050568656c6c6f00010100000000000000010344455600"
        )
        XCTAssertEqual(
            TaggrCandid.encodeEditPost(id: 7, text: "hello", patch: "patch", realm: "DEV").hexString,
            "4449444c046d7b6c02007101006d016e71057802710307000000000000000568656c6c6f000570617463680103444556"
        )
        XCTAssertEqual(
            TaggrCandid.encodePostData(text: "hello", realm: "DEV").hexString,
            "4449444c036e716d7b6e01037100020568656c6c6f010344455600"
        )
        XCTAssertEqual(
            TaggrCandid.encodePostBlob(id: "blob-id", blob: Data([1, 2, 3])).hexString,
            "4449444c016d7b02710007626c6f622d696403010203"
        )
    }

    func testRequestIdGoldenVector() {
        let content: TaggrCBOR.Value = .map([
            (.text("request_type"), .text("query")),
            (.text("canister_id"), .bytes(Data([1, 2, 3]))),
            (.text("method_name"), .text("stats")),
            (.text("arg"), .bytes(Data(hex: "4449444c0000")!)),
            (.text("sender"), .bytes(Data([4]))),
        ])
        XCTAssertEqual(TaggrRequestID.hash(of: content).hexString, "162bcd6936bd4c6f2aba446cb7f6fe1960ec7e402c8056550040e35f0fe3afc4")
    }

    func testCBORSignedEnvelopeShape() {
        let delegation = TaggrDelegationChain(
            publicKey: Data([1, 2, 3]),
            delegations: [
                .init(
                    delegation: .init(publicKey: Data([4, 5, 6]), expiration: UInt64.max, targets: nil),
                    signature: Data([7, 8])
                ),
            ]
        )
        let envelope = TaggrCBOR.signedEnvelope(
            content: .map([(.text("request_type"), .text("query"))]),
            publicKey: delegation.publicKey,
            signature: Data([9, 10]),
            delegation: delegation
        )
        guard case .map(let values)? = TaggrCBOR.decode(envelope) else {
            return XCTFail("Envelope is not a CBOR map.")
        }
        XCTAssertTrue(values.contains { $0.0 == .text("content") })
        XCTAssertTrue(values.contains { $0.0 == .text("sender_pubkey") })
        XCTAssertTrue(values.contains { $0.0 == .text("sender_sig") })
        XCTAssertTrue(values.contains { $0.0 == .text("sender_delegation") })
    }

    func testSignedEnvelopeUsesSessionPublicKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let session = makeAuthSession(privateKey: privateKey)
        let content: TaggrCBOR.Value = .map([(.text("request_type"), .text("query"))])
        let envelope = try TaggrAPI.signedEnvelope(content: content, identity: session)
        guard case .map(let values)? = TaggrCBOR.decode(envelope) else {
            return XCTFail("Envelope is not a CBOR map.")
        }
        XCTAssertEqual(value(named: "sender_pubkey", in: values), .bytes(session.sessionPublicKey))
        XCTAssertNotEqual(value(named: "sender_pubkey", in: values), .bytes(session.delegation.publicKey))
    }

    func testSignedEnvelopeSignatureVerifiesWithSessionKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let session = makeAuthSession(privateKey: privateKey)
        let content: TaggrCBOR.Value = .map([(.text("request_type"), .text("query"))])
        let envelope = try TaggrAPI.signedEnvelope(content: content, identity: session)
        guard case .map(let values)? = TaggrCBOR.decode(envelope),
              case .bytes(let signature)? = value(named: "sender_sig", in: values),
              case .bytes(let senderPublicKey)? = value(named: "sender_pubkey", in: values) else {
            return XCTFail("Envelope signature is missing.")
        }
        let requestId = TaggrRequestID.hash(of: content)
        let challenge = Data([0x0a]) + Data("ic-request".utf8) + requestId
        let rawPublicKey = Data(senderPublicKey.dropFirst(TaggrIdentityBridge.ed25519DERPrefix.count))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: challenge))
    }

    func testCBORReplyArgReadsTaggedBoundaryResponse() {
        let response = Data(hex: "d9d9f7bf66737461747573677265706c696564657265706c79a16361726743010203ff")!
        XCTAssertEqual(TaggrCBOR.decodeReplyArg(response), Data([1, 2, 3]))
    }

    func testCBORRejectedResponseReadsMessage() {
        let response = TaggrCBOR.encode(.map([
            (.text("status"), .text("rejected")),
            (.text("reject_code"), .unsigned(5)),
            (.text("reject_message"), .text("denied")),
        ]))
        XCTAssertEqual(TaggrCBOR.decodeRejectMessage(response), "denied")
    }

    func testCBORDecodesNestedByteSlice() {
        let nested = TaggrCBOR.encode(.map([(.text("value"), .unsigned(7))]))
        let container = TaggrCBOR.encode(.map([(.text("nested"), .bytes(nested))]))
        guard case .bytes(let nestedSlice)? = TaggrCBOR.mapValue(container, key: "nested") else {
            return XCTFail("Nested CBOR bytes are missing.")
        }
        XCTAssertEqual(TaggrCBOR.decode(nestedSlice), .map([(.text("value"), .unsigned(7))]))
    }

    func testPostEnvelopeDecodesTupleShape() throws {
        let post = try JSONDecoder().decode(TaggrPostEnvelope.self, from: postEnvelopeFixture())
        XCTAssertEqual(post.post.id, 42)
        XCTAssertEqual(post.post.parent, nil)
        XCTAssertEqual(post.post.children, [])
        XCTAssertEqual(post.post.reactions, [:])
        XCTAssertEqual(post.post.meta.authorName, "alice")
        XCTAssertEqual(post.post.meta.realmColor, nil)
        XCTAssertEqual(post.post.encrypted, false)
    }

    func testPostEnvelopeRejectsObjectFallback() {
        let object = Data(#"{"post":{},"meta":{}}"#.utf8)
        let singlePost = Data(#"{"id":42,"body":"hello","user":7,"timestamp":1,"children":[],"reactions":{}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaggrPostEnvelope.self, from: object))
        XCTAssertThrowsError(try JSONDecoder().decode(TaggrPostEnvelope.self, from: singlePost))
    }

    func testPostEnvelopeArrayNormalizesFeedRows() throws {
        let data = Data("[\(String(data: postEnvelopeFixture(), encoding: .utf8)!)]".utf8)
        let rows = try JSONDecoder().decode([TaggrPostEnvelope].self, from: data)
        let posts = rows.map(\.post)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].meta.authorName, "alice")
        XCTAssertEqual(posts[0].body, "hello")
    }

    func testPostImageMarkdownExtraction() {
        let body = "hello\n\n![320x240, 12kb](/blob/a1b2c3d4)\n![x](/blob/second)"
        XCTAssertEqual(TaggrPostImages.imageIDs(in: body), ["a1b2c3d4", "second"])
        XCTAssertEqual(TaggrPostImages.textWithoutImageMarkdown(body), "hello")
    }

    func testPostImageURLUsesRuntimeConfig() {
        let mainnet = TaggrRuntimeConfig.from(info: [:])
        XCTAssertEqual(
            TaggrPostImages.imageURL(bucketId: "aaaaa-aa", offset: 12, length: 34, config: mainnet)?.absoluteString,
            "https://aaaaa-aa.raw.icp0.io/image?offset=12&len=34"
        )
        let local = TaggrRuntimeConfig.from(info: ["TAGGR_API_BASE_URL": "http://127.0.0.1:8001"])
        XCTAssertEqual(
            TaggrPostImages.imageURL(bucketId: "aaaaa-aa", offset: 12, length: 34, config: local)?.absoluteString,
            "http://aaaaa-aa.raw.localhost:8001/image?offset=12&len=34"
        )
    }

    func testPostImageAttachmentsSkipMalformedFilesMetadata() {
        let post = samplePost(
            body: "hello\n\n![x](/blob/a1b2c3d4)",
            files: ["a1b2c3d4@aaaaa-aa": [LosslessInt(12)]]
        )
        XCTAssertEqual(post.imageAttachments(), [])
    }

    func testImageDraftsRejectsOversizedCompressedOutput() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        guard let data = image.pngData() else {
            return XCTFail("Fixture image is missing.")
        }
        XCTAssertNil(ImageDrafts.normalizedImageData(data, maxBytes: 1))
    }

    func testFeedModeDerivesFromFeedRoute() {
        XCTAssertEqual(FeedView.feedMode(from: .feed(.realm("DEV"))), .realm("DEV"))
        XCTAssertNil(FeedView.feedMode(from: .realm("DEV")))
    }

    func testIdentityBridgeRestrictsMessagesToIdentityMainFrameOrigin() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_II_URL": "http://id.ai.localhost:8000/#authorize",
        ])
        XCTAssertTrue(IdentityWebView.bridgeForMainFrameOnly)
        XCTAssertTrue(IdentityWebView.Coordinator.acceptsIdentityOrigin(
            scheme: "http",
            host: "id.ai.localhost",
            port: 8000,
            config: config
        ))
        XCTAssertFalse(IdentityWebView.Coordinator.acceptsIdentityOrigin(
            scheme: "http",
            host: "evil.localhost",
            port: 8000,
            config: config
        ))
    }

    func testQueryRejectedResponseSurfacesRejectedError() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = TaggrCBOR.encode(.map([
                (.text("status"), .text("rejected")),
                (.text("reject_message"), .text("denied")),
            ]))
            return (response, body)
        }
        do {
            _ = try await api.query("stats", args: [], as: TaggrStats.self)
            XCTFail("Expected rejected error.")
        } catch TaggrAPIError.rejected(let message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Expected rejected error, got \(error).")
        }
    }

    @MainActor
    func testPersonalFeedUsesSignedQueryWhenAuthenticated() async throws {
        var capturedBody: Data?
        let api = makeStubbedAPI { request in
            capturedBody = Self.requestBody(from: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let state = TaggrAppState(api: api)
        state.authSession = makeAuthSession(privateKey: privateKey)

        await state.loadFeed(mode: .personal, reset: true)

        guard let capturedBody,
              case .map(let envelope)? = TaggrCBOR.decode(capturedBody) else {
            return XCTFail("Signed personal feed query was not sent.")
        }
        XCTAssertNotNil(value(named: "sender_sig", in: envelope))
        XCTAssertNil(state.errorMessage)
    }

    func testIdentityPayloadValidation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let rootPublicKey = TaggrIdentityBridge.derPublicKey(from: Data(repeating: 1, count: 32))
        let sessionPublicKey = TaggrIdentityBridge.derPublicKey(from: privateKey.publicKey.rawRepresentation)
        let expiration = UInt64((Date().timeIntervalSince1970 + 3600) * 1_000_000_000)
        let payload = #"{"kind":"authorize-client-success","userPublicKey":\#(Array(rootPublicKey)),"delegations":[{"delegation":{"pubkey":\#(Array(sessionPublicKey)),"expiration":"\#(expiration)"},"signature":[1,2,3]}]}"#
        let session = try TaggrIdentityBridge.makeSession(from: payload, privateKey: privateKey)
        XCTAssertEqual(session.sessionPublicKey, sessionPublicKey)
        XCTAssertEqual(session.delegation.delegations.count, 1)
    }

    func testIdentityPayloadRejectsExpiredDelegation() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let rootPublicKey = TaggrIdentityBridge.derPublicKey(from: Data(repeating: 1, count: 32))
        let sessionPublicKey = TaggrIdentityBridge.derPublicKey(from: privateKey.publicKey.rawRepresentation)
        let payload = #"{"kind":"authorize-client-success","userPublicKey":\#(Array(rootPublicKey)),"delegations":[{"delegation":{"pubkey":\#(Array(sessionPublicKey)),"expiration":"1"},"signature":[1,2,3]}]}"#
        XCTAssertThrowsError(try TaggrIdentityBridge.makeSession(from: payload, privateKey: privateKey))
    }

    func testIdentityPayloadRejectsMismatchedSessionKey() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let rootPublicKey = TaggrIdentityBridge.derPublicKey(from: Data(repeating: 1, count: 32))
        let mismatchedSessionPublicKey = TaggrIdentityBridge.derPublicKey(from: Data(repeating: 9, count: 32))
        let expiration = UInt64((Date().timeIntervalSince1970 + 3600) * 1_000_000_000)
        let payload = #"{"kind":"authorize-client-success","userPublicKey":\#(Array(rootPublicKey)),"delegations":[{"delegation":{"pubkey":\#(Array(mismatchedSessionPublicKey)),"expiration":"\#(expiration)"},"signature":[1,2,3]}]}"#
        XCTAssertThrowsError(try TaggrIdentityBridge.makeSession(from: payload, privateKey: privateKey)) { error in
            guard case TaggrIdentityError.invalidPayload = error else {
                return XCTFail("Expected invalid payload, got \(error).")
            }
        }
    }

    func testIdentityPayloadFailure() {
        let privateKey = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try TaggrIdentityBridge.makeSession(from: #"{"kind":"authorize-client-failure","text":"denied"}"#, privateKey: privateKey))
    }

    func testReadStateCertificateStatusReadsReply() throws {
        let requestId = Data(repeating: 7, count: 32)
        let reply = Data([1, 2, 3])
        let tree = certificateTree(requestId: requestId, status: "replied", reply: reply)
        let readState = readStateResponse(tree: tree)
        let result = try TaggrCBOR.certificateStatusArg(from: readState, requestId: requestId)
        XCTAssertEqual(try result?.get(), reply)
    }

    func testReadStateCertificateStatusMapsRejected() throws {
        let requestId = Data(repeating: 7, count: 32)
        let tree = certificateTree(requestId: requestId, status: "rejected", rejectMessage: "denied")
        let readState = readStateResponse(tree: tree)
        let result = try TaggrCBOR.certificateStatusArg(from: readState, requestId: requestId)
        guard case .failure(let error)? = result,
              case TaggrAPIError.rejected(let message) = error else {
            return XCTFail("Expected rejected status.")
        }
        XCTAssertEqual(message, "denied")
    }

    func testReadStateCertificatePendingStatusesReturnNil() throws {
        let requestId = Data(repeating: 7, count: 32)
        for status in ["received", "processing", "unknown"] {
            let tree = certificateTree(requestId: requestId, status: status)
            let readState = readStateResponse(tree: tree)
            let result = try TaggrCBOR.certificateStatusArg(from: readState, requestId: requestId)
            XCTAssertNil(try result?.get())
        }
    }

    private func makeAuthSession(privateKey: Curve25519.Signing.PrivateKey) -> TaggrAuthSession {
        let sessionPublicKey = TaggrIdentityBridge.derPublicKey(from: privateKey.publicKey.rawRepresentation)
        let rootPublicKey = TaggrIdentityBridge.derPublicKey(from: Data(repeating: 1, count: 32))
        let delegation = TaggrDelegationChain(
            publicKey: rootPublicKey,
            delegations: [
                .init(
                    delegation: .init(publicKey: sessionPublicKey, expiration: UInt64.max, targets: nil),
                    signature: Data([1, 2, 3])
                ),
            ]
        )
        return TaggrAuthSession(
            principal: "2vxsx-fae",
            sessionPublicKey: sessionPublicKey,
            sessionPrivateKey: privateKey.rawRepresentation,
            delegation: delegation,
            createdAt: Date()
        )
    }

    private func value(named name: String, in values: [(TaggrCBOR.Value, TaggrCBOR.Value)]) -> TaggrCBOR.Value? {
        values.first { $0.0 == .text(name) }?.1
    }

    private func makeStubbedAPI(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> TaggrAPI {
        TaggrURLProtocolStub.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaggrURLProtocolStub.self]
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_API_BASE_URL": "https://example.test",
        ])
        return TaggrAPI(session: URLSession(configuration: configuration), config: config)
    }

    private static func queryReply(_ arg: Data) -> Data {
        TaggrCBOR.encode(.map([
            (.text("status"), .text("replied")),
            (.text("reply"), .map([(.text("arg"), .bytes(arg))])),
        ]))
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBufferPointer {
                stream.read($0.baseAddress!, maxLength: $0.count)
            }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func samplePost(body: String, files: [String: [LosslessInt]]) -> TaggrPost {
        TaggrPost(
            id: 1,
            parent: nil,
            user: 1,
            body: body,
            effBody: nil,
            realm: nil,
            timestamp: LosslessInt(1),
            reactions: [:],
            children: [],
            meta: TaggrPostMeta(authorName: "alice", realmColor: nil, nsfw: false, viewerBlocked: false),
            watchers: [],
            reposts: [],
            files: files,
            patches: [],
            tips: [],
            hashes: [],
            extensionValue: nil,
            treeSize: nil,
            treeUpdate: nil,
            encrypted: false,
            hiddenFor: []
        )
    }

    private func readStateResponse(tree: TaggrCBOR.Value) -> Data {
        let certificate = TaggrCBOR.encode(.map([
            (.text("tree"), tree),
            (.text("signature"), .bytes(Data([9]))),
        ]))
        return TaggrCBOR.encode(.map([(.text("certificate"), .bytes(certificate))]))
    }

    private func certificateTree(requestId: Data, status: String, reply: Data? = nil, rejectMessage: String? = nil) -> TaggrCBOR.Value {
        var requestBranches: [TaggrCBOR.Value] = [
            labeled("status", .array([.unsigned(3), .bytes(Data(status.utf8))])),
        ]
        if let reply {
            requestBranches.insert(labeled("reply", .array([.unsigned(3), .bytes(reply)])), at: 0)
        }
        if let rejectMessage {
            requestBranches.insert(labeled("reject_message", .array([.unsigned(3), .bytes(Data(rejectMessage.utf8))])), at: 0)
        }
        let requestTree = forkedTree(requestBranches)
        let statusTree = labeledBytes(requestId, requestTree)
        let timeTree = labeled("time", .array([.unsigned(3), .bytes(leb128(UInt64((Date().timeIntervalSince1970) * 1_000_000_000)))]))
        return .array([
            .unsigned(1),
            labeled("request_status", statusTree),
            timeTree,
        ])
    }

    private func forkedTree(_ branches: [TaggrCBOR.Value]) -> TaggrCBOR.Value {
        guard let first = branches.first else {
            return .array([.unsigned(0)])
        }
        return branches.dropFirst().reduce(first) { partial, branch in
            .array([.unsigned(1), partial, branch])
        }
    }

    private func labeled(_ label: String, _ value: TaggrCBOR.Value) -> TaggrCBOR.Value {
        labeledBytes(Data(label.utf8), value)
    }

    private func labeledBytes(_ label: Data, _ value: TaggrCBOR.Value) -> TaggrCBOR.Value {
        .array([.unsigned(2), .bytes(label), value])
    }

    private func leb128(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while value != 0
        return data
    }

    private func postEnvelopeFixture() -> Data {
        Data(
            #"""
            [
              {
                "id": 42,
                "parent": null,
                "user": 7,
                "body": "hello",
                "timestamp": "123",
                "children": [],
                "reactions": {},
                "watchers": [],
                "reposts": [],
                "files": {},
                "patches": [[123, "hello"]],
                "tips": [],
                "hashes": [],
                "extension": null,
                "tree_size": 1,
                "tree_update": "123",
                "encrypted": false,
                "hidden_for": []
              },
              {
                "author_name": "alice",
                "author_filters": {"users": [], "tags": [], "realms": []},
                "viewer_blocked": false,
                "nsfw": false,
                "max_downvotes_reached": false
              }
            ]
            """#.utf8
        )
    }
}

private final class TaggrURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TaggrAPIError.invalidResponse("missing URLProtocol stub"))
            return
        }
        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
