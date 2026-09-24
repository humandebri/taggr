import SwiftUI
import ICNativeClient

struct SearchView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var term: String
    @State private var results: [TaggrSearchResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var principal: String?
    init(query: String = "") { _term = State(initialValue: query) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Search TAGGR", text: $term)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("taggr-search")
                Text("@NAME users · /REALM realms · #TAG tags\nCombine @NAME /REALM WORD to search posts. Enter a Principal for transactions.")
                    .font(.footnote).foregroundStyle(.secondary)
                FeatureStatus(loading: loading, error: error, retry: { Task { await search() } })
                if let principal {
                    TransactionsView(account: principal)
                } else {
                    ForEach(results, id: \.key) { result in
                        Button { open(result) } label: {
                            VStack(alignment: .leading) {
                                Text(result.result == "user" ? (state.authorNamesByUserID[result.id] ?? "User #\(result.id)") : "\(result.result.capitalized) \(result.genericId.isEmpty ? String(result.id) : result.genericId)").bold()
                                Text(result.relevant).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !loading && error == nil && term.count >= 2 && results.isEmpty { Text("No results.") }
                }
            }.padding()
        }
        .navigationTitle("Search")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Back") { state.returnFromFeature(fallback: .feed(state.effectiveHomeFeedMode)) } }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: TaggrNavigation.universalURL(for: .search(term)))
            }
        }
        .task(id: "\(state.safetyScope):\(state.runtimeGeneration):\(term)") { await search() }
    }
    private func search() async {
        let query = term
        let context = TaggrFeatureContext(state)
        results = []; principal = nil; error = nil; loading = false
        guard query.count >= 2 else { return }
        if (try? TaggrFeatureAccount(query)) != nil { principal = query; return }
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            let matches = try await context.api.search(query)
            try context.requireCurrent(state)
            guard query == term else { return }
            // Fetch post/realm metadata before exposing snippets that may be restricted.
            let postIDs = matches.filter { $0.result == "post" }.map(\.id)
            let posts = postIDs.isEmpty ? [] : try await state.loadPostEnvelopes("posts", args: [postIDs], identity: context.identity, api: context.api)
            let allowedPosts = Set(try await context.visiblePosts(posts, in: state).map(\.id))
            let realmNames = matches.filter { $0.result == "realm" }.map(\.genericId)
            var allowedRealms = Set<String>()
            for name in Set(realmNames) {
                let realms = try await context.api.query("realms", args: [[name]], as: [TaggrRealm].self) ?? []
                try context.requireCurrent(state)
                if let realm = realms.first, !realm.adultContent { allowedRealms.insert(name) }
            }
            try context.requireCurrent(state)
            guard query == term else { return }
            let names = try await state.loadAuthorNames(userIDs: matches.filter { $0.result == "user" }.map(\.id), generation: context.generation, api: context.api)
            try context.requireCurrent(state)
            guard query == term else { return }
            for (id, name) in names { state.cacheAuthorName(name, userID: id) }
            results = matches.filter {
                switch $0.result {
                case "user": !state.isUserRestricted($0.id)
                case "post": allowedPosts.contains($0.id)
                case "realm": allowedRealms.contains($0.genericId)
                case "tag": $0.relevant.lowercased() != "nsfw"
                default: false
                }
            }
            loading = false
        } catch is CancellationError {} catch {
            if context.matches(state), query == term { self.error = error.localizedDescription; loading = false }
        }
    }
    private func open(_ result: TaggrSearchResult) {
        let previous = state.navigationStore.featureReturnRoutes[state.route]
        state.route = .search(term)
        if let previous { state.navigationStore.featureReturnRoutes[state.route] = previous }
        switch result.result {
        case "user": state.navigateToProfile(String(result.id))
        case "post": state.navigateToPost(result.id)
        case "realm":
            state.navigationStore.featureReturnRoutes[.realm(result.genericId)] = state.route
            state.navigateToRealm(result.genericId)
        case "tag": state.navigate(to: .feed(.tags([result.relevant])))
        default: break
        }
    }
}

struct TransactionsView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let account: String
    @State private var entries: [TaggrTransactionEntry] = []
    @State private var user: TaggrUser?
    @State private var loading = false
    @State private var error: String?
    @State private var page = 0
    @State private var finished = false
    @State private var balance: UInt64?
    private var decimals: Int { state.cache?.config?.tokenDecimals ?? 0 }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            Text(account).font(.caption.monospaced()).textSelection(.enabled)
            if let user, !state.isUserRestricted(user.id) {
                Button(user.name) { state.navigateToProfile(String(user.id)) }
            }
            if let balance { Text("Balance: \(FeatureAmount.format(balance, decimals: decimals)) \(state.cache?.config?.tokenSymbol ?? "")") }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transaction #\(entry.id)").bold()
                    Text("From: \(entry.transaction.from.address)")
                    Text("To: \(entry.transaction.to.address)")
                    Text("Amount: \(FeatureAmount.format(entry.transaction.amount, decimals: decimals)) · Fee: \(FeatureAmount.format(entry.transaction.fee, decimals: decimals))")
                    Text(Date(timeIntervalSince1970: Double(entry.transaction.timestamp) / 1e9), style: .date)
                    if let memo = entry.transaction.memo { Text("Memo: \(Data(memo).icHexString)") }
                }.font(.footnote).textSelection(.enabled)
                Divider()
            }
            FeatureStatus(loading: loading, error: error, retry: { Task { await load() } })
            if !loading && error == nil && entries.isEmpty { Text("No transactions.") }
            if !finished && !loading { Button("Load more") { Task { await load() } } }
        }
        .task(id: "\(account):\(state.runtimeGeneration)") {
            entries = []; user = nil; balance = nil; page = 0; finished = false
            await load()
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        let context = TaggrFeatureContext(state)
        defer { loading = false }
        do {
            let decoded = try TaggrFeatureAccount(account)
            let owner = decoded.owner
            let sub = decoded.subaccount
            let rows = try await context.api.query("transactions", args: [page, owner, sub], as: [TaggrTransactionEntry].self) ?? []
            if page == 0 {
                let profile = try await context.api.featureLookupUser(owner)
                let rawBalance = try await context.api.featureTokenBalance(owner: owner, subaccount: sub)
                try context.requireCurrent(state)
                user = profile; balance = rawBalance
            }
            try context.requireCurrent(state)
            let existing = Set(entries.map(\.id))
            entries += rows.filter { !existing.contains($0.id) }
            finished = rows.isEmpty; page += 1
        } catch is CancellationError {} catch { if context.matches(state) { self.error = error.localizedDescription } }
    }
}
