import Foundation
import Observation

@MainActor
@Observable
final class TaggrProposalDetailState {
    struct Vote: Equatable {
        let proposalID: Int
        let postID: Int
        let adopted: Bool
        let data: String
    }

    let id: Int
    private(set) var proposal: TaggrProposal?
    private(set) var post: TaggrPost?
    private(set) var busy = false
    private(set) var pendingVote: Vote?
    var error: String?
    var data = ""
    var confirmation = false
    private(set) var uncertain = false
    private var requestID = UUID()
    private var active = true
    private var submitting = false

    init(id: Int) { self.id = id }

    func invalidate() {
        active = false
        requestID = UUID()
        pendingVote = nil; confirmation = false; data = ""
        proposal = nil; post = nil; error = nil; busy = false
    }

    func canVote(_ state: TaggrAppCoordinator, canonical: Bool) -> Bool {
        active && !busy && !uncertain && error == nil && post != nil &&
            proposal?.id == id && state.authSession != nil &&
            proposal?.canVote(userID: state.currentUser?.id, canonical: canonical) == true
    }

    func prepareVote(adopted: Bool, state: TaggrAppCoordinator, canonical: Bool) {
        guard canVote(state, canonical: canonical), let proposal else { return }
        do {
            let value = try proposal.voteData(adopted: adopted, input: data,
                decimals: state.cache?.config?.tokenDecimals ?? 0, maximum: state.cache?.config?.maxFundingAmount)
            pendingVote = Vote(proposalID: id, postID: proposal.postId, adopted: adopted, data: value)
            confirmation = true
        } catch { self.error = error.localizedDescription }
    }

    func load(_ state: TaggrAppCoordinator) async {
        guard !submitting else { return }
        active = true
        let request = UUID()
        requestID = request
        busy = true; error = nil; pendingVote = nil; confirmation = false
        proposal = nil; post = nil
        let context = TaggrFeatureContext(state)
        defer { if requestID == request { busy = false } }
        do {
            let value = try await context.api.proposal(id)
            guard value.id == id else { throw TaggrAPIError.invalidResponse("Proposal ID mismatch.") }
            let rows = try await state.loadPostEnvelopes("posts", args: [[value.postId]], identity: context.identity, api: context.api)
            let visible = try await context.visiblePosts(rows, in: state)
            try context.requireCurrent(state)
            guard active, requestID == request else { return }
            proposal = value; post = visible.first { $0.id == value.postId }; uncertain = false
            let names = try await state.loadAuthorNames(userIDs: value.bulletins.map(\.userID) + [value.proposer], generation: context.generation, api: context.api)
            try context.requireCurrent(state)
            guard active, requestID == request else { return }
            for (id, name) in names { state.cacheAuthorName(name, userID: id) }
        } catch {
            if active, requestID == request, context.matches(state), !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
    }

    func vote(_ state: TaggrAppCoordinator, canonical: Bool) async {
        guard canVote(state, canonical: canonical), let vote = pendingVote,
              vote.proposalID == id, vote.postID == proposal?.postId else { return }
        pendingVote = nil; confirmation = false
        busy = true; submitting = true; uncertain = true; error = nil
        let request = requestID
        let context = TaggrFeatureContext(state)
        defer { submitting = false; if active, requestID == request { busy = false } }
        var saved = false
        do {
            guard let identity = context.identity else { throw TaggrAPIError.missingIdentity }
            try context.requireCurrent(state)
            try await context.api.voteOnProposal(id: vote.proposalID, adopted: vote.adopted, data: vote.data, identity: identity)
            saved = true
            try context.requireCurrent(state)
            let updated = try await context.api.proposal(vote.proposalID)
            guard updated.id == vote.proposalID else { throw TaggrAPIError.invalidResponse("Proposal ID mismatch.") }
            let rows = try await state.loadPostEnvelopes("posts", args: [[vote.postID]], identity: identity, api: context.api)
            let visible = try await context.visiblePosts(rows, in: state)
            try context.requireCurrent(state)
            if active, requestID == request {
                proposal = updated; post = visible.first { $0.id == vote.postID }; uncertain = false
            }
            do {
                _ = try await context.api.toggleFollowingPost(postId: vote.postID, identity: identity)
                try await context.refreshUser(state)
            } catch {
                if active, requestID == request, context.matches(state) {
                    self.error = "Vote saved; discussion follow update failed: " + error.localizedDescription
                }
            }
        } catch {
            guard active, requestID == request, context.matches(state) else { return }
            self.error = (saved ? "Vote saved; refresh failed: " : "") + error.localizedDescription
            if case TaggrAPIError.rejected = error { uncertain = false }
            do {
                let updated = try await context.api.proposal(vote.proposalID)
                try context.requireCurrent(state)
                guard active, requestID == request, updated.id == id else { return }
                proposal = updated
                if !updated.canVote(userID: context.userID, canonical: canonical) { uncertain = false }
            } catch {}
        }
    }
}
