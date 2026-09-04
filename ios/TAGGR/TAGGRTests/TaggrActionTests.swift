import XCTest
import AuthenticationServices
import CBlst
import CryptoKit
import UIKit
@testable import ICNativeClient
@testable import TAGGR

extension TaggrTests {
    func testPollHidePinAndDeleteUsePostUpdateMethods() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let post = samplePost(
            id: 42,
            body: "hello",
            files: [:],
            extensionValue: .object([
                "Poll": .object([
                    "options": .array([.string("yes")]),
                    "votes": .object([:]),
                    "voters": .array([]),
                    "deadline": .number(0),
                ]),
            ]),
            patches: [[.number(123), .string(TaggrEditPatch.fullReplacement(from: "hello", to: "edited"))]]
        )
        state.feed = [post]
        state.focusedPost = post
        state.repliesByPostID = [100: [post]]

        await state.toggleHide(postId: 42)
        XCTAssertTrue(state.feed.first?.hiddenFor.contains(7) == true)
        await state.voteOnPoll(postId: 42, option: 0, anonymously: true)
        await state.togglePinnedPost(postId: 42)
        await state.deletePost(post)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.filter { $0.method != "hot_posts" && $0.method != "user" }.map(\.method), [
            "toggle_hide_post",
            "vote_on_poll",
            "toggle_pinned_post",
            "delete_post",
        ])
        XCTAssertEqual(calls.first { $0.method == "vote_on_poll" }?.arg, try TaggrCandid.jsonArguments([42, 0, true]))
        XCTAssertEqual(calls.first { $0.method == "toggle_hide_post" }?.arg, try TaggrCandid.jsonArguments([42]))
        XCTAssertEqual(calls.first { $0.method == "toggle_pinned_post" }?.arg, try TaggrCandid.jsonArguments([42]))
        XCTAssertEqual(calls.first { $0.method == "delete_post" }?.arg, try TaggrCandid.jsonArguments([42, ["edited", "hello"]]))
    }

    @MainActor
    func testDeletePostDoesNotCallBackendWhenPatchHistoryIsInvalid() async {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        let post = samplePost(
            id: 42,
            user: 7,
            body: "hello",
            files: [:],
            patches: [[.number(123), .string("@@ malformed")]]
        )

        await state.deletePost(post)

        XCTAssertFalse(calls.contains { $0.method == "delete_post" })
        XCTAssertEqual(state.errorMessage, TaggrEditPatchError.malformedPatch.localizedDescription)
    }

    @MainActor
    func testUnreadNotificationCountIgnoresReadEntries() {
        let state = TaggrAppCoordinator()
        state.currentUser = notificationUser([
            1: TaggrNotificationEntry(notification: .generic("Unread"), read: false),
            2: TaggrNotificationEntry(notification: .generic("Read"), read: true),
            3: TaggrNotificationEntry(notification: .newPost(message: "New", postId: 42), read: false),
        ])

        XCTAssertEqual(state.unreadNotificationCount, 2)
        XCTAssertEqual(state.notificationEntries(read: false).map(\.id), [3, 1])
        XCTAssertEqual(state.notificationEntries(read: true).map(\.id), [2])
    }

    @MainActor
    func testMarkNotificationsReadSendsTopLevelIdArray() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = notificationUser([
            1: TaggrNotificationEntry(notification: .generic("Unread"), read: false),
        ])

        await state.markNotificationsRead([1])

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["clear_notifications"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([[1]]))
        XCTAssertEqual(state.currentUser?.notifications[1]?.read, true)
    }

    @MainActor
    func testUnwatchPostFromNotificationClearsAndTogglesWatch() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = notificationUser([
            9: TaggrNotificationEntry(notification: .watchedPostEntries(postId: 42, entries: [43]), read: false),
        ])

        await state.unwatchPostFromNotification(notificationId: 9, postId: 42)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["clear_notifications", "toggle_following_post"])
        XCTAssertEqual(calls.map(\.arg), [
            try TaggrCandid.jsonArguments([[9]]),
            try TaggrCandid.jsonArguments([42]),
        ])
        XCTAssertEqual(state.currentUser?.notifications[9]?.read, true)
    }

    @MainActor
    func testCreateUserPassesNameInviteAndRefreshesCurrentUser() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                switch calls.last?.method {
                case "user":
                    return (response, Self.queryReply(Self.currentUserFixture()))
                case "stats", "config":
                    return (response, Self.queryReply(Data("{}".utf8)))
                default:
                    return (response, Self.queryReply(Data("[]".utf8)))
                }
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.icpInvoice = TaggrICPInvoice(e8s: 100_000_000, paidE8s: 0, paid: true, account: [9])

        await state.createUser(name: " alice ", invite: " INVITE ")

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "create_user")
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments(["alice", "INVITE"]))
        XCTAssertEqual(state.currentUser?.name, "alice")
        XCTAssertNil(state.icpInvoice)
        XCTAssertFalse(calls.contains { $0.method == "mint_credits_with_icp" })
    }

    @MainActor
    func testCheckICPInvoiceStoresPaymentAccount() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Ok":{"e8s":100000000,"paid_e8s":0,"paid":false,"account":[222,173,190,239]}}"#.utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.checkICPInvoice()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["mint_credits_with_icp"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([0]))
        XCTAssertEqual(state.icpInvoice?.amountICP, "1")
        XCTAssertEqual(state.icpInvoice?.accountHex, "deadbeef")
    }

    @MainActor
    func testMintOneKCreditsTransfersICPAndRefreshesBalances() async throws {
        var calls: [(method: String, arg: Data, path: String)] = []
        var mintCalls = 0
        let account = try ICPAccountIdentifier.defaultAccount(for: "2vxsx-fae")
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append((call.method, call.arg, request.url?.path ?? ""))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch calls.last?.method {
            case "mint_credits_with_icp":
                mintCalls += 1
                if mintCalls == 1 {
                    return (response, Self.queryReply(Data(#"{"Ok":{"e8s":100000000,"paid_e8s":0,"paid":false,"account":\#(Array(account).description)}}"#.utf8)))
                }
                return (response, Self.queryReply(Data(#"{"Ok":{"e8s":100000000,"paid_e8s":100000000,"paid":true,"account":\#(Array(account).description)}}"#.utf8)))
            case "transfer":
                return (response, Self.queryReply(Self.candidLedgerTransferResultOk(88)))
            case "user":
                return (response, Self.queryReply(Self.currentUserFixture()))
            case "account_balance":
                return (response, Self.queryReply(Self.candidTokens(200_000_000)))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.mintOneKCredits()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), [
            "mint_credits_with_icp",
            "transfer",
            "mint_credits_with_icp",
            "user",
            "account_balance",
        ])
        XCTAssertEqual(calls[0].arg, try TaggrCandid.jsonArguments([0]))
        XCTAssertEqual(calls[2].arg, try TaggrCandid.jsonArguments([1]))
        XCTAssertTrue(calls[1].path.contains(TaggrAPI.icpLedgerCanisterId))
        XCTAssertEqual(state.currentUser?.name, "alice")
        XCTAssertEqual(state.icpBalanceE8s, 200_000_000)
        XCTAssertNil(state.icpInvoice)
    }

    @MainActor
    func testRepostPassesExtensionBlob() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.repost(postId: 42, text: "boost", realm: "DEV")

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "add_post")
        let extensionBlob = Data(#"{"Repost":42}"#.utf8)
        XCTAssertEqual(
            calls.first?.arg,
            try TaggrCandidAdapter.addPostArguments(
                text: "boost",
                refs: [],
                parent: nil,
                realm: "DEV",
                extensionBlob: extensionBlob
            ).encode()
        )
    }

    @MainActor
    func testSignOutClearsPersonalFeed() {
        let post = samplePost(body: "hello", files: [:])
        let state = TaggrAppCoordinator(
            identityStore: makeTestIdentityStore(
                config: TaggrRuntimeConfig.current,
                service: testIdentityService()
            )
        )
        state.route = .feed(.personal)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.feed = [post]
        state.focusedPost = post
        state.profile = TaggrUser(id: 1, name: "alice", about: "", principal: nil, realms: [], followees: [], followers: [], blacklist: [], mode: nil)

        state.signOut()

        XCTAssertNil(state.authSession)
        XCTAssertNil(state.focusedPost)
        XCTAssertNil(state.profile)
        XCTAssertEqual(state.feed, [])
    }

    @MainActor
    func testSignOutKeepsPublicFeed() {
        let post = samplePost(body: "hello", files: [:])
        let state = TaggrAppCoordinator(
            identityStore: makeTestIdentityStore(
                config: TaggrRuntimeConfig.current,
                service: testIdentityService()
            )
        )
        state.route = .feed(.latest)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.feed = [post]

        state.signOut()

        XCTAssertNil(state.authSession)
        XCTAssertEqual(state.feed, [post])
    }

    func customRuntimeConfig() -> TaggrRuntimeConfig {
        TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://taggr-identity.trycloudflare.com/authorize",
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
        ])
    }

    func testIdentityService() -> String {
        "network.taggr.ios.identity.tests.\(UUID().uuidString)"
    }

    func makeTestIdentityStore(
        config: TaggrRuntimeConfig,
        service: String
    ) -> ICIdentityStore {
        ICIdentityStore(
            configuration: config.icClientConfiguration,
            service: service
        )
    }

    func makeAuthSession(
        privateKey: Curve25519.Signing.PrivateKey,
        config: TaggrRuntimeConfig = .from(info: [:]),
        targets: [Data]? = nil
    ) -> ICAuthSession {
        let rootPrivateKey = Curve25519.Signing.PrivateKey()
        let sessionPublicKey = ICRC167Codec.derPublicKey(from: privateKey.publicKey.rawRepresentation)
        let rootPublicKey = ICRC167Codec.derPublicKey(from: rootPrivateKey.publicKey.rawRepresentation)
        let requestedAt = Date()
        let ttl = config.icClientConfiguration.delegationTTLNanoseconds
        let requestedAtNanoseconds = UInt64(requestedAt.timeIntervalSince1970 * 1_000_000_000)
        let expiration = requestedAtNanoseconds + ttl
        let delegation = ICDelegationChain.SignedDelegation.Delegation(
            publicKey: sessionPublicKey,
            expiration: expiration,
            targets: targets
        )
        var signableFields: [(ICCBOR.Value, ICCBOR.Value)] = [
            (.text("pubkey"), .bytes(delegation.publicKey)),
            (.text("expiration"), .unsigned(delegation.expiration)),
        ]
        if let targets {
            signableFields.append((.text("targets"), .array(targets.map(ICCBOR.Value.bytes))))
        }
        let signable = Data([0x1a])
            + Data("ic-request-auth-delegation".utf8)
            + ICRequestID.hash(of: .map(signableFields))
        let chain = ICDelegationChain(
            publicKey: rootPublicKey,
            delegations: [
                .init(delegation: delegation, signature: try! rootPrivateKey.signature(for: signable)),
            ]
        )
        let principal = ICPrincipal.text(from: ICPrincipal.selfAuthenticatingPublicKey(rootPublicKey))
        return ICAuthSession(storage: ICStoredAuthSession(
            formatVersion: ICAuthSession.currentFormatVersion,
            principal: principal,
            canisterId: config.canisterId,
            internetIdentityURL: config.identityURL.absoluteString,
            derivationOrigin: config.derivationOrigin,
            sessionPublicKey: sessionPublicKey,
            sessionPrivateKey: privateKey.rawRepresentation,
            delegation: chain,
            requestedAt: requestedAt,
            maxTimeToLiveNanoseconds: ttl
        ))
    }

    nonisolated static func candidResultErr(_ message: String) -> Data {
        try! CandidArguments([CandidTypedValue(TaggrResult.err(value: message))]).encode()
    }

    nonisolated static func candidAddPostResultOk(_ value: UInt64) -> Data {
        try! CandidArguments([CandidTypedValue(TaggrResult.ok(value: value))]).encode()
    }

    nonisolated static func candidEditPostResultOk() -> Data {
        try! CandidArguments([CandidTypedValue(TaggrResult1.ok)]).encode()
    }

    nonisolated static func candidLedgerTransferResultOk(_ value: UInt64) -> Data {
        try! CandidArguments([CandidTypedValue(LedgerTransferResult.ok(value: value))]).encode()
    }

    nonisolated static func candidTokens(_ e8s: UInt64) -> Data {
        var data = Data("DIDL".utf8)
        data.append(leb128(1))
        data.append(sleb128(-20))
        data.append(leb128(1))
        data.append(leb128(candidFieldId("e8s")))
        data.append(sleb128(-8))
        data.append(leb128(1))
        data.append(sleb128(0))
        withUnsafeBytes(of: e8s.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    nonisolated static func candidCanisterStatus() throws -> Data {
        let status = try managementCanisterStatus(cycles: CandidNat("2"))
        return try CandidArguments([CandidTypedValue(status)]).encode()
    }

    nonisolated static func managementCanisterStatus(cycles: CandidNat) throws -> ManagementCanisterStatus {
        let zero = try CandidNat("0")
        return ManagementCanisterStatus(
            memoryMetrics: ManagementMemoryMetrics(
                wasmBinarySize: zero,
                wasmChunkStoreSize: zero,
                canisterHistorySize: zero,
                stableMemorySize: zero,
                snapshotsSize: zero,
                wasmMemorySize: zero,
                globalMemorySize: zero,
                customSectionsSize: zero
            ),
            status: .running,
            memorySize: try CandidNat("1"),
            readyForMigration: false,
            version: 0,
            cycles: cycles,
            settings: ManagementDefiniteCanisterSettings(
                freezingThreshold: zero,
                wasmMemoryThreshold: zero,
                environmentVariables: [],
                controllers: [],
                reservedCyclesLimit: zero,
                logVisibility: .controllers,
                snapshotVisibility: .controllers,
                wasmMemoryLimit: zero,
                memoryAllocation: zero,
                computeAllocation: zero
            ),
            queryStats: ManagementQueryStats(
                responsePayloadBytesTotal: zero,
                numInstructionsTotal: zero,
                numCallsTotal: zero,
                requestPayloadBytesTotal: zero
            ),
            idleCyclesBurnedPerDay: try CandidNat("3"),
            moduleHash: nil,
            reservedCycles: zero
        )
    }

    nonisolated static func candidFieldId(_ label: String) -> UInt64 {
        var hash: UInt32 = 0
        for byte in label.utf8 {
            hash = hash &* 223 &+ UInt32(byte)
        }
        return UInt64(hash)
    }

    nonisolated static func sleb128(_ value: Int64) -> Data {
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

    nonisolated static func leb128(_ value: UInt64) -> Data {
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

    nonisolated func value(named name: String, in values: [(ICCBOR.Value, ICCBOR.Value)]) -> ICCBOR.Value? {
        values.first { $0.0 == .text(name) }?.1
    }

    func makeStubbedAPI(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> TaggrAPI {
        makeStubbedAPI(handler, config: TaggrRuntimeConfig.from(info: [
            "TAGGR_API_BASE_URL": "https://example.test",
        ]))
    }

    func makeStubbedAPI(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        config: TaggrRuntimeConfig
    ) -> TaggrAPI {
        let root = TaggrTestBLSKey(seed: 1)
        let node = Curve25519.Signing.PrivateKey()
        let nodeId = Data([0xaa])
        let subnetId = Data([0x01, 0x02, 0x03])
        let subnetCertificate = try! signedSubnetCertificate(
            root: root,
            subnetId: subnetId,
            nodeId: nodeId,
            node: node
        )
        TaggrURLProtocolStub.requestHandler = { request in
            if request.url?.path.hasSuffix("/read_state") == true,
               self.readStateRequest(request, containsPathLabel: "subnet") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (
                    response,
                    ICCBOR.encode(.map([(.text("certificate"), .bytes(subnetCertificate))]))
                )
            }
            let (response, data) = try handler(request)
            if request.url?.path.hasSuffix("/read_state") == true {
                return (response, try self.resignReadStateResponse(data, key: root))
            }
            guard let body = Self.requestBody(from: request),
                  let envelope = self.cborMap(from: body),
                  case .map(let content)? = self.value(named: "content", in: envelope) else {
                return (response, data)
            }
            if request.url?.path.hasSuffix("/query") == true,
               let queryResponse = self.cborMap(from: data) {
                let requestId = ICRequestID.hash(of: .map(content))
                let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
                let unsigned: Data
                let signed: (Data) -> Data
                if case .map(let reply)? = self.value(named: "reply", in: queryResponse),
                   case .bytes(let arg)? = self.value(named: "arg", in: reply) {
                    unsigned = Self.signedQueryReply(arg: arg, signatures: [])
                    signed = { signature in
                        Self.signedQueryReply(
                            arg: arg,
                            signatures: [(nodeId, signature, timestamp)]
                        )
                    }
                } else if case .text("rejected")? = self.value(named: "status", in: queryResponse),
                          case .text(let message)? = self.value(named: "reject_message", in: queryResponse) {
                    let code: UInt64
                    if case .unsigned(let value)? = self.value(named: "reject_code", in: queryResponse) {
                        code = value
                    } else {
                        code = 5
                    }
                    unsigned = Self.signedQueryReject(code: code, message: message, signatures: [])
                    signed = { signature in
                        Self.signedQueryReject(
                            code: code,
                            message: message,
                            signatures: [(nodeId, signature, timestamp)]
                        )
                    }
                } else {
                    return (response, data)
                }
                let parsed = try ICQueryResponse(cbor: unsigned)
                let signature = try node.signature(
                    for: parsed.signable(requestID: requestId, timestamp: timestamp)
                )
                return (response, signed(signature))
            }
            guard request.url?.path.hasSuffix("/call") == true,
                  let queryResponse = self.cborMap(from: data),
                  case .map(let reply)? = self.value(named: "reply", in: queryResponse),
                  case .bytes(let arg)? = self.value(named: "arg", in: reply) else {
                return (response, data)
            }
            let requestId = ICRequestID.hash(of: .map(content))
            let certificate = try self.signedCertificate(
                requestId: requestId,
                reply: arg,
                key: root
            )
            return (
                response,
                ICCBOR.encode(.map([
                    (.text("status"), .text("replied")),
                    (.text("certificate"), .bytes(certificate)),
                ]))
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaggrURLProtocolStub.self]
        return TaggrAPI(
            session: URLSession(configuration: configuration),
            config: config,
            trustRoot: .custom(root.derPublicKey)
        )
    }

    nonisolated static func queryReply(_ arg: Data) -> Data {
        ICCBOR.encode(.map([
            (.text("status"), .text("replied")),
            (.text("reply"), .map([(.text("arg"), .bytes(arg))])),
        ]))
    }

    nonisolated static func signedQueryReply(
        arg: Data,
        signatures: [(Data, Data, UInt64)]
    ) -> Data {
        ICCBOR.encode(.map([
            (.text("status"), .text("replied")),
            (.text("reply"), .map([(.text("arg"), .bytes(arg))])),
            (.text("signatures"), .array(signatures.map { identity, signature, timestamp in
                .map([
                    (.text("identity"), .bytes(identity)),
                    (.text("signature"), .bytes(signature)),
                    (.text("timestamp"), .unsigned(timestamp)),
                ])
            })),
        ]))
    }

    nonisolated static func signedQueryReject(
        code: UInt64,
        message: String,
        signatures: [(Data, Data, UInt64)]
    ) -> Data {
        ICCBOR.encode(.map([
            (.text("status"), .text("rejected")),
            (.text("reject_code"), .unsigned(code)),
            (.text("reject_message"), .text(message)),
            (.text("signatures"), .array(signatures.map { identity, signature, timestamp in
                .map([
                    (.text("identity"), .bytes(identity)),
                    (.text("signature"), .bytes(signature)),
                    (.text("timestamp"), .unsigned(timestamp)),
                ])
            })),
        ]))
    }

    nonisolated static func currentUserFixture() -> Data {
        Data(#"{"id":7,"name":"alice","about":"","principal":null,"realms":[],"followees":[],"followers":[],"blacklist":[],"bookmarks":[42],"pinned_posts":[],"settings":{},"controlled_realms":[],"mode":null}"#.utf8)
    }

    nonisolated static func userFixture(id: Int = 7, name: String = "alice") -> Data {
        return Data(
            """
            {
              "id": \(id),
              "name": "\(name)",
              "about": "",
              "principal": null,
              "realms": [],
              "followees": [],
              "followers": [],
              "blacklist": [],
              "bookmarks": [],
              "pinned_posts": [],
              "settings": {},
              "controlled_realms": [],
              "mode": null
            }
            """.utf8
        )
    }

    nonisolated static func requestBody(from request: URLRequest) -> Data? {
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

    nonisolated func requestMethodAndArg(from request: URLRequest) -> (method: String, arg: Data)? {
        guard let body = Self.requestBody(from: request),
              let envelope = cborMap(from: body),
              case .map(let content)? = value(named: "content", in: envelope),
              case .text(let method)? = value(named: "method_name", in: content),
              case .bytes(let arg)? = value(named: "arg", in: content) else {
            return nil
        }
        return (method, arg)
    }

    nonisolated func cborMap(from data: Data) -> [(ICCBOR.Value, ICCBOR.Value)]? {
        switch ICCBOR.decode(data) {
        case .map(let fields):
            return fields
        case .tagged(ICCBOR.selfDescribeTag, .map(let fields)):
            return fields
        default:
            return nil
        }
    }

    nonisolated func readStateRequest(_ request: URLRequest, containsPathLabel label: String) -> Bool {
        guard let body = Self.requestBody(from: request),
              let envelope = cborMap(from: body),
              case .map(let content)? = value(named: "content", in: envelope),
              case .array(let paths)? = value(named: "paths", in: content) else {
            return false
        }
        return paths.contains { path in
            guard case .array(let labels) = path else { return false }
            return labels.contains(.bytes(Data(label.utf8)))
        }
    }

    func notificationUser(_ notifications: [Int: TaggrNotificationEntry]) -> TaggrUser {
        TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            notifications: notifications,
            mode: nil
        )
    }

    func samplePost(
        id: Int = 1,
        user: Int = 1,
        parent: Int? = nil,
        body: String,
        effBody: String? = nil,
        reactions: [String: [Int]] = [:],
        children: [Int] = [],
        files: [String: [LosslessInt]],
        timestamp: LosslessInt = LosslessInt(1),
        treeSize: Int? = nil,
        realm: String? = nil,
        extensionValue: JSONValue? = nil,
        patches: [[JSONValue]] = [],
        hashes: [String] = [],
        encrypted: Bool = false,
        hiddenFor: [Int] = [],
        meta: TaggrPostMeta = TaggrPostMeta(authorName: "alice", realmColor: nil, nsfw: false, viewerBlocked: false)
    ) -> TaggrPost {
        TaggrPost(
            id: id,
            parent: parent,
            user: user,
            body: body,
            effBody: effBody,
            realm: realm,
            timestamp: timestamp,
            reactions: reactions,
            children: children,
            meta: meta,
            watchers: [],
            reposts: [],
            files: files,
            patches: patches,
            tips: [],
            hashes: hashes,
            extensionValue: extensionValue,
            treeSize: treeSize,
            treeUpdate: nil,
            encrypted: encrypted,
            hiddenFor: hiddenFor
        )
    }

    func timestamp(year: Int, month: Int) -> LosslessInt {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12)) ?? Date(timeIntervalSince1970: 0)
        return LosslessInt(Int64(date.timeIntervalSince1970) * 1_000_000_000)
    }

    nonisolated func readStateResponse(tree: ICCBOR.Value) -> Data {
        let certificate = ICCBOR.encode(.map([
            (.text("tree"), tree),
            (.text("signature"), .bytes(Data([9]))),
        ]))
        return ICCBOR.encode(.map([(.text("certificate"), .bytes(certificate))]))
    }

    nonisolated fileprivate func signedCertificate(
        requestId: Data,
        reply: Data,
        key: TaggrTestBLSKey
    ) throws -> Data {
        let tree = certificateTree(requestId: requestId, status: "replied", reply: reply)
        let digest = try ICHashTree(value: tree).digest
        let signature = key.sign(Data([0x0d]) + Data("ic-state-root".utf8) + digest)
        return ICCBOR.encode(.tagged(ICCBOR.selfDescribeTag, .map([
            (.text("tree"), tree),
            (.text("signature"), .bytes(signature)),
        ])))
    }

    nonisolated fileprivate func resignReadStateResponse(
        _ data: Data,
        key: TaggrTestBLSKey
    ) throws -> Data {
        guard let response = cborMap(from: data),
              case .bytes(let certificateData)? = value(named: "certificate", in: response),
              let certificate = cborMap(from: certificateData),
              let tree = value(named: "tree", in: certificate) else {
            throw TaggrAPIError.invalidResponse("read_state certificate fixture")
        }
        let digest = try ICHashTree(value: tree).digest
        let signature = key.sign(Data([0x0d]) + Data("ic-state-root".utf8) + digest)
        let signed = ICCBOR.encode(.tagged(ICCBOR.selfDescribeTag, .map([
            (.text("tree"), tree),
            (.text("signature"), .bytes(signature)),
        ])))
        return ICCBOR.encode(.map([(.text("certificate"), .bytes(signed))]))
    }

    nonisolated fileprivate func signedSubnetCertificate(
        root: TaggrTestBLSKey,
        subnetId: Data,
        nodeId: Data,
        node: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let ranges = ICCBOR.encode(.array([
            .array([.bytes(Data()), .bytes(Data(repeating: 0xff, count: 29))]),
        ]))
        let tree = hashTree([
            ([Data("time".utf8)], leb128(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))),
            ([Data("subnet".utf8), subnetId, Data("canister_ranges".utf8)], ranges),
            ([Data("subnet".utf8), subnetId, Data("node".utf8), nodeId, Data("public_key".utf8)],
             ICRC167Codec.derPublicKey(from: node.publicKey.rawRepresentation)),
        ])
        let digest = try ICHashTree(value: tree).digest
        let signature = root.sign(Data([0x0d]) + Data("ic-state-root".utf8) + digest)
        return ICCBOR.encode(.tagged(ICCBOR.selfDescribeTag, .map([
            (.text("tree"), tree),
            (.text("signature"), .bytes(signature)),
        ])))
    }

    nonisolated func hashTree(_ leaves: [([Data], Data)]) -> ICCBOR.Value {
        precondition(!leaves.isEmpty)
        let groups = Dictionary(grouping: leaves, by: { $0.0[0] })
        let nodes = groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }).map { label -> ICCBOR.Value in
            let entries = groups[label]!
            let child: ICCBOR.Value
            if entries.allSatisfy({ $0.0.count == 1 }) {
                precondition(entries.count == 1)
                child = .array([.unsigned(3), .bytes(entries[0].1)])
            } else {
                child = hashTree(entries.map { (Array($0.0.dropFirst()), $0.1) })
            }
            return .array([.unsigned(2), .bytes(label), child])
        }
        return forkTree(nodes)
    }

    nonisolated func forkTree(_ nodes: [ICCBOR.Value]) -> ICCBOR.Value {
        if nodes.count == 1 { return nodes[0] }
        let midpoint = nodes.count / 2
        return .array([
            .unsigned(1),
            forkTree(Array(nodes[..<midpoint])),
            forkTree(Array(nodes[midpoint...])),
        ])
    }

    nonisolated func certificateTree(requestId: Data, status: String, reply: Data? = nil, rejectMessage: String? = nil) -> ICCBOR.Value {
        var requestBranches: [ICCBOR.Value] = [
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

    nonisolated func forkedTree(_ branches: [ICCBOR.Value]) -> ICCBOR.Value {
        guard let first = branches.first else {
            return .array([.unsigned(0)])
        }
        return branches.dropFirst().reduce(first) { partial, branch in
            .array([.unsigned(1), partial, branch])
        }
    }

    nonisolated func labeled(_ label: String, _ value: ICCBOR.Value) -> ICCBOR.Value {
        labeledBytes(Data(label.utf8), value)
    }

    nonisolated func labeledBytes(_ label: Data, _ value: ICCBOR.Value) -> ICCBOR.Value {
        .array([.unsigned(2), .bytes(label), value])
    }

    nonisolated func leb128(_ value: UInt64) -> Data {
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

    nonisolated func postEnvelopeFixture(id: Int = 42, parent: Int? = nil, extensionJSON: String = "null") -> Data {
        let parentJSON = parent.map(String.init) ?? "null"
        return Data(
            """
            [
              {
                "id": \(id),
                "parent": \(parentJSON),
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
                "extension": \(extensionJSON),
                "tree_size": 1,
                "tree_update": "123",
                "encrypted": false,
                "hidden_for": []
              },
              {
                "author_name": "alice",
                "author_filters": {"users": [], "tags": [], "realms": []},
                "realm_color": "#123456",
                "viewer_blocked": false,
                "nsfw": false,
                "max_downvotes_reached": false
              }
            ]
            """.data(using: .utf8)!
        )
    }

    nonisolated func postEnvelopeWithoutAuthorFixture() -> Data {
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
                "patches": [],
                "tips": [],
                "hashes": [],
                "extension": null,
                "encrypted": false,
                "hidden_for": []
              },
              {
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

fileprivate struct TaggrTestBLSKey: @unchecked Sendable {
    private static let dst = Data("BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_".utf8)
    private let secret: blst_scalar
    private let publicKey: Data

    var derPublicKey: Data {
        Data([
            0x30, 0x81, 0x82, 0x30, 0x1d, 0x06, 0x0d, 0x2b, 0x06, 0x01, 0x04, 0x01,
            0x82, 0xdc, 0x7c, 0x05, 0x03, 0x01, 0x02, 0x01, 0x06, 0x0c, 0x2b, 0x06,
            0x01, 0x04, 0x01, 0x82, 0xdc, 0x7c, 0x05, 0x03, 0x02, 0x01, 0x03, 0x61, 0x00,
        ]) + publicKey
    }

    init(seed: UInt8) {
        var secret = blst_scalar()
        let ikm = Data(repeating: seed, count: 32)
        ikm.withUnsafeBytes { bytes in
            blst_keygen(&secret, bytes.bindMemory(to: UInt8.self).baseAddress, ikm.count, nil, 0)
        }
        var point = blst_p2()
        blst_sk_to_pk_in_g2(&point, &secret)
        var compressed = [UInt8](repeating: 0, count: 96)
        blst_p2_compress(&compressed, &point)
        self.secret = secret
        self.publicKey = Data(compressed)
    }

    func sign(_ message: Data) -> Data {
        var hash = blst_p1()
        message.withUnsafeBytes { messageBytes in
            Self.dst.withUnsafeBytes { dstBytes in
                blst_hash_to_g1(
                    &hash,
                    messageBytes.bindMemory(to: UInt8.self).baseAddress,
                    message.count,
                    dstBytes.bindMemory(to: UInt8.self).baseAddress,
                    Self.dst.count,
                    nil,
                    0
                )
            }
        }
        var signature = blst_p1()
        var secret = secret
        blst_sign_pk_in_g2(&signature, &hash, &secret)
        var compressed = [UInt8](repeating: 0, count: 48)
        blst_p1_compress(&compressed, &signature)
        return Data(compressed)
    }
}

final class TaggrTestKeychain: ICKeychainAccess, @unchecked Sendable {
    private var data: Data?

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        result?.pointee = data as CFData?
        return data == nil ? errSecItemNotFound : errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        guard data != nil else { return errSecItemNotFound }
        if let values = attributes as? [String: Any] {
            data = values[kSecValueData as String] as? Data
        }
        return errSecSuccess
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        guard data == nil else { return errSecDuplicateItem }
        if let values = attributes as? [String: Any] {
            data = values[kSecValueData as String] as? Data
        }
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        data = nil
        return errSecSuccess
    }
}

final class TaggrURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
