import CryptoKit
import ICNativeClient
import XCTest
@testable import TAGGR

final class TaggrIdentityTests: XCTestCase {
    func testIdentitySessionUsesRuntimeConfiguration() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let session = try ICIdentitySession.makeSession(
            privateKey: privateKey,
            delegation: delegation(for: privateKey),
            configuration: defaultConfiguration
        )

        XCTAssertEqual(session.canisterId, TaggrRuntimeConfig.productionCanisterId)
        XCTAssertEqual(session.identityProvider, "https://id.ai/authorize")
        XCTAssertEqual(session.derivationOrigin, TaggrRuntimeConfig.productionDerivationOrigin)
        XCTAssertEqual(
            session.sessionPublicKey,
            ICIdentitySession.derPublicKey(from: privateKey.publicKey.rawRepresentation)
        )
    }

    func testIdentitySessionRejectsMismatchedLeafKey() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()

        XCTAssertThrowsError(try ICIdentitySession.makeSession(
            privateKey: privateKey,
            delegation: delegation(for: otherKey),
            configuration: defaultConfiguration
        ))
    }

    func testIdentitySessionRejectsExpiredDelegation() {
        let privateKey = Curve25519.Signing.PrivateKey()

        XCTAssertThrowsError(try ICIdentitySession.makeSession(
            privateKey: privateKey,
            delegation: delegation(for: privateKey, expiration: 1),
            configuration: defaultConfiguration
        ))
    }

    private var defaultConfiguration: ICClientConfiguration {
        TaggrRuntimeConfig.from(info: [:]).icClientConfiguration
    }

    private func delegation(
        for privateKey: Curve25519.Signing.PrivateKey,
        expiration: UInt64 = UInt64((Date().timeIntervalSince1970 + 3600) * 1_000_000_000)
    ) -> ICDelegationChain {
        ICDelegationChain(
            publicKey: ICIdentitySession.derPublicKey(
                from: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            ),
            delegations: [
                .init(
                    delegation: .init(
                        publicKey: ICIdentitySession.derPublicKey(
                            from: privateKey.publicKey.rawRepresentation
                        ),
                        expiration: expiration,
                        targets: nil
                    ),
                    signature: Data(repeating: 7, count: 64)
                ),
            ]
        )
    }
}
