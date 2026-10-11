package org.taggr.android.data

import kotlinx.coroutines.CancellationException

/** Confirm a reaction with a fresh read; never replay a possibly committed update. */
internal suspend fun submitPostReaction(
    postId: Long,
    viewerId: Long,
    reaction: Int,
    read: suspend () -> TaggrPost,
    send: suspend () -> Unit,
    checkOwner: () -> Unit,
) {
    require(postId >= 0 && viewerId >= 0 && reaction in 0..65535)
    checkOwner()
    val before = read()
    checkOwner()
    require(before.id == postId && before.restriction == null && before.canReact(viewerId)) {
        "You cannot react to this post. Refresh to check its current status."
    }
    var failure: Throwable? = null
    try {
        send()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
        failure = e
    }
    checkOwner()
    val after = read()
    checkOwner()
    if (after.id != postId || viewerId !in after.reactions[reaction].orEmpty()) {
        throw IllegalStateException(
            "Reaction is unconfirmed. Refresh the post before trying again.",
            failure,
        )
    }
}
