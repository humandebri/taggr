package org.taggr.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.commonmark.node.*
import org.commonmark.parser.Parser
import org.taggr.android.AccountPhoto
import org.taggr.android.ImagePagerDialog
import org.taggr.android.data.TaggrPost

internal val LocalPostViewer = compositionLocalOf<Long?> { null }

private val parser = Parser.builder().build()

/** Render the parsed AST as Compose text; HTML is never executed. */
internal fun markdownText(text: String): AnnotatedString = buildAnnotatedString {
    var renderedTail: Char? = null
    val ordinals = mutableMapOf<OrderedList, Long>()
    fun appendVisible(value: String) {
        append(value)
        if (value.isNotEmpty()) renderedTail = value.last()
    }
    fun children(node: Node, visit: (Node) -> Unit) {
        var child = node.firstChild
        while (child != null) {
            visit(child)
            child = child.next
        }
    }
    fun render(node: Node, linkProse: Boolean = true) {
        when (node) {
            is org.commonmark.node.Text -> {
                if (linkProse) {
                    appendLinkedProse(node.literal, renderedTail)
                    if (node.literal.isNotEmpty()) renderedTail = node.literal.last()
                } else appendVisible(node.literal)
            }
            is SoftLineBreak,
            is HardLineBreak -> appendVisible("\n")
            is StrongEmphasis ->
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                    children(node) { render(it, linkProse) }
                }
            is Emphasis ->
                withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                    children(node) { render(it, linkProse) }
                }
            is Code ->
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
                    appendVisible(node.literal)
                }
            is FencedCodeBlock -> {
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
                    appendVisible(node.literal.trimEnd())
                }
                appendVisible("\n\n")
            }
            is IndentedCodeBlock -> {
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
                    appendVisible(node.literal.trimEnd())
                }
                appendVisible("\n\n")
            }
            is Heading -> {
                withStyle(
                    SpanStyle(fontWeight = FontWeight.Bold, fontSize = (24 - node.level).sp)
                ) {
                    children(node) { render(it, linkProse) }
                }
                appendVisible("\n\n")
            }
            is Link -> {
                val destination = safeLink(node.destination)
                if (destination == null) children(node) { render(it, false) }
                else
                    withLink(LinkAnnotation.Url(destination)) {
                        children(node) { render(it, false) }
                    }
            }
            is org.commonmark.node.Image -> Unit
            is org.commonmark.node.Paragraph -> {
                children(node) { render(it, linkProse) }
                val list = node.parent?.parent as? ListBlock
                appendVisible(
                    if (node.parent is ListItem && list?.isTight == true) "\n" else "\n\n"
                )
            }
            is ListBlock -> {
                children(node) { render(it, linkProse) }
                if (node.parent !is ListItem) appendVisible("\n")
            }
            is ListItem -> {
                val ordered = node.parent as? OrderedList
                if (ordered == null) appendVisible("• ")
                else {
                    val ordinal = ordinals[ordered] ?: (ordered.markerStartNumber ?: 1).toLong()
                    ordinals[ordered] = ordinal + 1
                    appendVisible("$ordinal. ")
                }
                children(node) { render(it, linkProse) }
            }
            is BlockQuote -> {
                appendVisible("› ")
                children(node) { render(it, linkProse) }
            }
            is ThematicBreak -> appendVisible("────────\n")
            is HtmlInline -> appendVisible(node.literal)
            is HtmlBlock -> appendVisible(node.literal)
            else -> children(node) { render(it, linkProse) }
        }
    }
    render(parser.parse(text.take(200_000)))
}
    .let {
        val start = it.text.length - it.text.trimStart('\n', '\r').length
        val end = it.text.trimEnd().length.coerceAtLeast(start)
        it.subSequence(start, end)
    }

internal fun safeLink(destination: String): String? =
    try {
        val url = URI(destination)
        when {
            url.scheme?.lowercase() in listOf("http", "https") &&
                !url.host.isNullOrEmpty() &&
                url.userInfo == null -> url.toString()
            url.scheme?.lowercase() == "mailto" -> url.toString()
            destination.startsWith("/#/") ->
                "https://${org.taggr.android.data.TaggrRuntime.domain}$destination"
            else -> null
        }
    } catch (_: Exception) {
        null
    }

