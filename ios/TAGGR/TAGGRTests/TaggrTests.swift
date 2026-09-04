import XCTest
import AuthenticationServices
import CryptoKit
import UIKit
@testable import ICNativeClient
@testable import TAGGR

@MainActor
final class TaggrTests: XCTestCase {
    func testRoutesUniversalLinks() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/post/12")!), .post(12))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice")!), .profile("alice"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice/photos")!), .userPhotos("alice"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/realm/DEV")!), .realm("DEV"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/inbox")!), .inbox)
        XCTAssertEqual(TaggrNavigation.universalURL(for: .userPhotos("alice")).path, "/user/alice/photos")
    }

    func testFeedFragmentRoutesSupportTags() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/latest")!), .feed(.latest))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/tag")!), .feed(.tags(["tag"])))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/TAG")!), .feed(.tags(["TAG"])))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/@alice+tag")!), .feed(.tags(["@alice", "tag"])))
        XCTAssertEqual(TaggrNavigation.universalURL(for: .feed(.tags(["TAG"]))).path, "/feed/TAG")
        XCTAssertEqual(TaggrNavigation.universalURL(for: .feed(.realm("DEV"))).path, "/realm/DEV")
    }

    func testTokenAndWalletRoutesOpenAccount() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transaction/12")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transactions")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/tokens")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/wallet")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/auction")!), .settings)
    }

    func testRejectsExternalHosts() {
        XCTAssertNil(TaggrNavigation.route(from: URL(string: "https://example.com/post/1")!))
    }

    func testRuntimeConfigUsesProductionDefaults() {
        let config = TaggrRuntimeConfig.from(info: [:])
        XCTAssertEqual(config.canisterId, TaggrRuntimeConfig.productionCanisterId)
        XCTAssertEqual(config.apiBaseURL, TaggrRuntimeConfig.productionAPIBaseURL)
        XCTAssertEqual(config.domain, TaggrRuntimeConfig.productionDomain)
        XCTAssertEqual(config.callbackDomain, TaggrRuntimeConfig.productionDomain)
        XCTAssertEqual(config.identityURL, TaggrRuntimeConfig.productionIdentityURL)
        XCTAssertEqual(
            config.identityURL.absoluteString,
            "https://id.ai/authorize"
        )
        XCTAssertEqual(config.derivationOrigin, TaggrRuntimeConfig.productionDerivationOrigin)
    }

    @MainActor
    func testCustomBuildConfigIsUsedAtLaunch() {
        let customConfig = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com",
            "TAGGR_CALLBACK_DOMAIN": "callback.trycloudflare.com",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://identity.trycloudflare.com/authorize",
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
        ])
        var apiConfig: TaggrRuntimeConfig?
        var identityStoreConfig: TaggrRuntimeConfig?
        var authenticatorConfig: TaggrRuntimeConfig?
        let identityService = testIdentityService()

        let state = TaggrAppCoordinator(
            buildConfig: customConfig,
            apiFactory: { config in
                apiConfig = config
                return TaggrAPI(config: config)
            },
            identityStoreFactory: { config in
                identityStoreConfig = config
                return self.makeTestIdentityStore(config: config, service: identityService)
            },
            identityAuthenticatorFactory: { config in
                authenticatorConfig = config
                return try! ICInternetIdentityAuthenticator(
                    configuration: config.icClientConfiguration,
                    callbackDomain: config.callbackDomain,
                    callbackPath: ICInternetIdentityAuthenticator.callbackPath
                )
            }
        )

        XCTAssertEqual(state.runtimeConfig, customConfig)
        XCTAssertEqual(apiConfig, customConfig)
        XCTAssertEqual(identityStoreConfig, customConfig)
        XCTAssertEqual(authenticatorConfig, customConfig)
        XCTAssertEqual(state.runtimeConfig.canisterId, "bkyz2-fmaaa-aaaaa-qaaaq-cai")
        XCTAssertEqual(state.runtimeConfig.apiBaseURL.absoluteString, "https://taggr.trycloudflare.com")
        XCTAssertEqual(state.runtimeConfig.domain, "taggr.trycloudflare.com")
        XCTAssertEqual(state.runtimeConfig.callbackDomain, "callback.trycloudflare.com")
        XCTAssertEqual(state.runtimeConfig.identityURL.absoluteString, "https://identity.trycloudflare.com/authorize")
        XCTAssertEqual(state.runtimeConfig.derivationOrigin, "https://taggr.trycloudflare.com")
    }

    func testRuntimeConfigReadsInfoOverrides() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com",
            "TAGGR_CALLBACK_DOMAIN": "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://taggr-identity.trycloudflare.com/authorize",
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
        ])
        XCTAssertEqual(config.canisterId, "bkyz2-fmaaa-aaaaa-qaaaq-cai")
        XCTAssertEqual(config.apiURL(for: "query").absoluteString, "https://taggr.trycloudflare.com/api/v3/canister/bkyz2-fmaaa-aaaaa-qaaaq-cai/query")
        XCTAssertEqual(config.domain, "taggr.trycloudflare.com")
        XCTAssertEqual(config.callbackDomain, "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io")
        XCTAssertEqual(config.identityURL.absoluteString, "https://taggr-identity.trycloudflare.com/authorize")
        XCTAssertEqual(config.derivationOrigin, "https://taggr.trycloudflare.com")
        XCTAssertTrue(config.shouldLoadBucketImagesThroughAPI)
    }

    func testRuntimeConfigIgnoresBuildSettingPlaceholders() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "$(TAGGR_CANISTER_ID)",
            "TAGGR_API_BASE_URL": "$(TAGGR_API_BASE_URL)",
            "TAGGR_CALLBACK_DOMAIN": "$(TAGGR_CALLBACK_DOMAIN)",
            "TAGGR_DOMAIN": "$(TAGGR_DOMAIN)",
            "TAGGR_II_URL": "$(TAGGR_II_URL)",
            "TAGGR_DERIVATION_ORIGIN": "$(TAGGR_DERIVATION_ORIGIN)",
        ])
        XCTAssertEqual(config, TaggrRuntimeConfig.from(info: [:]))
    }

    func testAPIURLUsesRuntimeConfig() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com/",
        ])
        let api = TaggrAPI(config: config)
        XCTAssertEqual(api.apiURL(for: "read_state").absoluteString, "https://taggr.trycloudflare.com/api/v3/canister/bkyz2-fmaaa-aaaaa-qaaaq-cai/read_state")
        XCTAssertEqual(api.apiURL(for: "call", canisterId: "aaaaa-aa").absoluteString, "https://taggr.trycloudflare.com/api/v4/canister/aaaaa-aa/call")
    }

    func testICRC167AuthorizationURLUsesRuntimeConfig() throws {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://taggr-identity.trycloudflare.com/authorize",
            "TAGGR_CALLBACK_DOMAIN": "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
        ])
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )
        let pending = try ICRC167Codec.makePendingRequest()
        let url = try ICRC167Codec.authorizationURL(
            configuration: config.icClientConfiguration,
            callbackURL: callbackURL,
            pendingRequest: pending
        )
        var fragment = URLComponents()
        fragment.percentEncodedQuery = try XCTUnwrap(url.fragment)
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(fragment.queryItems).map {
            ($0.name, $0.value ?? "")
        })
        let message = try XCTUnwrap(query["message"]?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "taggr-identity.trycloudflare.com")
        XCTAssertEqual(url.path, "/authorize")
        XCTAssertNil(url.port)
        XCTAssertEqual(query["state"], pending.state)
        XCTAssertEqual(query["callback"], "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/ios-auth-callback")
        XCTAssertEqual(object["method"] as? String, "icrc34_delegation")
        XCTAssertEqual(object["id"] as? String, pending.requestID)
        XCTAssertEqual(params["maxTimeToLive"] as? String, String(pending.maxTimeToLiveNanoseconds))
        XCTAssertEqual(params["icrc95DerivationOrigin"] as? String, config.derivationOrigin)
    }

    func testProductionCallbackUsesExplicitHTTPSPath() throws {
        let config = TaggrRuntimeConfig.from(info: [:])
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )

        XCTAssertEqual(callbackURL.absoluteString, "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/ios-auth-callback")
    }

    func testCustomDomainCallbackUsesExplicitHTTPSPath() throws {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_DOMAIN": "example.ngrok-free.app",
        ])
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )

        XCTAssertEqual(callbackURL.absoluteString, "https://example.ngrok-free.app/ios-auth-callback")
    }

    func testIdentityStorePersistsOnlyMatchingRuntimeConfig() throws {
        let config = customRuntimeConfig()
        let service = "network.taggr.ios.identity.tests.\(UUID().uuidString)"
        let account = "session"
        let keychain = TaggrTestKeychain()
        let store = ICIdentityStore(
            configuration: config.icClientConfiguration,
            service: service,
            account: account,
            keychain: keychain
        )
        let otherStore = ICIdentityStore(
            configuration: TaggrRuntimeConfig.from(info: [:]).icClientConfiguration,
            service: service,
            account: account,
            keychain: keychain
        )
        defer {
            try? store.clear()
            try? otherStore.clear()
        }
        let session = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey(), config: config)

        try store.save(session)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.canisterId, config.canisterId)
        XCTAssertEqual(loaded.internetIdentityURL, config.identityURL.absoluteString)
        XCTAssertEqual(loaded.derivationOrigin, config.derivationOrigin)

        XCTAssertThrowsError(try otherStore.load()) { error in
            XCTAssertEqual(error as? ICClientError, .invalidPayload)
        }

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testIdentityStoreUsesWhenUnlockedKeychainProtection() {
        XCTAssertEqual(
            ICIdentityStore.keychainAccessibility,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
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

    func testCandidGoldenFixtures() throws {
        XCTAssertEqual(try TaggrCandidAdapter.emptyArguments().encode().icHexString, "4449444c0000")
        XCTAssertEqual(
            try TaggrCandidAdapter.addPostArguments(text: "hello", refs: [], parent: 1, realm: "DEV", extensionBlob: nil).encode().icHexString,
            "4449444c066d016c030071017802786e786e716e056d7b0571000203040568656c6c6f00010100000000000000010344455600"
        )
        XCTAssertEqual(
            try TaggrCandidAdapter.addPostArguments(
                text: "hello",
                refs: [(id: "blob-id", offset: 0, length: 3)],
                parent: 1,
                realm: "DEV",
                extensionBlob: nil
            ).encode().icHexString,
            "4449444c066d016c030071017802786e786e716e056d7b0571000203040568656c6c6f0107626c6f622d696400000000000000000300000000000000010100000000000000010344455600"
        )
        XCTAssertEqual(
            try TaggrCandidAdapter.editPostArguments(id: 7, text: "hello", refs: [], patch: "patch", realm: "DEV").encode().icHexString,
            "4449444c036d016c030071017802786e7105787100710207000000000000000568656c6c6f000570617463680103444556"
        )
    }

    func testGeneratedLedgerBindingsProduceCandidMessages() throws {
        let account = try ICPAccountIdentifier.defaultAccount(for: "2vxsx-fae")
        XCTAssertEqual(try TaggrCandidAdapter.accountBalanceArguments(account: account).encode().prefix(4).icHexString, "4449444c")
        XCTAssertEqual(try TaggrCandidAdapter.transferArguments(
            to: account, amountE8s: 123_000_000, feeE8s: ICPAmount.feeE8s, memo: 0
        ).encode().prefix(4).icHexString, "4449444c")
    }

    func testGeneratedCMCNotifyErrorCoversEveryProductionVariant() throws {
        let errors: [CMCNotifyError] = [
            .refunded(value: CMCNotifyErrorRefunded(blockIndex: 9, reason: "refunded")),
            .invalidTransaction(value: "invalid"),
            .transactionTooOld(value: 12),
            .processing,
            .other(value: CMCNotifyErrorOther(errorMessage: "other", errorCode: 5)),
        ]
        for error in errors {
            let decoded = try CMCNotifyError(candidValue: error.candidValue)
            XCTAssertFalse(TaggrCandidAdapter.notifyErrorMessage(decoded).isEmpty)
        }
    }

    func testLedgerTransferNestedErrorRecordsDecodeWithoutFlattening() throws {
        let tokenFields = [CandidField("e8s", type: .nat64)]
        let badFeeFields = [CandidField("expected_fee", type: .record(tokenFields))]
        let insufficientFields = [CandidField("balance", type: .record(tokenFields))]
        let errorFields = [
            CandidField("BadFee", type: .record(badFeeFields)),
            CandidField("InsufficientFunds", type: .record(insufficientFields)),
        ]
        let resultFields = [
            CandidField("Ok", type: .nat64),
            CandidField("Err", type: .variant(errorFields)),
        ]

        func reply(tag: String, payloadFields: [CandidField], payloadName: String, e8s: UInt64) throws -> CandidReply {
            let tokens = CandidValue.record(tokenFields, [Candid.fieldID("e8s"): .nat64(e8s)])
            let payload = CandidValue.record(payloadFields, [Candid.fieldID(payloadName): tokens])
            let error = CandidValue.variant(try CandidVariant(fields: errorFields, tag: tag, value: payload))
            let result = CandidValue.variant(try CandidVariant(fields: resultFields, tag: "Err", value: error))
            return CandidReply(values: [try CandidTypedValue(type: .variant(resultFields), value: result)])
        }

        XCTAssertThrowsError(try TaggrCandidAdapter.transferResult(
            reply(tag: "BadFee", payloadFields: badFeeFields, payloadName: "expected_fee", e8s: 10_000)
        )) { XCTAssertTrue($0.localizedDescription.contains("0.0001")) }
        XCTAssertThrowsError(try TaggrCandidAdapter.transferResult(
            reply(tag: "InsufficientFunds", payloadFields: insufficientFields, payloadName: "balance", e8s: 25_000)
        )) { XCTAssertTrue($0.localizedDescription.contains("0.00025")) }
    }

    func testCanisterStatusRejectsNatOverflow() throws {
        let tooLarge = try CandidNat("18446744073709551616")
        let status = try Self.managementCanisterStatus(cycles: tooLarge)
        XCTAssertThrowsError(try TaggrCandidAdapter.canisterStatus(status))
    }

    func testBucketHeadersKeepAnonymousFieldIDsZeroAndOne() throws {
        let encoded = try TaggrCandidAdapter.bucketHTTPRequestArguments(offset: 1, length: 2).encode()
        let reply = try CandidDecoder().decode(encoded)
        guard case .record(_, let request) = reply.values[0].value,
              case .vector(let headerType, _) = request[Candid.fieldID("headers")],
              case .record(let fields) = headerType else {
            return XCTFail("bucket headers are not vec record")
        }
        XCTAssertEqual(fields.map(\.id), [0, 1])
    }

    func testEditPatchBuildsFullReplacementPatches() {
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "hello world", to: "hello"),
            "@@ -1,11 +1,5 @@\n-hello world\n+hello\n"
        )
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "a\nc", to: "a\nb"),
            "@@ -1,3 +1,3 @@\n-a%0Ac\n+a%0Ab\n"
        )
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "new", to: ""),
            "@@ -1,3 +0,0 @@\n-new\n"
        )
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "", to: "old"),
            "@@ -0,0 +1,3 @@\n+old\n"
        )
    }

    func testCandidResultErrSurfacesRejectedError() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultErr("denied")))
        }
        do {
            _ = try await api.addPost(text: "hello", parent: nil, realm: nil, identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey()))
            XCTFail("Expected rejected error.")
        } catch TaggrAPIError.rejected(let message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Expected rejected error, got \(error).")
        }
    }

    func testAddPostReturnsCreatedPostId() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidAddPostResultOk(77)))
        }

        let postId = try await api.addPost(
            text: "hello",
            parent: nil,
            realm: nil,
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(postId, 77)
    }

    func testJSONErrSurfacesRejectedError() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Err":"denied"}"#.utf8)))
        }
        do {
            _ = try await api.updateJSON("react", args: [42, 53], identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey()))
            XCTFail("Expected rejected error.")
        } catch TaggrAPIError.rejected(let message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Expected rejected error, got \(error).")
        }
    }

    func testHTTPHTMLFailureSurfacesBackendUnavailableWithoutBody() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            let html = Data("<!DOCTYPE html><html><head><title>trycloudflare.com | 502: Bad gateway</title></head><body>Bad gateway</body></html>".utf8)
            return (response, html)
        }
        do {
            _ = try await api.query("user", args: [[]], as: Optional<TaggrUser>.self)
            XCTFail("Expected backend unavailable error.")
        } catch TaggrAPIError.backendUnavailable(let context) {
            XCTAssertEqual(context, "query user HTTP 502")
        } catch {
            XCTFail("Expected backend unavailable error, got \(error).")
        }
    }

    func testHTTPTextFailureKeepsShortContext() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("gateway unavailable".utf8))
        }
        do {
            _ = try await api.query("user", args: [[]], as: Optional<TaggrUser>.self)
            XCTFail("Expected backend unavailable error.")
        } catch TaggrAPIError.backendUnavailable(let context) {
            XCTAssertEqual(context, "query user HTTP 503: gateway unavailable")
        } catch {
            XCTFail("Expected backend unavailable error, got \(error).")
        }
    }

    func testCancelledHTTPErrorIsNotWrappedAsBackendUnavailable() async throws {
        let api = makeStubbedAPI { _ in
            throw URLError(.cancelled)
        }
        do {
            _ = try await api.query("user", args: [[]], as: Optional<TaggrUser>.self)
            XCTFail("Expected cancelled URL error.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Expected cancelled URL error, got \(error).")
        }
    }

    func testUpdateCallsShareMissingIdentityMessage() async {
        let api = makeStubbedAPI { _ in
            XCTFail("Missing identity should fail before network.")
            let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let operations: [() async throws -> Void] = [
            { _ = try await api.updateJSON("react", args: [42, 53], identity: nil) },
            { _ = try await api.addPost(text: "hello", parent: nil, realm: nil, identity: nil) },
            { _ = try await api.editPost(id: 42, text: "hello", patch: "patch", realm: nil, identity: nil) },
            { _ = try await api.transferICP(to: "invalid", e8s: 1, identity: nil) },
        ]

        for operation in operations {
            do {
                try await operation()
                XCTFail("Expected missing identity error.")
            } catch {
                XCTAssertEqual(error.localizedDescription, TaggrAPIError.signInRequiredMessage)
            }
        }
    }

    func testMintCreditsWithICPDecodesInvoice() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Ok":{"e8s":123456789,"paid_e8s":0,"paid":false,"account":[1,2,255]}}"#.utf8)))
        }

        let invoice = try await api.mintCreditsWithICP(
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(calls.first?.method, "mint_credits_with_icp")
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([0]))
        XCTAssertEqual(invoice.e8s, 123_456_789)
        XCTAssertEqual(invoice.paidE8s, 0)
        XCTAssertFalse(invoice.paid)
        XCTAssertEqual(invoice.account, [1, 2, 255])
        XCTAssertEqual(invoice.accountHex, "0102ff")
        XCTAssertEqual(invoice.amountICP, "1.23456789")
    }

    func testICPAmountParsesAndFormatsE8s() {
        XCTAssertEqual(ICPAmount.parse("1"), 100_000_000)
        XCTAssertEqual(ICPAmount.parse("0.0001"), 10_000)
        XCTAssertEqual(ICPAmount.parse("1.23456789"), 123_456_789)
        XCTAssertNil(ICPAmount.parse("1.123456789"))
        XCTAssertEqual(ICPAmount.format(123_450_000), "1.2345 ICP")
        XCTAssertEqual(ICPAmount.format(100_000_000, units: false), "1")
    }

    func testICPAccountIdentifierAcceptsAccountOrPrincipal() throws {
        let account = try ICPAccountIdentifier.defaultAccount(for: "2vxsx-fae")
        XCTAssertEqual(account.count, 32)
        XCTAssertEqual(try ICPAccountIdentifier.parse(account.icHexString), account)
        XCTAssertEqual(try ICPAccountIdentifier.parse("2vxsx-fae"), account)
        XCTAssertThrowsError(try ICPAccountIdentifier.parse(String(repeating: "0", count: 64)))
    }

    func testCMCSubaccountIdentifierUsesPrincipalSubaccount() throws {
        let defaultCMC = try ICPAccountIdentifier.defaultAccount(for: TaggrAPI.cmcCanisterId)
        let userCMC = try ICPAccountIdentifier.account(
            for: TaggrAPI.cmcCanisterId,
            subaccountPrincipal: "2vxsx-fae"
        )
        let bucketCMC = try ICPAccountIdentifier.account(
            for: TaggrAPI.cmcCanisterId,
            subaccountPrincipal: "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        )

        XCTAssertEqual(userCMC.count, 32)
        XCTAssertEqual(bucketCMC.count, 32)
        XCTAssertNotEqual(defaultCMC, userCMC)
        XCTAssertNotEqual(userCMC, bucketCMC)
    }

    func testStorageCreationStateRoundTripsThroughSettingsJSON() throws {
        let state = TaggrStorageCreationState(stage: .created, blockIndex: 12, canisterId: "bkyz2-fmaaa-aaaaa-qaaaq-cai")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TaggrStorageCreationState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(TaggrStorageCreationState.settingKey, "bucket_creation_state")
    }

    @MainActor
    func testStorageUpgradeDetectionComparesModuleHashes() {
        let state = TaggrAppCoordinator()
        state.storageExpectedWasmHash = "01020304"
        state.storageStatus = TaggrStorageCanisterStatus(
            status: "running",
            controllers: [],
            moduleHash: Data([0x01, 0x02, 0x03, 0x04]),
            memorySize: 0,
            cycles: 0,
            idleCyclesBurnedPerDay: 0
        )
        XCTAssertFalse(state.storageNeedsUpgrade)

        state.storageStatus = TaggrStorageCanisterStatus(
            status: "running",
            controllers: [],
            moduleHash: Data([0x04, 0x03, 0x02, 0x01]),
            memorySize: 0,
            cycles: 0,
            idleCyclesBurnedPerDay: 0
        )
        XCTAssertTrue(state.storageNeedsUpgrade)
    }

    func testStorageCandidEncodersProduceMessages() throws {
        XCTAssertEqual(try TaggrCandidAdapter.canisterStatusArguments(canisterId: "bkyz2-fmaaa-aaaaa-qaaaq-cai").encode().prefix(4).icHexString, "4449444c")
        let createArg = try TaggrCandidAdapter.notifyCreateCanisterArguments(
            blockIndex: 7,
            controller: "swqvp-ecw6b-psba6-673lj-2bnf4-z4n66-6mgzy-sbdaq-ksjck-m5zoz-wae",
            blackhole: TaggrAPI.blackholeCanisterId
        ).encode()
        XCTAssertEqual(createArg.prefix(4).icHexString, "4449444c")
        let decodedCreate = try CandidDecoder().decode(createArg)
        let create = try CandidRecord(decodedCreate.values[0].value)
        guard case .optional(_, let settingsValue)? = create.fields[Candid.fieldID("settings")],
              let settingsValue,
              case .record(_, let settings) = settingsValue,
              case .optional(_, let controllersValue)? = settings[Candid.fieldID("controllers")],
              let controllersValue,
              case .vector(_, let controllers) = controllersValue else {
            return XCTFail("notify_create_canister settings/controllers shape is invalid")
        }
        XCTAssertEqual(
            try controllers.map { try CandidPrincipal(candidValue: $0).text },
            [
                "swqvp-ecw6b-psba6-673lj-2bnf4-z4n66-6mgzy-sbdaq-ksjck-m5zoz-wae",
                TaggrAPI.blackholeCanisterId,
            ]
        )
        XCTAssertEqual(
            try TaggrCandidAdapter.notifyTopUpArguments(blockIndex: 7, canisterId: "bkyz2-fmaaa-aaaaa-qaaaq-cai").encode().prefix(4).icHexString,
            "4449444c"
        )
        XCTAssertEqual(
            try TaggrCandidAdapter.updateInternalControllersArguments([TaggrAPI.blackholeCanisterId]).encode().prefix(4).icHexString,
            "4449444c"
        )
    }

    func testCanisterStatusUsesManagementRequestIDAndBucketRoutingID() async throws {
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        var requestPath: String?
        var requestCanister: Data?
        let api = makeStubbedAPI { request in
            requestPath = request.url?.path
            if let body = Self.requestBody(from: request),
               let envelope = self.cborMap(from: body),
               case .map(let content)? = self.value(named: "content", in: envelope),
               case .bytes(let canister)? = self.value(named: "canister_id", in: content) {
                requestCanister = canister
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(try Self.candidCanisterStatus()))
        }

        let status = try await api.storageCanisterStatus(
            bucketId,
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(status.status, "running")
        XCTAssertTrue(requestPath?.contains("/canister/\(bucketId)/query") == true)
        XCTAssertEqual(requestCanister, ICPrincipal.parse(TaggrAPI.managementCanisterId))
    }

    func testInstallBucketCodeCandidMatchesWebIDL() throws {
        let encoded = try TaggrCandidAdapter.installCodeArguments(
            canisterId: "a5dhi-k7777-77775-aaabq-cai",
            wasm: Data([0, 1, 2]),
            userPrincipal: "swqvp-ecw6b-psba6-673lj-2bnf4-z4n66-6mgzy-sbdaq-ksjck-m5zoz-wae",
            mode: .install
        ).encode()
        XCTAssertEqual(encoded.prefix(4).icHexString, "4449444c")
        XCTAssertThrowsError(try TaggrCandidAdapter.installMode("unknown"))
    }

    func testICPAccountBalanceQueriesLedgerCanister() async throws {
        var calls: [(method: String, arg: Data, path: String)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append((call.method, call.arg, request.url?.path ?? ""))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidTokens(123_456)))
        }

        let balance = try await api.icpAccountBalance(ownerPrincipal: "2vxsx-fae")

        XCTAssertEqual(balance, 123_456)
        XCTAssertEqual(calls.first?.method, "account_balance")
        XCTAssertTrue(calls.first?.path.contains(TaggrAPI.icpLedgerCanisterId) == true)
        XCTAssertEqual(
            calls.first?.arg,
            try TaggrCandidAdapter.accountBalanceArguments(account: ICPAccountIdentifier.defaultAccount(for: "2vxsx-fae")).encode()
        )
    }

    func testTransferICPCallsLedgerTransfer() async throws {
        var calls: [(method: String, arg: Data, path: String)] = []
        let recipient = try ICPAccountIdentifier.defaultAccount(for: "2vxsx-fae").icHexString
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append((call.method, call.arg, request.url?.path ?? ""))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidLedgerTransferResultOk(77)))
        }

        let block = try await api.transferICP(
            to: recipient,
            e8s: 123_000_000,
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(block, 77)
        XCTAssertEqual(calls.first?.method, "transfer")
        XCTAssertTrue(calls.first?.path.contains(TaggrAPI.icpLedgerCanisterId) == true)
        XCTAssertEqual(
            calls.first?.arg,
            try TaggrCandidAdapter.transferArguments(
                to: try ICPAccountIdentifier.parse(recipient),
                amountE8s: 123_000_000,
                feeE8s: ICPAmount.feeE8s,
                memo: 0
            ).encode()
        )
    }

    func testRequestIdGoldenVector() {
        let content: ICCBOR.Value = .map([
            (.text("request_type"), .text("query")),
            (.text("canister_id"), .bytes(Data([1, 2, 3]))),
            (.text("method_name"), .text("stats")),
            (.text("arg"), .bytes(Data(icHex: "4449444c0000")!)),
            (.text("sender"), .bytes(Data([4]))),
        ])
        XCTAssertEqual(ICRequestID.hash(of: content).icHexString, "162bcd6936bd4c6f2aba446cb7f6fe1960ec7e402c8056550040e35f0fe3afc4")
    }

    func testCBORSignedEnvelopeShape() {
        let delegation = ICDelegationChain(
            publicKey: Data([1, 2, 3]),
            delegations: [
                .init(
                    delegation: .init(publicKey: Data([4, 5, 6]), expiration: UInt64.max, targets: nil),
                    signature: Data([7, 8])
                ),
            ]
        )
        let envelope = ICCBOR.signedEnvelope(
            content: .map([(.text("request_type"), .text("query"))]),
            publicKey: delegation.publicKey,
            signature: Data([9, 10]),
            delegation: delegation
        )
        guard let values = cborMap(from: envelope) else {
            return XCTFail("Envelope is not a CBOR map.")
        }
        XCTAssertTrue(values.contains { $0.0 == .text("content") })
        XCTAssertTrue(values.contains { $0.0 == .text("sender_pubkey") })
        XCTAssertTrue(values.contains { $0.0 == .text("sender_sig") })
        XCTAssertTrue(values.contains { $0.0 == .text("sender_delegation") })
    }

    func testSignedEnvelopeUsesDelegationPublicKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let session = makeAuthSession(privateKey: privateKey)
        let content: ICCBOR.Value = .map([(.text("request_type"), .text("query"))])
        let envelope = try ICClient.signedEnvelope(content: content, identity: session)
        guard let values = cborMap(from: envelope) else {
            return XCTFail("Envelope is not a CBOR map.")
        }
        XCTAssertEqual(value(named: "sender_pubkey", in: values), .bytes(session.delegation.publicKey))
        XCTAssertNotEqual(value(named: "sender_pubkey", in: values), .bytes(session.sessionPublicKey))
    }

    func testSignedEnvelopeSignatureVerifiesWithSessionPublicKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let session = makeAuthSession(privateKey: privateKey)
        let content: ICCBOR.Value = .map([(.text("request_type"), .text("query"))])
        let envelope = try ICClient.signedEnvelope(content: content, identity: session)
        guard let values = cborMap(from: envelope),
              case .bytes(let signature)? = value(named: "sender_sig", in: values),
              case .bytes(let senderPublicKey)? = value(named: "sender_pubkey", in: values) else {
            return XCTFail("Envelope signature is missing.")
        }
        XCTAssertEqual(senderPublicKey, session.delegation.publicKey)
        let requestId = ICRequestID.hash(of: content)
        let challenge = Data([0x0a]) + Data("ic-request".utf8) + requestId
        let rawPublicKey = Data(session.sessionPublicKey.dropFirst(ICRC167Codec.ed25519DERPrefix.count))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: challenge))
    }

    func testUpdatePollingReadStateOmitsCanisterId() async throws {
        var updateRequestId: Data?
        var readStateBody: Data?
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/call") == true {
                guard let body = Self.requestBody(from: request),
                      let envelope = self.cborMap(from: body),
                      let content = self.value(named: "content", in: envelope) else {
                    throw TaggrAPIError.invalidResponse("call envelope")
                }
                updateRequestId = ICRequestID.hash(of: content)
                return (response, Data())
            }
            if request.url?.path.hasSuffix("/read_state") == true {
                readStateBody = Self.requestBody(from: request)
                let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let tree = self.certificateTree(
                    requestId: try XCTUnwrap(updateRequestId),
                    status: "replied",
                    reply: Data("null".utf8)
                )
                return (ok, self.readStateResponse(tree: tree))
            }
            throw TaggrAPIError.invalidResponse("unexpected request")
        }

        _ = try await api.createUser(
            name: "alice",
            invite: "",
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        guard let readStateBody,
              let envelope = cborMap(from: readStateBody),
              case .map(let content)? = value(named: "content", in: envelope) else {
            return XCTFail("read_state envelope was not sent.")
        }
        XCTAssertEqual(value(named: "request_type", in: content), .text("read_state"))
        XCTAssertNil(value(named: "canister_id", in: content))
        XCTAssertNotNil(value(named: "paths", in: content))
        XCTAssertNotNil(value(named: "sender", in: content))
        XCTAssertNotNil(value(named: "sender_sig", in: envelope))
    }

    func testAPIRejectsSessionForDifferentRuntimeConfig() async throws {
        let config = customRuntimeConfig()
        let api = TaggrAPI(config: config)
        let session = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        do {
            try await api.validateIdentity(session, requestCanisterId: config.canisterId)
            XCTFail("Expected invalidIdentity.")
        } catch {
            guard case TaggrAPIError.invalidIdentity = error else {
                return XCTFail("Expected invalidIdentity, got \(error).")
            }
        }
    }

    func testBucketWriteAcceptsUntargetedSession() async throws {
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        var capturedURL: URL?
        let api = makeStubbedAPI { request in
            capturedURL = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data([0, 0, 0, 0, 0, 0, 0, 7])))
        }

        let offset = try await api.bucketWrite(
            bucketId: bucketId,
            blob: Data([1, 2, 3]),
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(offset, 7)
        XCTAssertTrue(capturedURL?.path.contains("/canister/\(bucketId)/call") == true)
    }

    func testBucketWriteRejectsMainOnlyTargetBeforeSending() async throws {
        var didSend = false
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        let mainTarget = try XCTUnwrap(ICPrincipal.parse(TaggrRuntimeConfig.productionCanisterId))
        let api = makeStubbedAPI { request in
            didSend = true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data()))
        }
        let identity = makeAuthSession(
            privateKey: Curve25519.Signing.PrivateKey(),
            targets: [mainTarget]
        )

        do {
            _ = try await api.bucketWrite(bucketId: bucketId, blob: Data([1]), identity: identity)
            XCTFail("Expected invalidIdentity.")
        } catch TaggrAPIError.invalidIdentity {
        } catch {
            XCTFail("Expected invalidIdentity, got \(error).")
        }
        XCTAssertFalse(didSend)
    }

    func testBucketWriteAcceptsBucketTarget() async throws {
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        let bucketTarget = try XCTUnwrap(ICPrincipal.parse(bucketId))
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data()))
        }
        let identity = makeAuthSession(
            privateKey: Curve25519.Signing.PrivateKey(),
            targets: [bucketTarget]
        )

        try await api.validateIdentity(identity, requestCanisterId: bucketId)
    }

    func testPrincipalTextRoundTripAndRejectsBadChecksum() throws {
        let blob = Data([1, 2, 3, 4, 5])
        let text = ICPrincipal.text(from: blob)
        XCTAssertEqual(ICPrincipal.parse(text), blob)

        let replacement = text.hasSuffix("a") ? "b" : "a"
        let tampered = String(text.dropLast()) + replacement
        XCTAssertNil(ICPrincipal.parse(tampered))
    }

    func testCBORDecodesNestedByteSlice() {
        let nested = ICCBOR.encode(.map([(.text("value"), .unsigned(7))]))
        let container = ICCBOR.encode(.map([(.text("nested"), .bytes(nested))]))
        guard case .bytes(let nestedSlice)? = ICCBOR.mapValue(container, key: "nested") else {
            return XCTFail("Nested CBOR bytes are missing.")
        }
        XCTAssertEqual(ICCBOR.decode(nestedSlice), .map([(.text("value"), .unsigned(7))]))
    }

    func testPostEnvelopeDecodesTupleShape() throws {
        let post = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture())
        XCTAssertEqual(post.post.id, 42)
        XCTAssertEqual(post.post.parent, nil)
        XCTAssertEqual(post.post.children, [])
        XCTAssertEqual(post.post.reactions, [:])
        XCTAssertEqual(post.post.meta.authorName, "alice")
        XCTAssertEqual(post.post.meta.realmColor, "#123456")
        XCTAssertEqual(post.post.meta.viewerBlocked, false)
        XCTAssertEqual(post.post.encrypted, false)
        XCTAssertEqual(post.post.treeSize, 1)
        XCTAssertEqual(post.post.hiddenFor, [])
    }

    func testPostEnvelopeAllowsMissingAuthorNameFallback() throws {
        let post = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeWithoutAuthorFixture())
        XCTAssertNil(post.post.meta.authorName)
        XCTAssertEqual(post.post.user, 7)
    }

    func testPostEnvelopeRejectsObjectFallback() {
        let object = Data(#"{"post":{},"meta":{}}"#.utf8)
        let singlePost = Data(#"{"id":42,"body":"hello","user":7,"timestamp":1,"children":[],"reactions":{}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: object))
        XCTAssertThrowsError(try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: singlePost))
    }

    func testPostEnvelopeArrayNormalizesFeedRows() throws {
        let data = Data("[\(String(data: postEnvelopeFixture(), encoding: .utf8)!)]".utf8)
        let rows = try JSONDecoder.taggr.decode([TaggrPostEnvelope].self, from: data)
        let posts = rows.map(\.post)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].meta.authorName, "alice")
        XCTAssertEqual(posts[0].body, "hello")
    }

    func testConfigDecodesReactions() throws {
        let data = Data(#"{"name":"TAGGR","token_symbol":"TAGGR","token_decimals":2,"max_post_length":5000,"max_tag_length":30,"max_blob_size_bytes":460800,"max_report_length":1000,"reactions":[[11,1],[10,1],[1,-3]],"feed_page_size":25,"poll_revote_deadline_hours":2,"post_cost":10,"poll_cost":4,"post_deletion_penalty_factor":3}"#.utf8)
        let config = try JSONDecoder.taggr.decode(TaggrConfig.self, from: data)
        XCTAssertEqual(config.reactions, [[11, 1], [10, 1], [1, -3]])
        XCTAssertEqual(config.tokenSymbol, "TAGGR")
        XCTAssertEqual(config.tokenDecimals, 2)
        XCTAssertEqual(config.maxPostLength, 5000)
        XCTAssertEqual(config.maxTagLength, 30)
        XCTAssertEqual(config.maxBlobSizeBytes, 460_800)
        XCTAssertEqual(config.maxReportLength, 1000)
        XCTAssertEqual(config.feedPageSize, 25)
        XCTAssertEqual(config.pollRevoteDeadlineHours, 2)
        XCTAssertEqual(config.postCost, 10)
        XCTAssertEqual(config.pollCost, 4)
        XCTAssertEqual(config.postDeletionPenaltyFactor, 3)
    }
}
