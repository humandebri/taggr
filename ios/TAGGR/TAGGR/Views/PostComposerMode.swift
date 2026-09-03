// TAGGR/Views: Identifies why the shared post composer is open so one UI can create, reply, or edit.

enum PostComposerMode {
    case newPost(selectedMode: TaggrFeedMode)
    case reply(parentPost: TaggrPost, selectedMode: TaggrFeedMode)
    case edit(post: TaggrPost, selectedMode: TaggrFeedMode)

    var submitTitle: String {
        switch self {
        case .newPost:
            return "Post"
        case .reply:
            return "Reply"
        case .edit:
            return "Save"
        }
    }

    var placeholder: String {
        switch self {
        case .newPost:
            return "What's happening?"
        case .reply:
            return "Write a reply"
        case .edit:
            return "Edit post"
        }
    }

    var initialText: String {
        guard case .edit(let post, _) = self else { return "" }
        return post.body
    }

    var selectedMode: TaggrFeedMode {
        switch self {
        case .newPost(let selectedMode),
             .reply(_, let selectedMode),
             .edit(_, let selectedMode):
            return selectedMode
        }
    }

    var timelineModeAfterSubmit: TaggrFeedMode {
        switch self {
        case .newPost(let selectedMode):
            return selectedMode
        case .reply(_, let selectedMode),
             .edit(_, let selectedMode):
            return selectedMode
        }
    }

    var targetRealm: String? {
        switch self {
        case .newPost(.realm(let name)):
            return name
        case .newPost:
            return nil
        case .reply(let parentPost, _):
            return parentPost.realm
        case .edit(let post, _):
            return post.realm
        }
    }

    var parentPostID: Int? {
        guard case .reply(let parentPost, _) = self else { return nil }
        return parentPost.id
    }

    var editingPost: TaggrPost? {
        guard case .edit(let post, _) = self else { return nil }
        return post
    }

    var allowsRealmSelection: Bool {
        switch self {
        case .newPost:
            return true
        case .edit(let post, _):
            return post.parent == nil
        case .reply:
            return false
        }
    }

    var draftContext: PostDraftContext {
        switch self {
        case .newPost:
            return .newPost
        case .reply(let parentPost, _):
            return .reply(parentPost.id)
        case .edit(let post, _):
            return .edit(post.id)
        }
    }
}
