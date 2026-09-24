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
    var voteError: String?
    var data = ""
    private var requestID = UUID()
    private var submitting = false

    init(id: Int) { self.id = id }

    /// Invalidates in-flight reads when the screen goes away. The pending vote is
    /// deliberately kept: a confirmed vote is sent exactly like on the web app.
    func invalidate() { requestID = UUID() }

    func canVote(_ state: TaggrAppCoordinator, canonical: Bool) -> Bool {
        state.authSession != nil &&
            proposal?.canVote(userID: state.currentUser?.id, canonical: canonical) == true
    }

    /// Snapshots the vote input so the confirmation dialog always sends what the
    /// user saw, and reports validation failures instead of failing silently.
    @discardableResult
    func prepareVote(adopted: Bool, state: TaggrAppCoordinator, canonical: Bool) -> Bool {
        guard canVote(state, canonical: canonical), let proposal else { return false }
        do {
            let value = try proposal.voteData(adopted: adopted, input: data,
                decimals: state.cache?.config?.tokenDecimals ?? 0, maximum: state.cache?.config?.maxFundingAmount)
            pendingVote = Vote(proposalID: id, postID: proposal.postId, adopted: adopted, data: value)
            voteError = nil
            return true
        } catch {
            pendingVote = nil
            voteError = error.localizedDescription
            return false
        }
    }

    func load(_ state: TaggrAppCoordinator) async {
        guard !submitting else { return }
        let request = UUID()
        requestID = request
        busy = true; error = nil
        proposal = nil; post = nil
        let context = TaggrFeatureContext(state)
        defer { if requestID == request { busy = false } }
        do {
            let value = try await context.api.proposal(id)
            guard value.id == id else { throw TaggrAPIError.invalidResponse("Proposal ID mismatch.") }
            let rows = try await state.loadPostEnvelopes("posts", args: [[value.postId]], identity: context.identity, api: context.api)
            let visible = try await context.visiblePosts(rows, in: state)
            try context.requireCurrent(state)
            guard requestID == request else { return }
            proposal = value; post = visible.first { $0.id == value.postId }
            let names = try await state.loadAuthorNames(userIDs: value.bulletins.map(\.userID) + [value.proposer], generation: context.generation, api: context.api)
            try context.requireCurrent(state)
            guard requestID == request else { return }
            for (id, name) in names { state.cacheAuthorName(name, userID: id) }
        } catch {
            if requestID == request, context.matches(state), !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
    }

    func vote(_ state: TaggrAppCoordinator) async {
        guard let vote = pendingVote else { return }
        pendingVote = nil
        voteError = nil
        busy = true; submitting = true
        let request = requestID
        let context = TaggrFeatureContext(state)
        defer { submitting = false; busy = false }
        var saved = false
        do {
            guard let identity = context.identity else { throw TaggrAPIError.missingIdentity }
            try context.requireCurrent(state)
            try await context.api.voteOnProposal(id: vote.proposalID, adopted: vote.adopted, data: vote.data, identity: identity)
            saved = true
            try context.requireCurrent(state)
            // The PWA starts following the discussion immediately after a saved vote.
            // Keep this independent of the proposal refresh so a transient read failure
            // cannot leave a successful voter without discussion notifications.
            do {
                _ = try await context.api.toggleFollowingPost(postId: vote.postID, identity: identity)
                try await context.refreshUser(state)
            } catch {
                if requestID == request, context.matches(state) {
                    self.voteError = "Vote saved; discussion follow update failed: " + error.localizedDescription
                }
            }
            let updated = try await context.api.proposal(vote.proposalID)
            guard updated.id == vote.proposalID else { throw TaggrAPIError.invalidResponse("Proposal ID mismatch.") }
            let rows = try await state.loadPostEnvelopes("posts", args: [[vote.postID]], identity: identity, api: context.api)
            let visible = try await context.visiblePosts(rows, in: state)
            try context.requireCurrent(state)
            if requestID == request {
                proposal = updated; post = visible.first { $0.id == vote.postID }
            }
        } catch {
            guard requestID == request, context.matches(state) else { return }
            self.voteError = (saved ? "Vote saved; refresh failed: " : "") + error.localizedDescription
            do {
                let updated = try await context.api.proposal(vote.proposalID)
                try context.requireCurrent(state)
                guard requestID == request, updated.id == id else { return }
                self.proposal = updated
            } catch {}
        }
    }
}
