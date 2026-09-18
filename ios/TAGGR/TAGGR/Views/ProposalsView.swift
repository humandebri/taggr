import SwiftUI

struct ProposalsView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var filter = "ALL"
    @State private var postIDs: [Int] = []
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?
    @State private var finished = false
    @State private var requestID = UUID()
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Picker("Proposal type", selection: $filter) {
                    ForEach(["ALL", "RELEASE", "FUNDING", "REWARDS", "REALM CONTROLLER", "ICP TRANSFER"], id: \.self) { Text($0).tag($0) }
                }
                FeaturePostList(postIDs: postIDs)
                FeatureStatus(loading: busy, error: error, retry: { Task { await load(reset: false) } })
                if !busy && postIDs.isEmpty && error == nil { Text("No proposals.") }
                if !busy && !finished { Button("Load more") { Task { await load(reset: false) } } }
            }.padding(.horizontal)
        }
        .navigationTitle("Proposals")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Back") { state.returnFromFeature(fallback: .settings) } } }
        .task(id: filter) { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard reset || !busy else { return }
        let request = UUID()
        requestID = request
        let selected = filter
        let context = TaggrFeatureContext(state)
        if reset {
            postIDs = []; page = 0; finished = false
            state.featurePosts.clearPosts(keepingOperations: true)
        }
        let listGeneration = state.featurePosts.listGeneration
        busy = true; error = nil
        do {
            let values = try await state.loadPostEnvelopes("proposals", args: [page, selected], identity: context.identity, api: context.api)
            let visible = try await context.visiblePosts(values, in: state)
            try context.requireCurrent(state)
            guard filter == selected, requestID == request, state.featurePosts.listGeneration == listGeneration else { return }
            let ids = Set(postIDs)
            state.featurePosts.register(visible)
            postIDs += visible.map(\.id).filter { !ids.contains($0) }
            page += 1; finished = values.isEmpty; busy = false
        } catch is CancellationError {} catch {
            if context.matches(state), selected == filter, requestID == request { self.error = error.localizedDescription; busy = false }
        }
    }
}

