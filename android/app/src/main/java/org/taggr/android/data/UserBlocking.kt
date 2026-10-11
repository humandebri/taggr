package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import kotlinx.coroutines.CancellationException

internal data class UserBlockState(val id: Long, val blocked: Set<Long>) {
    companion object {
        fun decode(user: JsonNode): UserBlockState {
            val id = user.get("id")
            val blacklist = user.get("blacklist")
            require(
                id != null && id.isIntegralNumber && id.canConvertToLong() && id.longValue() >= 0
            ) {
                "Account unavailable"
            }
            require(
                blacklist != null &&
                    blacklist.isArray &&
                    blacklist.all {
                        it.isIntegralNumber && it.canConvertToLong() && it.longValue() >= 0
                    }
            ) {
                "Block status unavailable. Refresh your account."
            }
            return UserBlockState(id.longValue(), blacklist.map { it.longValue() }.toSet())
        }
    }
}

/** Read before toggling; an ambiguous reply is resolved by a read, never a second toggle. */
internal suspend fun synchronizeUserBlock(
    target: Long,
    selected: Boolean,
    read: suspend () -> JsonNode,
    toggle: suspend () -> Unit,
    checkOwner: () -> Unit,
): JsonNode {
    checkOwner()
    val beforeUser = read()
    val before = UserBlockState.decode(beforeUser)
    checkOwner()
    require(target >= 0 && target != before.id) { "Choose another user's profile." }
    if ((target in before.blocked) == selected) return beforeUser
    try {
        toggle()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        if (e !is Exception && e !is org.ic4j.agent.AgentError) throw e
        // Keep the local choice; the following read determines whether the toggle committed.
    }
    checkOwner()
    val after = read()
    checkOwner()
    val state = UserBlockState.decode(after)
    check(state.id == before.id && (target in state.blocked) == selected) {
        "Server block result is unconfirmed. Refresh your account before trying again."
    }
    return after
}
