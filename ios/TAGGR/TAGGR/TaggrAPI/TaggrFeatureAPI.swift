import Foundation
import ICNativeClient

extension TaggrAPI {
    func featureLookupUser(_ handle: String) async throws -> TaggrUser? {
        try await query("user", args: ["", [handle]], as: TaggrUser?.self) ?? nil
    }
    func search(_ term: String) async throws -> [TaggrSearchResult] {
        try await query("search", args: [domain, term], as: [TaggrSearchResult].self) ?? []
    }

    func featureUser(identity: ICAuthSession) async throws -> TaggrUser {
        guard let user = try await signedQuery("user", args: [domain, []], identity: identity, as: TaggrUser.self) else {
            throw TaggrAPIError.emptyResponse
        }
        return user
    }

    func updateProfile(_ draft: TaggrProfileDraft, preserving user: TaggrUser, identity: ICAuthSession) async throws {
        _ = try await updateJSON("update_user", args: [
            draft.name == user.name ? "" : draft.name, draft.about, draft.controllerIDs,
            user.filters.noise.jsonObject, draft.governance, draft.mode, user.showPostsInRealms,
        ], identity: identity)
    }

    func updateLinks(_ links: String, preserving settings: [String: String], identity: ICAuthSession) async throws {
        var merged = settings
        merged["links"] = links
        _ = try await updateJSON("update_user_settings", args: [merged], identity: identity)
    }

    func invites(identity: ICAuthSession) async throws -> [TaggrInviteEntry] {
        try await signedQuery("invites", args: [], identity: identity, as: [TaggrInviteEntry].self) ?? []
    }

    func createInvite(credits: Int, perUser: Int, realm: String, identity: ICAuthSession) async throws {
        _ = try await updateJSON("create_invite", args: [credits, perUser, realm.isEmpty ? nil : realm], identity: identity)
    }

    func updateInvite(code: String, credits: Int, realm: String, identity: ICAuthSession) async throws {
        _ = try await updateJSON("update_invite", args: [code, credits, realm.isEmpty ? nil : realm], identity: identity)
    }

    func createRealm(name: String, payload: sending [String: Any], identity: ICAuthSession) async throws {
        _ = try await updateJSON("create_realm", args: [name, payload], identity: identity)
    }

    func proposal(_ id: Int) async throws -> TaggrProposal {
        guard let result = try await query("proposal", args: [id], as: TaggrProposalReply.self) else {
            throw TaggrAPIError.emptyResponse
        }
        if let error = result.err { throw TaggrAPIError.rejected(error) }
        guard let proposal = result.ok else { throw TaggrAPIError.emptyResponse }
        return proposal
    }

    func voteOnProposal(id: Int, adopted: Bool, data: String, identity: ICAuthSession) async throws {
        _ = try await updateJSON("vote_on_proposal", args: [id, adopted, data], identity: identity)
    }
}
