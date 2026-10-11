package org.taggr.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import org.taggr.android.data.*

@Composable
internal fun TransactionsScreen(
    account: AccountViewModel,
    address: String,
    back: () -> Unit,
    openProfile: (String) -> Unit,
) {
    val identity by account.state.collectAsStateWithLifecycle()
    TransactionsContent(
        address,
        identity.principal ?: "guest",
        account.api::tokenTransactions,
        account.api::tokenAccountSummary,
        back,
        { owner ->
            account.api
                .jsonQuery("user", listOf("", listOf(owner)))
                .takeUnless { it.isNull }
                ?.takeIf { account.safety.allowedUser(it.path("id").asLong(-1)) }
        },
        openProfile,
    )
}

@Composable
internal fun TransactionsContent(
    address: String,
    scopeKey: String,
    loadPage: suspend (TokenAccount, Int) -> List<TokenTransaction>,
    loadSummary: suspend (TokenAccount) -> TokenAccountSummary,
    back: () -> Unit,
    loadProfile: suspend (String) -> com.fasterxml.jackson.databind.JsonNode? = { null },
    openProfile: (String) -> Unit = {},
) {
    BackHandler(onBack = back)
    val parsed = remember(address) { runCatching { TokenAccount.parse(address) } }
    val target = parsed.getOrNull()
    val scope = rememberCoroutineScope()
    val pageLoader by rememberUpdatedState(loadPage)
    val summaryLoader by rememberUpdatedState(loadSummary)
    val profileLoader by rememberUpdatedState(loadProfile)
    val pager =
        remember(address, scopeKey) {
            TransactionPager(scope) { page -> pageLoader(target ?: error("Invalid account"), page) }
        }
    val paging by pager.state.collectAsStateWithLifecycle()
    var summary by remember(address, scopeKey) { mutableStateOf<TokenAccountSummary?>(null) }
    var profile by
        remember(address, scopeKey) {
            mutableStateOf<com.fasterxml.jackson.databind.JsonNode?>(null)
        }
    var summaryError by remember(address, scopeKey) { mutableStateOf<String?>(null) }
    var revision by remember(address, scopeKey) { mutableIntStateOf(0) }
    DisposableEffect(pager) { onDispose { pager.close() } }
    LaunchedEffect(pager) { if (target != null) pager.refresh() }
    LaunchedEffect(target, scopeKey, revision) {
        if (target == null) return@LaunchedEffect
        summaryError = null
        try {
            summary = summaryLoader(target)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            summaryError = e.message ?: "Balance could not be loaded."
        }
        try {
            profile = profileLoader(target.owner)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            profile = null
        }
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { TextButton(onClick = back) { Text("Back") } }
        item { Text("Transactions", style = MaterialTheme.typography.headlineLarge) }
        item {
            SelectionContainer {
                Text(target?.address ?: address, fontFamily = FontFamily.Monospace)
            }
        }
        if (target == null)
            item {
                Text(
                    parsed.exceptionOrNull()?.message ?: "Invalid account.",
                    color = MaterialTheme.colorScheme.error,
                )
            }
        else {
            profile
                ?.takeIf {
                    it.path("id").isIntegralNumber &&
                        it.path("id").asLong(-1) >= 0 &&
                        it.path("name").isTextual
                }
                ?.let {
                    item {
                        TextButton(onClick = { openProfile(it["id"].asText()) }) {
                            Text("@${it["name"].asText()}")
                        }
                    }
                }
            summary?.let {
                item {
                    Text("Balance: ${WalletAmounts.token(it.balance, it.decimals)} ${it.symbol}")
                }
            }
            summaryError?.let {
                item {
                    Text(it, color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = { revision++ }) { Text("Retry balance") }
                }
            }
            item {
                TextButton(
                    onClick = {
                        pager.refresh()
                        revision++
                    },
                    enabled = !paging.loading,
                ) {
                    Text("Refresh transactions")
                }
            }
            items(paging.entries, key = { it.id }) { entry ->
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.medium,
                ) {
                    SelectionContainer {
                        Column(
                            Modifier.fillMaxWidth().padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                "Transaction #${entry.id}",
                                style = MaterialTheme.typography.titleMedium,
                            )
                            Text("From: ${entry.from.address}")
                            Text("To: ${entry.to.address}")
                            Text(
                                summary?.let {
                                    "Amount: ${WalletAmounts.token(java.math.BigInteger(entry.amount.toString()), it.decimals)} ${it.symbol} · Fee: ${WalletAmounts.token(java.math.BigInteger(entry.fee.toString()), it.decimals)}"
                                }
                                    ?: "Amount: ${entry.amount} base units · Fee: ${entry.fee} base units"
                            )
                            Text(
                                java.time.Instant.ofEpochSecond(
                                        (entry.timestamp / 1_000_000_000uL).toLong(),
                                        (entry.timestamp % 1_000_000_000uL).toLong(),
                                    )
                                    .atZone(java.time.ZoneId.systemDefault())
                                    .toLocalDate()
                                    .toString()
                            )
                            entry.memo?.let { Text("Memo: $it", fontFamily = FontFamily.Monospace) }
                        }
                    }
                }
            }
            if (paging.loading) item { CircularProgressIndicator() }
            paging.error?.let {
                item {
                    Text(it, color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = pager::loadMore) { Text("Retry transactions") }
                }
            }
            if (!paging.loading && paging.error == null && paging.entries.isEmpty())
                item { Text("No transactions.") }
            if (!paging.loading && paging.error == null && paging.hasMore)
                item { TextButton(onClick = pager::loadMore) { Text("Load more") } }
        }
    }
}
