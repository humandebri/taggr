package org.taggr.android.data

import android.content.Context
import android.util.AtomicFile
import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.util.Base64

/** Persist the request ID before dispatch, so recovery polls instead of reposting. */
data class PendingPost(
    val principal: String,
    val canister: String,
    val requestId: ByteArray,
    val method: String = "add_post",
    val postId: Long? = null,
    val draftSlot: String? = null,
) {
    init {
        require(requestId.size == 32)
        require(method in listOf("add_post", "edit_post", "delete_post"))
        require(method !in listOf("edit_post", "delete_post") || (postId != null && postId >= 0))
        require(method != "delete_post" || draftSlot == null)
        require(
            draftSlot == null ||
                draftSlot.matches(Regex("new|reply/[0-9]+|edit/[0-9]+|repost/[0-9]+"))
        )
    }
}

class PendingPostStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "taggr-pending-post.json"))
    private val mapper = ObjectMapper()

    fun save(post: PendingPost) {
        val bytes =
            mapper.writeValueAsBytes(
                mapOf(
                    "principal" to post.principal,
                    "canister" to post.canister,
                    "requestId" to Base64.getEncoder().encodeToString(post.requestId),
                    "method" to post.method,
                    "postId" to post.postId,
                    "draftSlot" to post.draftSlot,
                )
            )
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (e: Exception) {
            file.failWrite(stream)
            throw e
        }
    }

    fun load(principal: String, canister: String): PendingPost? {
        if (!file.baseFile.exists()) return null
        check(file.baseFile.length() < 4096) { "Invalid pending post" }
        val value = mapper.readTree(file.readFully())
        require(
            value.path("principal").asText() == principal &&
                value.path("canister").asText() == canister
        ) {
            "Pending post belongs to a different account"
        }
        val id = Base64.getDecoder().decode(value.required("requestId").asText())
        require(id.size == 32)
        return PendingPost(
            principal,
            canister,
            id,
            value.path("method").asText("add_post"),
            value["postId"]?.takeIf { it.isIntegralNumber }?.asLong(),
            value["draftSlot"]?.takeIf { it.isTextual }?.asText(),
        )
    }

    fun clear() {
        file.delete()
    }
}

class PostRejectedException(message: String) : Exception(message)
