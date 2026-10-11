package org.taggr.android.ui

import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

@Composable
internal fun RootTabIcon(index: Int, unreadNotifications: Int) {
    if (index == 2 && unreadNotifications > 0) {
        BadgedBox(
            badge = {
                Badge(
                    Modifier.semantics {
                        contentDescription =
                            if (unreadNotifications == 1) "1 unread notification"
                            else "$unreadNotifications unread notifications"
                    }
                ) {
                    Text(unreadNotifications.toString())
                }
            }
        ) {
            TabIcon(index)
        }
    } else TabIcon(index)
}