internal fun postImageUrls(
    post: TaggrPost,
    text: String,
    localOrigin: java.net.URI? = org.taggr.android.data.TaggrRuntime.localMediaOrigin,
): List<String> {
    require(
        localOrigin == null ||
            (localOrigin.scheme == "https" &&
                localOrigin.host == "localhost" &&
                localOrigin.userInfo == null &&
                localOrigin.query == null &&
                localOrigin.fragment == null)
    )

    val destinations = mutableListOf<String>()
    parser
        .parse(text.take(200_000))
        .accept(
            object : AbstractVisitor() {
                override fun visit(image: org.commonmark.node.Image) {
                    destinations += image.destination
                }
            }
        )
    return destinations
        .mapNotNull { destination ->
            if (destination.startsWith("/blob/")) {
                val id = destination.removePrefix("/blob/")
                val file =
                    post.files.entries.firstOrNull { it.key.substringBefore('@') == id }
                        ?: return@mapNotNull null
                val bucket = file.key.substringAfter('@', "")
                if (bucket.isEmpty() || file.value.first < 0 || file.value.second <= 0)
                    return@mapNotNull null
                try {
                    org.ic4j.types.Principal.fromString(bucket)
                } catch (_: Exception) {
                    return@mapNotNull null
                }
                if (localOrigin != null)
                    localOrigin
                        .resolve(
                            "/image?canisterId=$bucket&offset=${file.value.first}&len=${file.value.second}"
                        )
                        .toString()
                else
                    "https://$bucket.raw.icp0.io/image?offset=${file.value.first}&len=${file.value.second}"
            } else safeLink(destination)?.takeIf { it.startsWith("https://") }
        }
        .distinct()
        .take(20)
}

@Composable
fun PostContent(post: TaggrPost, expanded: Boolean, showAuthorBadges: Boolean = true) {
    val viewer = LocalPostViewer.current
    var revealHidden by
        remember(post.id, viewer, post.hiddenFor, post.restriction) {
            mutableStateOf(false)
        }
    if (post.restriction != null) {
        Text(post.restriction, style = MaterialTheme.typography.bodyLarge)
        if (
            post.deleted &&
                post.restriction == "This post has been deleted." &&
                post.deletionHashes.isNotEmpty()
        ) {
            SelectionContainer {
                Text(
                    post.deletionHashes.joinToString("\n") { it.take(16) },
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("deleted-post-hashes-${post.id}"),
                )
            }
        }
    } else if (post.hiddenForViewer(viewer) && !revealHidden) {
        Column {
            Text("Hidden", style = MaterialTheme.typography.titleSmall)
            Text("You hid this post.", style = MaterialTheme.typography.bodyMedium)
            TextButton(onClick = { revealHidden = true }) { Text("Show") }
        }
    } else {
        VisiblePostContent(post, expanded, showAuthorBadges)
    }
}

