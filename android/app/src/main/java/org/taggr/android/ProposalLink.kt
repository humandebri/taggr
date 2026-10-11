package org.taggr.android

import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import org.taggr.android.data.TaggrPost

@Composable
internal fun ProposalLink(post: TaggrPost, openProposal: ((Long) -> Unit)?) {
    val id = post.proposalId?.takeIf { it in 0..0xffff_ffffL } ?: return
    if (post.restriction != null || openProposal == null) return
    TextButton(onClick = { openProposal(id) }) { Text("Proposal #$id") }
}
