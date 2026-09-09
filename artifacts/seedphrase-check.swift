import CryptoKit
import Foundation
import SwiftUI

enum TaggrSeedPhrase {
    nonisolated static func privateKey(from phrase: String) throws -> Data {
        guard !phrase.isEmpty else {
            throw TaggrSeedPhraseError.empty
        }
        // Match authentication.tsx/common.tsx exactly, including whitespace and UTF-8 bytes.
        var seed = Data(phrase.utf8)
        for _ in 0..<15_000 {
            seed = Data(SHA256.hash(data: seed))
        }
        return seed
    }
}

enum TaggrSeedPhraseError: LocalizedError {
    case empty

    var errorDescription: String? {
        "Enter your seed phrase."
    }
}


let fixtures = [
    ("taggr-test-only-seed", "9a6e0a77607f916df171a390a22e2d766cdf6bae3f018e33fe02aeacda63f060"),
    ("  日本語 Seed 🔑  ", "b93b548230ec12a78512e2a10d0fc07e603e8a601dfc4868ca4d61f672973023"),
    ("é", "fb6e8cc5715e77484458c6cfc56b56ae1c6f696cf5a147fd4fdab4bf3e23298a"),
    ("é", "747ee6f75d1248e5b3148edf646db988ec10af2d091ee4ae9b7aa3060554f798"),
]
for (phrase, expected) in fixtures {
    let seed = try TaggrSeedPhrase.privateKey(from: phrase)
    precondition(seed.map { String(format: "%02x", $0) }.joined() == expected)
}
do {
    _ = try TaggrSeedPhrase.privateKey(from: "")
    fatalError("Empty input accepted")
} catch TaggrSeedPhraseError.empty {}
print("PASS: 4 Web-derived seed fixtures and empty-input rejection")
