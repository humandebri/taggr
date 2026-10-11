package org.taggr.android

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

enum class MarkdownAction(val label: String) {
    BOLD("Bold"),
    ITALIC("Italic"),
    LIST("Bullet list"),
    QUOTE("Quote"),
    LINK("Link"),
}

internal fun markdownEdit(
    value: TextFieldValue,
    action: MarkdownAction,
    url: String = "",
): TextFieldValue {
    val start = value.selection.min.coerceIn(0, value.text.length)
    val end = value.selection.max.coerceIn(start, value.text.length)
    val selected = value.text.substring(start, end)
    val replacement: String
    val selection: TextRange
    when (action) {
        MarkdownAction.BOLD,
        MarkdownAction.ITALIC -> {
            val marker = if (action == MarkdownAction.BOLD) "**" else "_"
            replacement = marker + selected + marker
            selection = TextRange(start + marker.length, end + marker.length)
        }
        MarkdownAction.LIST -> {
            replacement = selected.split('\n').joinToString("\n") { "- $it" }
            selection = TextRange(start + replacement.length)
        }
        MarkdownAction.QUOTE -> {
            replacement = "> $selected"
            selection = TextRange(start + replacement.length)
        }
        MarkdownAction.LINK -> {
            if (url.isEmpty()) return value
            replacement = "[$selected]($url)"
            selection = TextRange(start + if (selected.isEmpty()) 1 else replacement.length)
        }
    }
    return TextFieldValue(value.text.replaceRange(start, end, replacement), selection)
}

@Composable
internal fun MarkdownEditor(
    text: String,
    changed: (String) -> Unit,
    label: String,
    enabled: Boolean,
    selectionChanged: (TextRange) -> Unit = {},
    selectionRequest: TextRange? = null,
    consumeSelectionRequest: () -> Unit = {},
) {
    var value by
        rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(text)) }
    var linkSnapshot by remember { mutableStateOf<TextFieldValue?>(null) }
    var url by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(text, selectionRequest) {
        if (value.text != text || selectionRequest != null)
            value =
                TextFieldValue(
                    text,
                    TextRange(
                        (selectionRequest ?: value.selection).start.coerceIn(0, text.length),
                        (selectionRequest ?: value.selection).end.coerceIn(0, text.length),
                    ),
                )
        if (selectionRequest != null) consumeSelectionRequest()
    }
    SideEffect { selectionChanged(value.selection) }
    LaunchedEffect(enabled) {
        if (!enabled) {
            linkSnapshot = null
            url = ""
        }
    }
    fun apply(edit: TextFieldValue) {
        value = edit
        changed(edit.text)
        focus.requestFocus()
    }
    Column {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            for (action in MarkdownAction.entries) TextButton(
                enabled = enabled,
                onClick = {
                    if (action == MarkdownAction.LINK) {
                        linkSnapshot = value
                        url = ""
                    } else apply(markdownEdit(value, action))
                },
            ) {
                Text(action.label)
            }
        }
        OutlinedTextField(
            value,
            {
                value = it
                changed(it.text)
            },
            label = { Text(label) },
            modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp).focusRequester(focus),
            enabled = enabled,
        )
    }
    linkSnapshot?.let { snapshot ->
        AlertDialog(
            onDismissRequest = {
                linkSnapshot = null
                focus.requestFocus()
            },
            title = { Text("Link") },
            text = {
                OutlinedTextField(url, { url = it }, label = { Text("URL") }, singleLine = true)
            },
            confirmButton = {
                TextButton(
                    enabled = enabled && url.isNotEmpty() && text == snapshot.text,
                    onClick = {
                        if (enabled && text == snapshot.text)
                            apply(markdownEdit(snapshot, MarkdownAction.LINK, url))
                        linkSnapshot = null
                        url = ""
                    },
                ) {
                    Text("Insert")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        linkSnapshot = null
                        url = ""
                        focus.requestFocus()
                    }
                ) {
                    Text("Cancel")
                }
            },
        )
    }
}
