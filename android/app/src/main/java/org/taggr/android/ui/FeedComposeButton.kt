package org.taggr.android.ui

import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.taggr.android.R

@Composable
internal fun FeedComposeButton(
    signedIn: Boolean,
    hasUser: Boolean,
    ready: Boolean,
    open: () -> Unit,
) {
    if (!signedIn) return
    FloatingActionButton(
        onClick = { if (ready) open() },
        modifier = Modifier.size(56.dp).semantics { if (!ready) disabled() },
        shape = CircleShape,
        containerColor = MaterialTheme.colorScheme.tertiary,
    ) {
        Icon(
            painterResource(if (hasUser) R.drawable.ic_compose else R.drawable.ic_create_user),
            if (hasUser) "Post" else "Create TAGGR user",
            Modifier.size(24.dp),
        )
    }
}
