package org.taggr.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

/** Shared photo controls for post attachments and the account library. */
@Composable
internal fun ImagePagerDialog(
    photos: List<AccountPhoto>,
    initialIndex: Int,
    close: () -> Unit,
    image: @Composable (AccountPhoto, Modifier, (Boolean) -> Unit, () -> Unit) -> Unit =
        { photo, modifier, zoom, dismiss ->
            PhotoImage(photo, modifier, ContentScale.Fit, zoom, dismiss)
        },
    trailing: @Composable (AccountPhoto) -> Unit = {},
    footer: @Composable (AccountPhoto) -> Unit = {},
) {
    if (photos.isEmpty()) return
    val scope = rememberCoroutineScope()
    val pager =
        rememberPagerState(initialPage = initialIndex.coerceIn(photos.indices)) { photos.size }
    val photo = photos[pager.currentPage.coerceIn(photos.indices)]
    val zoomed = remember { mutableStateMapOf<String, Boolean>() }
    Dialog(
        onDismissRequest = close,
        properties =
            DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
            ),
    ) {
        Column(
            Modifier.fillMaxSize()
                .background(Color.Black)
                .safeDrawingPadding()
                .testTag("photo-viewer")
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = close) { Text("Close") }
                Text(
                    "${pager.currentPage + 1} of ${photos.size}",
                    Modifier.padding(16.dp),
                    color = Color.White,
                )
                trailing(photo)
            }
            HorizontalPager(
                pager,
                Modifier.fillMaxWidth().weight(1f),
                userScrollEnabled = zoomed[photo.id] != true,
            ) { page ->
                val item = photos[page]
                key(item.id) {
                    image(
                        item,
                        Modifier.fillMaxSize()
                            .testTag("viewer-photo-${item.postId}-${item.ordinal}"),
                        { zoomed[item.id] = it },
                        close,
                    )
                }
            }
            footer(photo)
            if (photos.size > 1)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(
                        onClick = {
                            scope.launch { pager.animateScrollToPage(pager.currentPage - 1) }
                        },
                        enabled = pager.currentPage > 0,
                    ) {
                        Text("Previous")
                    }
                    TextButton(
                        onClick = {
                            scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
                        },
                        enabled = pager.currentPage < photos.lastIndex,
                    ) {
                        Text("Next")
                    }
                }
        }
    }
}
