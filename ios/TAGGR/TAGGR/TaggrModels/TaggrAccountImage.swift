// TAGGR/TaggrModels: Account image library items derived from posted media refs.
// Keeps the iOS photo review mode independent from feed state and backend wire changes.
import Foundation

struct TaggrAccountImage: Identifiable, Equatable {
    let postId: Int
    let timestamp: LosslessInt
    let attachment: TaggrPostImageAttachment
    let caption: String

    var id: String {
        attachment.id
    }

    var date: Date {
        Date(timeIntervalSince1970: Double(timestamp.value) / 1_000_000_000)
    }

    var year: Int {
        Calendar.current.component(.year, from: date)
    }

    static func images(from posts: [TaggrPost]) -> [TaggrAccountImage] {
        var seenImageIDs = Set<String>()
        return posts.flatMap { post in
            post.imageAttachments().compactMap { attachment in
                guard seenImageIDs.insert(attachment.id).inserted else { return nil }
                return TaggrAccountImage(
                    postId: post.id,
                    timestamp: post.timestamp,
                    attachment: attachment,
                    caption: post.displayBody
                )
            }
        }
    }

    static func yearGroups(from images: [TaggrAccountImage]) -> [TaggrAccountImageYearGroup] {
        Dictionary(grouping: images, by: \.year)
            .map { year, values in
                TaggrAccountImageYearGroup(
                    year: year,
                    images: values.sorted { lhs, rhs in
                        if lhs.timestamp == rhs.timestamp {
                            return lhs.postId > rhs.postId
                        }
                        return lhs.timestamp > rhs.timestamp
                    }
                )
            }
            .sorted { $0.year > $1.year }
    }
}

struct TaggrAccountImageYearGroup: Identifiable, Equatable {
    let year: Int
    let images: [TaggrAccountImage]

    var id: Int {
        year
    }
}

struct TaggrAccountImagePageResult: Equatable {
    let images: [TaggrAccountImage]
    let page: Int
    let pagingOffset: Int
    let reachedEnd: Bool
}

enum TaggrAccountImagePaging {
    static func append(
        posts: [TaggrPost],
        to images: [TaggrAccountImage],
        page: Int,
        pagingOffset: Int
    ) -> TaggrAccountImagePageResult {
        let nextPage = page + 1
        let nextOffset = page == 0 ? posts.first?.id ?? 0 : pagingOffset
        guard !posts.isEmpty else {
            return TaggrAccountImagePageResult(
                images: images,
                page: nextPage,
                pagingOffset: nextOffset,
                reachedEnd: true
            )
        }
        let existingIDs = Set(images.map(\.id))
        let newImages = TaggrAccountImage.images(from: posts).filter { !existingIDs.contains($0.id) }
        return TaggrAccountImagePageResult(
            images: images + newImages,
            page: nextPage,
            pagingOffset: nextOffset,
            reachedEnd: false
        )
    }

    static func shouldContinueLoading(
        previousImageCount: Int,
        result: TaggrAccountImagePageResult
    ) -> Bool {
        !result.reachedEnd && result.images.count == previousImageCount
    }
}
