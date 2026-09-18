import Foundation
import Observation
import SwiftUI

struct TaggrRealmCreationRequest: Equatable {
    let name: String
    let description: String
    let controllers: String
    let whitelist: String
    let labelColor: String
    let penalty: Int
    let maxDownvotes: Int
    let adult: Bool
    let filterComments: Bool
    let safe: Bool
    let age: Int
    let balance: Int
    let followers: Int
    let ownTheme: Bool
    let themeColors: [String: String]
}

@MainActor
@Observable
final class TaggrRealmCreationState {
    private(set) var request: TaggrRealmCreationRequest?
    private(set) var progress = TaggrRealmCreationProgress.editing
    private(set) var completedName: String?
    var busy = false
    var error: String?
    var createdName: String? { progress.createdName }
    var uncertain: Bool { progress == .uncertain }
    func prepare(_ request: TaggrRealmCreationRequest) {
        guard !busy, progress.canCreate else { return }
        self.request = request
    }
    private func resolve(_ text: String, context: TaggrFeatureContext, state: TaggrAppCoordinator) async throws -> [Int] {
        var ids = [Int]()
        for name in text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            guard let user = try await context.api.featureLookupUser(name) else {
                throw TaggrAPIError.rejected("User not found: \(name)")
            }
            try context.requireCurrent(state)
            if !ids.contains(user.id) { ids.append(user.id) }
        }
        return ids
    }
    func create(_ state: TaggrAppCoordinator) async {
        guard !busy, progress.canCreate, let request else { return }
        let name = request.name
        let description = request.description
        let controllers = request.controllers
        let whitelist = request.whitelist
        let labelColor = request.labelColor
        let penalty = request.penalty
        let maxDownvotes = request.maxDownvotes
        let adult = request.adult
        let filterComments = request.filterComments
        let safe = request.safe
        let age = request.age
        let balance = request.balance
        let followers = request.followers
        let ownTheme = request.ownTheme
        let themeColors = request.themeColors
        busy = true; error = nil
        let context = TaggrFeatureContext(state)
        defer { busy = false }
        var sent = false
        do {
            guard let identity = context.identity, let user = state.currentUser else { throw TaggrAPIError.missingIdentity }
            guard let maxName = state.cache?.config?.maxRealmName,
                  !name.isEmpty, name.utf8.count <= maxName,
                  !name.allSatisfy({ $0.isASCII && $0.isNumber }),
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                  !description.isEmpty, description.utf8.count <= 2000 else {
                throw TaggrAPIError.rejected("Check Realm name and description (maximum 2,000 bytes).")
            }
            guard [penalty, maxDownvotes, age, balance, followers].allSatisfy({ $0 >= 0 }),
                  penalty <= (state.cache?.config?.maxRealmCleanupPenalty ?? 0),
                  Color(hex: labelColor) != nil else { throw TaggrAPIError.rejected("Invalid limits or label color.") }
            guard !ownTheme || themeColors.values.allSatisfy({ Color(hex: $0) != nil }) else {
                throw TaggrAPIError.rejected("Theme colors must use #RRGGBB.")
            }
            let theme = ownTheme ? String(decoding: try JSONSerialization.data(withJSONObject: themeColors, options: .sortedKeys), as: UTF8.self) : ""
            guard (state.cache?.config?.realmCost ?? Int.max) <= (user.cycles ?? 0) else { throw TaggrAPIError.rejected("Insufficient credits.") }
            let existing = try await context.api.query("realms", args: [[name]], as: [TaggrRealm].self) ?? []
            guard existing.isEmpty else { throw TaggrAPIError.rejected("Realm name taken.") }
            let controllerIDs = try await resolve(controllers, context: context, state: state)
            let whitelistIDs = try await resolve(whitelist, context: context, state: state)
            guard !controllerIDs.isEmpty, whitelistIDs.count <= 100 else { throw TaggrAPIError.rejected("At least one Controller and at most 100 whitelist users are required.") }
            let realm = TaggrRealm(name: name, description: description, labelColor: labelColor, logo: nil,
                numMembers: 0, numPosts: 0, cleanupPenalty: penalty, controllers: controllerIDs,
                filter: TaggrRealmFilter(ageDays: age, safe: safe, balance: balance, numFollowers: followers),
                maxDownvotes: maxDownvotes, theme: theme, whitelist: whitelistIDs,
                adultContent: adult, commentsFiltering: filterComments, hasCompleteSettings: true)
            let payload = try realm.editPayload(description: description, labelColor: labelColor, logo: nil,
                cleanupPenalty: penalty, maxDownvotes: maxDownvotes, adultContent: adult, commentsFiltering: filterComments)
            try context.requireCurrent(state)
            sent = true
            try await context.api.createRealm(name: name, payload: payload, identity: identity)
            try context.requireCurrent(state)
            progress = .created(name)
        } catch {
            if context.matches(state) {
                self.error = error.localizedDescription
                if sent { if case TaggrAPIError.rejected = error {} else { progress = .uncertain } }
            }
        }
        if let createdName, context.matches(state) {
            busy = false
            await join(createdName, state: state)
        }
    }
    func reconcile(_ state: TaggrAppCoordinator) async {
        guard !busy, uncertain, let name = request?.name else { return }
        busy = true
        defer { busy = false }
        let context = TaggrFeatureContext(state)
        do {
            let realms = try await context.api.query("realms", args: [[name]], as: [TaggrRealm].self) ?? []
            try await context.refreshUser(state)
            if !realms.isEmpty, state.currentUser?.controlledRealms.contains(name) == true {
                progress = .created(name); error = nil
            } else { error = "Creation is not confirmed yet. Check again later." }
        } catch { if context.matches(state) { self.error = error.localizedDescription } }
    }
    func join(_ name: String, state: TaggrAppCoordinator) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let context = TaggrFeatureContext(state)
        do {
            try await context.refreshUser(state)
            if !state.isJoinedRealm(name) {
                guard let identity = context.identity else { throw TaggrAPIError.missingIdentity }
                try await context.api.setRealmMembership(name: name, joined: true, identity: identity)
            }
            try await context.refreshUser(state)
            await state.reloadCache()
            try context.requireCurrent(state)
            completedName = name
        } catch { if context.matches(state) { self.error = "Realm created; joining failed. " + error.localizedDescription } }
    }
}
