# TAGGR browsing App Links

MainActivity receives HTTPS browsing URLs for the build's `TAGGR_DOMAIN`.
Both native paths such as `/post/42` and existing fragment URLs such as
`/#/post/42` select the corresponding native screen. The parser recognizes the
production domain and the configured build domain. It never changes the
canister, API endpoint, trust root, identity or callback from an intent.

Supported routes include post/thread conversations, user/journal profiles and
photos, Realms, hot/latest/personal/tag feeds, search, token transactions,
proposals, Inbox, bookmarks, invites and Account. Wallet/token/auction aliases
open Account as in Swift; they do not expose an auction or submit updates.
Incoming photo routes open a separate three-column, year-grouped library using
public `user_posts` paging. Its screen-owned pager skips image-free pages and
removes photos when overlapping pages report a source post as restricted.
Thumbnails and full-screen paging reuse the bounded image loader. The viewer
shows the date/source post and can open the conversation. Its sampled bitmap
supports 1–4× pinch zoom, 2.5× double-tap zoom/reset and bounded panning; horizontal
paging is disabled while the selected image is enlarged. Pinch preserves the
touched focal point; in-progress translation is retained while the displayed
image stays within its fitted bounds. Image sharing uses
an original-image cache file exposed only by the app's restricted FileProvider;
the actual OS chooser display/cancellation is verified both with a generated
image fixture and with a normal photo-library button using a live public image,
while external recipient delivery remains unverified. See
[photo-sharing-verification.md](photo-sharing-verification.md). Post thumbnails use the same
full-screen pager and zoom controls, including attachments omitted by the
four-thumbnail collapsed grid. Loaded-image taps are consumed; black-margin
taps close either viewer.

The Activity's original launch intent stays unchanged. New URLs go into a
SavedStateHandle queue, remain pending through account restoration or the terms
gate, and are cleared only after routing. Activity recreation restores the
current screen instead of submitting the original URL again. Authentication
callback paths are excluded from MainActivity's browsing intent filter and
parser.

## Public association

The manifest requests verification, but the production
`src/frontend/assets/.well-known/assetlinks.json` still contains `[]`. Browser
App Links are not publicly verified by the instrumentation tests. Android's
[App Links verification documentation](https://developer.android.com/training/app-links/verify-applinks)
describes the website association and certificate requirements.

A local debug-APK association candidate is in
`.build/android/browsing-links-debug-assetlinks.json`. Its public SHA-256
certificate fingerprint was extracted with `apksigner verify --print-certs`
from the built APK; no private signing key was exported. This candidate is not
a release association. The release artifact must use the actual distribution
signing certificate and be reviewed and published on the controlled domain
before verifying browser auto-opening. No production asset or deployment was
changed for this work.

## Verification

Pure JVM tests cover native/fragment routes, multi-tag and Unicode decoding,
malformed UTF-8/IDs, unexpected hosts/ports, credentials and authentication
callback rejection. Device tests use the real MainActivity and native public
queries, with guest-only session checks and restoration of any local terms
preference they changed. They cover initial URL launch, photo-tab selection,
merged-manifest browsing/callback matching, singleTop incoming URLs, search
state through Activity recreation and ignored unsupported/callback URLs.
These are package-targeted instrumentation intents, not proof of public domain
verification. No login, transfer or authenticated update is dispatched.
