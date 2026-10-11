package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.fasterxml.jackson.databind.JsonNode
import org.taggr.android.ui.safeLink

internal data class ProfileLink(val label: String, val url: String)

internal fun profileLinks(profile: JsonNode): List<ProfileLink> =
    profile
        .path("settings")
        .path("links")
        .takeIf { it.isTextual }
        ?.asText()
        ?.lines()
        ?.mapNotNull { line ->
            val parts = line.split(':', limit = 2).map { it.trim() }
            if (parts.size != 2 || parts[0].isEmpty() || !parts[1].startsWith("https://")) null
            else safeLink(parts[1])?.let { ProfileLink(parts[0], it) }
        }
        .orEmpty()

@Composable
internal fun ProfileDetails(profile: JsonNode, showLinks: Boolean = true) {
    val links =
        remember(profile, showLinks) { if (showLinks) profileLinks(profile) else emptyList() }
    val principal =
        profile.get("principal")?.takeIf { it.isTextual }?.asText()?.takeIf { it.isNotBlank() }
    val uriHandler = LocalUriHandler.current
    var failed by remember(profile) { mutableStateOf(false) }
    ProfileDetailsContent(links, principal, failed) { url ->
        failed = runCatching { uriHandler.openUri(url) }.isFailure
    }
}

@Composable
internal fun ProfileDetailsContent(
    links: List<ProfileLink>,
    principal: String?,
    failed: Boolean = false,
    open: (String) -> Unit,
) {
    if (links.isEmpty() && principal == null) return
    Surface(
        Modifier.fillMaxWidth().testTag("profile-details"),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (links.isNotEmpty()) {
                Text(
                    "Links",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                links.forEachIndexed { index, link ->
                    TextButton(
                        onClick = { open(link.url) },
                        contentPadding = PaddingValues(0.dp),
                        modifier = Modifier.testTag("profile-link-$index"),
                    ) {
                        Text(
                            link.label,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
            if (principal != null) {
                Text(
                    "Principal",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                SelectionContainer {
                    Text(
                        principal,
                        modifier = Modifier.testTag("profile-principal"),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
            if (failed) Text("Unable to open link.", color = MaterialTheme.colorScheme.error)
        }
    }
}
