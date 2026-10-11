package org.taggr.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.fasterxml.jackson.databind.JsonNode
import java.math.BigInteger
import java.text.NumberFormat
import org.taggr.android.data.WalletAmounts

internal val LocalRealmOpen = staticCompositionLocalOf<((String) -> Unit)?> { null }

internal data class ProfileStatistic(
    val key: String,
    val label: String,
    val value: String,
    val users: ProfileUserList? = null,
    val realms: List<String> = emptyList(),
)

internal fun profileStatistics(profile: JsonNode, decimals: Int?): List<ProfileStatistic> {
    val format = NumberFormat.getIntegerInstance()
    val stats = mutableListOf<ProfileStatistic>()
    fun add(
        key: String,
        label: String,
        value: BigInteger?,
        users: ProfileUserList? = null,
        realms: List<String> = emptyList(),
    ) {
        if (value != null && value.signum() > 0)
            stats += ProfileStatistic(key, label, format.format(value), users, realms)
    }
    fun number(field: String) =
        profile
            .get(field)
            ?.takeIf { it.isIntegralNumber && it.bigIntegerValue().signum() >= 0 }
            ?.bigIntegerValue()
    fun ids(field: String) =
        profile
            .path(field)
            .takeIf { it.isArray }
            ?.filter { it.isIntegralNumber && it.canConvertToLong() && it.longValue() >= 0 }
            ?.map { it.longValue() }
            ?.distinct()
            .orEmpty()
    fun realms(field: String) =
        profile
            .path(field)
            .takeIf { it.isArray }
            ?.filter { it.isTextual && it.asText().isNotBlank() }
            ?.map { it.asText() }
            ?.distinct()
            .orEmpty()
    add("posts", "Posts", number("num_posts"))
    add(
        "follows",
        "Follows",
        ProfileUserList.Following.ids(profile).size.toBigInteger(),
        ProfileUserList.Following,
    )
    add(
        "followers",
        "Followers",
        ProfileUserList.Followers.ids(profile).size.toBigInteger(),
        ProfileUserList.Followers,
    )
    for ((key, label, field) in
        listOf(
            Triple("joined-realms", "Joined realms", "realms"),
            Triple("controls-realms", "Controls realms", "controlled_realms"),
        )) {
        val names = realms(field)
        add(key, label, names.size.toBigInteger(), realms = names)
    }
    add("bookmarks", "Bookmarks", ids("bookmarks").size.toBigInteger())
    val pins = runCatching {
        org.taggr.android.data.PinnedPosts.decode(profile.get("pinned_posts"))
    }.getOrNull()
    add("pinned", "Pinned", pins?.size?.toBigInteger())
    add("active-weeks", "Active weeks", number("active_weeks"))
    add("credits", "Credits", number("cycles"))
    number("balance")
        ?.takeIf { it.signum() > 0 }
        ?.let { balance ->
            if (decimals != null && decimals in 0..255) {
                val raw = WalletAmounts.token(balance, decimals)
                val whole = raw.substringBefore('.').toBigInteger()
                val fraction = raw.substringAfter('.', "")
                stats +=
                    ProfileStatistic(
                        "balance",
                        "Balance",
                        format.format(whole) + if (fraction.isEmpty()) "" else ".$fraction",
                    )
            }
        }
    return stats
}

@Composable
internal fun ProfileStatisticsGrid(
    stats: List<ProfileStatistic>,
    openUsers: (ProfileUserList) -> Unit,
    openRealms: (ProfileStatistic) -> Unit,
) {
    if (stats.isEmpty()) return
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = ((maxWidth + 8.dp) / 112.dp).toInt().coerceAtLeast(1)
        val width = (maxWidth - 8.dp * (columns - 1)) / columns
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            stats.forEach { stat ->
                val action: (() -> Unit)? =
                    when {
                        stat.users != null -> ({ openUsers(stat.users) })
                        stat.realms.isNotEmpty() -> ({ openRealms(stat) })
                        else -> null
                    }
                Surface(
                    modifier =
                        Modifier.width(width)
                            .heightIn(min = 96.dp)
                            .testTag("profile-stat-${stat.key}")
                            .semantics(mergeDescendants = true) {
                                contentDescription = "${stat.label}, ${stat.value}"
                            }
                            .then(
                                if (action != null) Modifier.clickable(onClick = action)
                                else Modifier
                            ),
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surface,
                ) {
                    Column(
                        Modifier.padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            stat.label.uppercase(),
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            stat.value,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Black,
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ProfileRealmsSheet(
    stat: ProfileStatistic,
    dismiss: () -> Unit,
    select: (String) -> Unit,
) {
    ModalBottomSheet(onDismissRequest = dismiss) {
        LazyColumn(
            Modifier.fillMaxWidth().testTag("profile-realm-list"),
            contentPadding = PaddingValues(16.dp),
        ) {
            item { Text(stat.label, style = MaterialTheme.typography.titleLarge) }
            item { TextButton(onClick = dismiss) { Text("Close") } }
            items(stat.realms, key = { it }) { name ->
                TextButton(
                    onClick = { select(name) },
                    modifier = Modifier.fillMaxWidth().testTag("profile-realm-$name"),
                ) {
                    Text("/$name")
                }
            }
        }
    }
}