struct ProposalDetailView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let id: Int
    @State private var model: TaggrProposalDetailState
    init(id: Int) { self.id = id; _model = State(initialValue: TaggrProposalDetailState(id: id)) }
    private var proposal: TaggrProposal? { model.proposal }
    private var post: TaggrPost? { model.post }
    private var busy: Bool { model.busy }
    private var error: String? { model.error }
    private var uncertain: Bool { model.uncertain }
    private var decimals: Int { state.cache?.config?.tokenDecimals ?? 0 }
    private var canonical: Bool {
        state.runtimeConfig.apiBaseURL.scheme == "http" ||
            state.runtimeConfig.domain == "\(state.runtimeConfig.canisterId).icp0.io"
    }
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FeatureStatus(loading: busy, error: error, retry: { Task { await model.load(state) } })
                if let proposal, let post, state.canDisplayPost(post) {
                    Text("\(proposal.payload.title) · \(proposal.status.uppercased())").font(.headline)
                    Button("Proposer: \(state.authorNamesByUserID[proposal.proposer] ?? String(proposal.proposer))") {
                        state.navigateToProfile(String(proposal.proposer))
                    }
                    Text(Date(timeIntervalSince1970: Double(proposal.timestamp) / 1e9), style: .date)
                    TaggrMarkdownText(text: post.body)
                    Button("Open discussion") { state.navigateToPost(post.id) }
                    payloadView(proposal.payload)
                    Text("EFFECTIVE VOTING POWER: \(votingPower(proposal.votingPower))")
                    if let threshold = state.cache?.config?.proposalApprovalThreshold, let days = proposal.executionDays(threshold: threshold) {
                        Text("Execution deadline: \(days) DAYS")
                    }
                    ForEach([true, false], id: \.self) { accepted in
                        Text("\(accepted ? "ACCEPTED" : "REJECTED"): \(votingPower(proposal.power(adopted: accepted))) (\(proposal.percentage(adopted: accepted)))").bold()
                        ForEach(proposal.bulletins.filter { $0.adopted == accepted }, id: \.userID) { vote in
                            if !state.isUserRestricted(vote.userID) {
                                Button(state.authorNamesByUserID[vote.userID] ?? "User #\(vote.userID)") { state.navigateToProfile(String(vote.userID)) }
                            }
                        }
                    }
                    if model.canVote(state, canonical: canonical) {
                        if case .release = proposal.payload {
                            TextField("Reproducible build hash (required to accept)", text: $model.data).autocorrectionDisabled().textInputAutocapitalization(.never)
                        }
                        if case .rewards = proposal.payload {
                            TextField("Reward amount in tokens", text: $model.data).keyboardType(.decimalPad)
                            if let maximum = state.cache?.config?.maxFundingAmount { Text("Maximum: \(amount(UInt64(max(0, maximum))))") }
                        }
                        HStack {
                            Button("REJECT", role: .destructive) { model.prepareVote(adopted: false, state: state, canonical: canonical) }
                            Button("ACCEPT") { model.prepareVote(adopted: true, state: state, canonical: canonical) }
                        }.disabled(busy || uncertain)
                    } else if proposal.status == "Open", !canonical {
                        Text("Voting is unavailable on custom domains.")
                    } else if proposal.status == "Open", state.currentUser == nil {
                        Text("Sign in to vote.")
                    }
                    if uncertain { Text("Vote result is unknown. Reload before retrying.") }
                } else if !busy && error == nil { Text("Proposal unavailable.") }
            }.padding()
        }
        .navigationTitle("Proposal #\(id)")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Back") { state.returnFromFeature(fallback: .proposals) } } }
        .confirmationDialog(model.pendingVote?.adopted == true ? "Accept proposal?" : "Reject proposal?", isPresented: $model.confirmation, titleVisibility: .visible) {
            Button(model.pendingVote?.adopted == true ? "ACCEPT" : "REJECT") { Task { await model.vote(state, canonical: canonical) } }
        } message: { Text(model.pendingVote.map { "Proposal #\($0.proposalID) · \($0.data)" } ?? "Confirm your vote.") }
        .onDisappear { model.invalidate() }
        .task(id: id) { await model.load(state) }
        .refreshable { await model.load(state) }
    }
    private func amount(_ value: UInt64) -> String { FeatureAmount.format(value, decimals: decimals) }
    private func votingPower(_ value: UInt64) -> String { TaggrProposal.displayedPower(value, decimals: decimals).formatted() }
    @ViewBuilder private func payloadView(_ payload: TaggrProposal.Payload) -> some View {
        switch payload {
        case .release(let release):
            Text("Commit: \(release.commit)").textSelection(.enabled)
            if proposal?.status != "Open" { Text("Build hash: \(release.hash)").textSelection(.enabled) }
            if let url = URL(string: "https://github.com/TaggrNetwork/taggr/commit/\(release.commit)") { Link("Source commit", destination: url) }
        case .funding(let recipient, let quantity):
            Button("Recipient: \(recipient)") { state.navigate(to: .transactions(recipient)) }
            Text("Funding: \(amount(quantity))")
        case .rewards(let rewards):
            Button("Recipient: \(rewards.receiver)") { state.navigate(to: .transactions(rewards.receiver)) }
            if proposal?.status == "Executed" { Text("Minted: \(amount(rewards.minted))") }
        case .icpTransfer(let recipient, let e8s):
            Text("Recipient: \(Data(recipient).icHexString)").textSelection(.enabled)
            Text("ICP: \(FeatureAmount.format(e8s, decimals: 8))")
        case .realmController(let realm, let user):
            Button("Realm: /\(realm)") { state.navigateToRealm(realm) }
            Button("Controller: \(state.authorNamesByUserID[user] ?? String(user))") { state.navigateToProfile(String(user)) }
        case .unsupported: Text("UNSUPPORTED PROPOSAL TYPE")
        }
    }
}
