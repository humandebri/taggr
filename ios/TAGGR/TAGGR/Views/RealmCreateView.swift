import SwiftUI

struct RealmCreateView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var controllers = ""
    @State private var whitelist = ""
    @State private var labelColor = "#ffffff"
    @State private var penalty = 10
    @State private var maxDownvotes = 0
    @State private var adult = false
    @State private var filterComments = true
    @State private var safe = false
    @State private var age = 0
    @State private var balance = 0
    @State private var followers = 0
    @State private var ownTheme = false
    @State private var themeColors = ["text": "#e0e0c8", "background": "#1c3239", "code": "#ffffff", "clickable": "#30d5c8", "accent": "#ffc700"]
    @State private var model = TaggrRealmCreationState()
    @State private var confirmation = false
    private var busy: Bool { model.busy }
    private var error: String? { model.error }
    private var createdName: String? { model.createdName }
    private var uncertain: Bool { model.uncertain }

    var body: some View {
        NavigationStack {
            Form {
                if let createdName {
                    Text("/\(createdName) was created.")
                    Button("Join Realm") { Task { await model.join(createdName, state: state) } }.disabled(busy)
                    Button("Open Realm") { state.navigateToRealm(createdName); dismiss() }
                } else {
                    Group {
                    Section("Identity") {
                        TextField("Realm name", text: $name).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        TextField("Description", text: $description, axis: .vertical).lineLimit(4...10)
                        TaggrMarkdownText(text: description)
                        TextField("Label color (#RRGGBB)", text: $labelColor)
                        Text("Logo can be added after creation.").font(.footnote)
                    }
                    Section("Controllers and whitelist") {
                        TextField("Controllers (names or IDs, comma separated)", text: $controllers, axis: .vertical)
                        TextField("Whitelist (names or IDs, comma separated)", text: $whitelist, axis: .vertical)
                    }
                    Section("Moderation") {
                        Toggle("Adult content", isOn: $adult)
                        Toggle("Apply posting rules to comments", isOn: $filterComments)
                        TextField("Clean-up penalty", value: $penalty, format: .number).keyboardType(.numberPad)
                        TextField("Maximum downvotes", value: $maxDownvotes, format: .number).keyboardType(.numberPad)
                        Toggle("Safe users only", isOn: $safe)
                        TextField("Minimum account age (days)", value: $age, format: .number).keyboardType(.numberPad)
                        TextField("Minimum token balance (whole tokens)", value: $balance, format: .number).keyboardType(.numberPad)
                        TextField("Minimum followers", value: $followers, format: .number).keyboardType(.numberPad)
                    }
                    Section("Theme") {
                        Toggle("Use own theme", isOn: $ownTheme)
                        if ownTheme {
                            ForEach(["text", "background", "code", "clickable", "accent"], id: \.self) { key in
                                TextField(key.capitalized + " (#RRGGBB)", text: Binding(get: { themeColors[key] ?? "" }, set: { themeColors[key] = $0 }))
                                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                            }
                        }
                    }
                    }.disabled(busy || uncertain)
                    if let cost = state.cache?.config?.realmCost { Text("Creation costs \(cost) credits.") }
                    else { Button("Reload creation settings") { Task { await state.reloadCache() } } }
                }
                FeatureStatus(loading: busy, error: error)
                if uncertain {
                    Button("Check whether Realm was created") { Task { await model.reconcile(state) } }
                    Text("Creation result is unknown. Verify it before submitting again.").font(.footnote)
                }
            }
            .navigationTitle("Create Realm")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if createdName == nil {
                        Button("Create") {
                            model.prepare(TaggrRealmCreationRequest(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                                description: description,
                                controllers: controllers,
                                whitelist: whitelist,
                                labelColor: labelColor,
                                penalty: penalty,
                                maxDownvotes: maxDownvotes,
                                adult: adult,
                                filterComments: filterComments,
                                safe: safe,
                                age: age,
                                balance: balance,
                                followers: followers,
                                ownTheme: ownTheme,
                                themeColors: themeColors
                            ))
                            confirmation = true
                        }.disabled(busy || uncertain || state.cache?.config?.realmCost == nil)
                    }
                }
            }
            .confirmationDialog("Create Realm?", isPresented: $confirmation) {
                Button("Create for \(state.cache?.config?.realmCost ?? 0) credits") { Task { await model.create(state) } }
            }
            .interactiveDismissDisabled(busy)
            .onChange(of: model.completedName) { _, name in
                if let name { state.navigateToRealm(name); dismiss() }
            }
            .onAppear {
                controllers = state.currentUser.map { String($0.id) } ?? ""
                maxDownvotes = state.cache?.config?.defaultMaxDownvotes ?? 0
            }
        }
    }
}
