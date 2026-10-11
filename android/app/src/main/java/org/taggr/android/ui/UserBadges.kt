package org.taggr.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fasterxml.jackson.databind.JsonNode
import java.math.BigInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.taggr.android.AccountViewModel
import org.taggr.android.data.UserBadge

@Composable
internal fun UserBadgeRow(badges: List<UserBadge>) {
    if (badges.isEmpty()) return
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        badges.forEach { badge ->
            val background =
                when (badge) {
                    UserBadge.Bot -> Color(0xFF4169E1)
                    UserBadge.Og -> Color(0xFFDB7093)
                    UserBadge.Stalwart -> Color(0xFFFA8072)
                    UserBadge.Frequenter -> Color(0xFF6A5ACD)
                    UserBadge.FollowsYou -> Color(0xFF2E8B57)
                    UserBadge.Inactive -> Color.White
                }
            val foreground =
                if (badge in listOf(UserBadge.Bot, UserBadge.Frequenter, UserBadge.FollowsYou))
                    Color.White
                else Color.Black
            Text(
                badge.label,
                Modifier.background(background, RoundedCornerShape(4.dp))
                    .padding(horizontal = 6.dp, vertical = 3.dp)
                    .semantics { contentDescription = badge.accessibilityLabel },
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = foreground,
            )
        }
    }
}

@Composable
internal fun ProfileUserBadges(account: AccountViewModel, user: JsonNode) {
    val state by account.state.collectAsStateWithLifecycle()
    var weeks by remember(account, state.principal) { mutableStateOf<BigInteger?>(null) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(account, state.principal) {
        try {
            weeks =
                UserBadge.unsigned(
                    account.api.jsonQuery("config").path("voting_power_activity_weeks")
                )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            weeks = null
        }
    }
    LaunchedEffect(user) {
        while (isActive) {
            now = System.currentTimeMillis()
            delay(60000)
        }
    }
    UserBadgeRow(
        UserBadge.profile(
            user,
            state.user
                ?.path("id")
                ?.takeIf { it.isIntegralNumber && it.canConvertToLong() }
                ?.asLong(),
            weeks,
            now,
        )
    )
}
