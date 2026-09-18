import SwiftUI

struct ProfileFollowButton: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let userID: Int

    var body: some View {
        if state.canInteractWithProfile(userID: userID) {
            let following = state.isFollowingUser(userID)
            Button {
                Task { await state.setFollowingUser(userID, following: !following) }
            } label: {
                Label(following ? "Unfollow" : "Follow", systemImage: following ? "person.badge.minus" : "person.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(TaggrTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TaggrTheme.clickable)
            .disabled(state.isBusy || state.contentStore.profileActionInFlight)
            .accessibilityIdentifier("profile.follow.\(userID)")
        }
    }
}
