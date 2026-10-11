package org.taggr.android.data

import com.fasterxml.jackson.databind.JsonNode
import java.net.URI
import org.ic4j.types.Principal

data class ProfileDraft(
    val name: String,
    val about: String,
    val links: String,
    val mode: String,
    val governance: Boolean,
    val controllers: String,
) {
    val controllerIds
        get() = controllers.lines().map { it.trim() }.filter { it.isNotEmpty() }

    fun validate() {
        require(name.isNotBlank()) { "Name is required." }
        require(mode in listOf("Mining", "Rewards", "Credits")) { "Unknown usage mode." }
        controllerIds.forEach {
            try {
                Principal.fromString(it)
            } catch (e: org.ic4j.types.PrincipalError) {
                throw IllegalArgumentException("Invalid Controller Principal: $it", e)
            }
        }
        require(controllerIds.distinct().size == controllerIds.size) {
            "Duplicate Controller Principal."
        }
        links
            .lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .forEach { line ->
                val parts = line.split(": ", limit = 2)
                require(
                    parts.size == 2 &&
                        parts[0].trim().codePointCount(0, parts[0].trim().length) in 1..50
                ) {
                    "Use Label: https://example.com for each link."
                }
                val url =
                    try {
                        URI(parts[1].trim())
                    } catch (e: java.net.URISyntaxException) {
                        throw IllegalArgumentException("Links need a valid https:// URL.", e)
                    }
                require(
                    url.scheme == "https" && !url.host.isNullOrBlank() && url.userInfo == null
                ) {
                    "Links need a valid https:// URL."
                }
            }
    }

    fun profileChanged(user: JsonNode): Boolean {
        val old = from(user)
        return name != old.name ||
            about != old.about ||
            mode != old.mode ||
            governance != old.governance ||
            controllerIds != old.controllerIds
    }

    fun unsavedFields(user: JsonNode): List<String> {
        val old = from(user)
        return buildList {
            if (name != old.name) add("Name")
            if (about != old.about) add("About")
            if (links != old.links) add("Links")
            if (mode != old.mode) add("Usage mode")
            if (governance != old.governance) add("Governance")
            if (controllerIds != old.controllerIds) add("Controllers")
        }
    }

    fun updateArguments(user: JsonNode): List<Any> {
        validate()
        require(
            mode != "Credits" ||
                user.path("mode").asText() == "Credits" ||
                user.path("rewards").asLong() <= 0
        ) {
            "Receive pending rewards before switching to Credits."
        }
        val filter = user.path("filters").path("noise")
        require(filter.isObject && user.path("show_posts_in_realms").isBoolean) {
            "Account settings could not be loaded completely."
        }
        return listOf(
            if (name == user.path("name").asText()) "" else name,
            about,
            controllerIds,
            filter,
            governance,
            mode,
            user.path("show_posts_in_realms").asBoolean(),
        )
    }

    fun mergedSettings(user: JsonNode): Map<String, String> {
        val settings = user.path("settings")
        require(settings.isObject && settings.all { it.isTextual }) {
            "Account settings could not be loaded completely."
        }
        return settings.fields().asSequence().associate { it.key to it.value.asText() } +
            ("links" to links)
    }

    companion object {
        fun from(user: JsonNode) =
            ProfileDraft(
                user.path("name").asText(),
                user.path("about").asText(""),
                user.path("settings").path("links").asText(""),
                user.path("mode").asText("Mining"),
                user.path("governance").asBoolean(true),
                user.path("controllers").joinToString("\n") { it.asText() },
            )
    }
}
