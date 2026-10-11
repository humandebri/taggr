package org.taggr.android

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.taggr.android.data.TokenTransaction

data class TransactionPageState(
    val entries: List<TokenTransaction> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val hasMore: Boolean = true,
)

internal class TransactionPager(
    private val scope: CoroutineScope,
    private val load: suspend (Int) -> List<TokenTransaction>,
) : AutoCloseable {
    private val mutable = MutableStateFlow(TransactionPageState())
    val state = mutable.asStateFlow()
    private var page = 0
    private var generation = 0
    private var job: Job? = null
    private var closed = false

    fun refresh() {
        if (closed) return
        generation++
        job?.cancel()
        page = 0
        mutable.value = TransactionPageState()
        loadMore()
    }

    fun loadMore() {
        val before = mutable.value
        if (closed || before.loading || !before.hasMore) return
        val version = generation
        mutable.value = before.copy(loading = true, error = null)
        job = scope.launch {
            try {
                val rows = load(page)
                if (closed || version != generation) return@launch
                page++
                mutable.value =
                    TransactionPageState(
                        (before.entries + rows).distinctBy { it.id },
                        hasMore = rows.isNotEmpty(),
                    )
            } catch (_: TimeoutCancellationException) {
                if (!closed && version == generation)
                    mutable.value = before.copy(error = "Loading timed out. Try again.")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!closed && version == generation)
                    mutable.value =
                        before.copy(error = e.message ?: "Transactions could not be loaded.")
            }
        }
    }

    override fun close() {
        closed = true
        generation++
        job?.cancel()
    }
}