@Composable
private fun VisiblePostContent(post: TaggrPost, expanded: Boolean, showAuthorBadges: Boolean) {
    if (showAuthorBadges) UserBadgeRow(post.authorBadges)
    val viewer = LocalPostViewer.current
    val contentKey =
        remember(post.id, post.body, viewer) {
            val bodyHash =
                android.util.Base64.encodeToString(
                    MessageDigest.getInstance("SHA-256")
                        .digest(post.body.toByteArray(Charsets.UTF_8)),
                    android.util.Base64.NO_WRAP,
                )
            "${post.id}:$viewer:$bodyHash"
        }
    // Saveable inputs reset live changes, but are not checked against restored state.
    // Store the content identity so restoration can validate it without saving the body.
    var expandedContentKey by rememberSaveable(contentKey) { mutableStateOf<String?>(null) }
    val full = expanded || expandedContentKey == contentKey
    val body = if (full) post.body else post.timelineBody
    var truncated by remember(body, full) { mutableStateOf(false) }
    val images = remember(body, post.files) { postImageUrls(post, body) }
    val blocks = remember(body) { org.taggr.android.data.PostBodyParser.blocks(body) }
    val hasVideo = blocks.any { it is org.taggr.android.data.PostBodyBlock.YouTube }
    val renderBlocks: @Composable () -> Unit = {
        blocks.forEachIndexed { index, block ->
            when (block) {
                is org.taggr.android.data.PostBodyBlock.Markdown ->
                    SelectionContainer {
                        Text(
                            remember(block.text) { markdownText(block.text) },
                            modifier = Modifier.testTag("post-body-${post.id}-$index"),
                            style = MaterialTheme.typography.bodyLarge,
                            maxLines = if (full || hasVideo) Int.MAX_VALUE else 10,
                            overflow = TextOverflow.Ellipsis,
                            onTextLayout = {
                                truncated = !full && !hasVideo && it.hasVisualOverflow
                            },
                        )
                    }
                is org.taggr.android.data.PostBodyBlock.YouTube ->
                    key(post.id, index, block.id) { YouTubePlayer(block) }
            }
        }
    }
    if (hasVideo) Column(verticalArrangement = Arrangement.spacedBy(16.dp)) { renderBlocks() }
    else renderBlocks()
    if (!full && (post.timelineBody != post.body || truncated))
        TextButton(
            onClick = { expandedContentKey = contentKey },
            modifier = Modifier.heightIn(min = 44.dp).testTag("show-full-post-${post.id}"),
            contentPadding = PaddingValues(horizontal = 0.dp, vertical = 4.dp),
        ) {
            Text(
                "Show full post",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
            )
        }
    post.repostId?.let { RepostSource(it) }
    if (post.poll != null)
        Column(Modifier.testTag("post-poll-${post.id}")) { org.taggr.android.PollCard(post) }
    else if (post.pollUnavailable)
        Text("Poll unavailable", style = MaterialTheme.typography.bodySmall)
    val visible = images.take(if (full) 20 else 4)
    var selected by remember(post.id, images) { mutableStateOf<String?>(null) }
    PostImageGrid(visible) { selected = it }
    val selectedIndex = images.indexOf(selected)
    if (selectedIndex >= 0)
        ImagePagerDialog(
            images.mapIndexed { index, url ->
                AccountPhoto(post.id, post.timestampMillis, url, post.body, index, post)
            },
            selectedIndex,
            { selected = null },
        )
    if (!full && images.size > 4)
        Text("${images.size} images", style = MaterialTheme.typography.labelSmall)
    InlinePostTranslation(post.id, body)
}

@Composable
private fun PostImageGrid(visible: List<String>, open: (String) -> Unit) {
    if (visible.size == 1) PostImage(visible.single(), open = { open(visible.single()) })
    else
        visible.chunked(2).forEach { pair ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                pair.forEach { url ->
                    Box(Modifier.weight(1f)) {
                        PostImage(
                            url,
                            Modifier.fillMaxWidth().aspectRatio(1f).clipToBounds(),
                            ContentScale.Crop,
                            open = { open(url) },
                        )
                    }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
}

internal object ImageLoader {
    val client = OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build()
    val cache =
        object : LruCache<String, Bitmap>(32 * 1024 * 1024) {
            override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
        }

    suspend fun load(url: String): Bitmap =
        withContext(Dispatchers.IO) {
            cache.get(url)?.let {
                return@withContext it
            }
            val bytes = download(url)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            check(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported image" }
            val options =
                BitmapFactory.Options().apply {
                    inSampleSize = 1
                    while (
                        bounds.outWidth / inSampleSize > 1600 ||
                            bounds.outHeight / inSampleSize > 1600
                    ) inSampleSize *= 2
                }
            val bitmap =
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                    ?: error("Unsupported image")
            cache.put(url, bitmap)
            bitmap
        }

    suspend fun download(url: String): ByteArray =
        withContext(Dispatchers.IO) {
            require(safeLink(url)?.startsWith("https://") == true)
            client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                check(response.isSuccessful) { "Image unavailable (${response.code})" }
                val body = response.body ?: error("Empty image")
                check(body.contentLength() <= 10 * 1024 * 1024) { "Image too large" }
                body.byteStream().use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        check(output.size() + count <= 10 * 1024 * 1024) { "Image too large" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
            }
        }
}

@Composable
private fun PostImage(
    url: String,
    layout: Modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
    scale: ContentScale = ContentScale.Fit,
    open: () -> Unit,
) {
    var bitmap by remember(url) { mutableStateOf<Bitmap?>(null) }
    var error by remember(url) { mutableStateOf<String?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    LaunchedEffect(url, revision) {
        error = null
        try {
            bitmap = ImageLoader.load(url)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        }
    }
    val image = bitmap
    when {
        image != null ->
            Image(
                image.asImageBitmap(),
                "Post image",
                modifier = layout.clickable(onClickLabel = "Open image", onClick = open),
                contentScale = scale,
            )
        error != null -> TextButton(onClick = { revision++ }) { Text("Image unavailable · Retry") }
        else -> LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}
