package org.taggr.android

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.taggr.android.data.RealmDetails
import org.taggr.android.data.RealmLogo
import org.taggr.android.ui.markdownText

@Composable
internal fun RealmDetailsCard(
    name: String,
    details: RealmDetails,
    names: Map<ULong, String>,
    openProfile: ((String) -> Unit)?,
) {
    val bitmap by
        produceState<android.graphics.Bitmap?>(null, details.logo) {
            value = null
            value = withContext(Dispatchers.Default) { RealmLogo.decode(details.logo) }
        }
    val color =
        remember(details.labelColor) {
            if (details.labelColor.matches(Regex("#[0-9A-Fa-f]{6}")))
                Color(android.graphics.Color.parseColor(details.labelColor))
            else Color(0xFFFFD700)
        }
    val luminance = color.luminance()
    val initialsColor =
        if ((luminance + 0.05f) / 0.05f >= 1.05f / (luminance + 0.05f)) Color.Black else Color.White
    Column(Modifier.testTag("realm-details"), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Surface(shape = RoundedCornerShape(8.dp)) {
            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(72.dp).clip(RoundedCornerShape(10.dp)).background(color),
                    contentAlignment = androidx.compose.ui.Alignment.Center,
                ) {
                    if (bitmap != null)
                        Image(
                            bitmap!!.asImageBitmap(),
                            "Realm logo",
                            Modifier.fillMaxSize(),
                            contentScale = ContentScale.Crop,
                        )
                    else
                        Text(
                            name
                                .filter { it.isLetterOrDigit() }
                                .take(2)
                                .uppercase()
                                .ifEmpty { "#" },
                            color = initialsColor,
                            fontWeight = FontWeight.Black,
                        )
                }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        name,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        "${details.members} members · ${details.posts} posts",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
        Surface(shape = RoundedCornerShape(8.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "About",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                SelectionContainer {
                    Text(remember(details.description) { markdownText(details.description) })
                }
                HorizontalDivider()
                Text("Cleanup penalty: ${details.penalty} credits")
                Text("Posting: ${details.posting}")
                Text("Comments: ${details.comments}")
                Text("Adult content: Not allowed")
                Text(
                    "Controllers",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (details.controllers.isEmpty()) Text("No controllers")
                for (chunk in details.controllers.chunked(3)) {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        for (id in chunk) {
                            val label = "@${names[id] ?: id.toString()}"
                            if (openProfile != null && id <= Long.MAX_VALUE.toULong())
                                TextButton(
                                    onClick = { openProfile(id.toString()) },
                                    modifier = Modifier.weight(1f).testTag("realm-controller-$id"),
                                ) {
                                    Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            else
                                SelectionContainer(Modifier.weight(1f)) {
                                    Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                        }
                    }
                }
            }
        }
    }
}
