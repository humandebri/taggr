# Google OAuth registration for Android YouTube upload

This is prepared configuration, not a registered client or a successful sign-in.

-   Android package: `org.taggr.android`
-   Current Debug APK signing certificate SHA-1: `1E:DB:25:4C:37:8B:EF:BD:16:26:66:CB:3F:30:8E:05:86:FD:FF:D4`
-   Official dependency verified in Google Maven: `play-services-auth:22.0.0`
-   Release/Play signing certificate and Google Cloud project: not selected.

The Debug SHA-1 was read from the current APK with apksigner. Register production
using its actual distribution certificate; this Debug certificate is not a release
signing identity. Package/SHA-1 registration follows the
[Android authorization guide](https://developer.android.com/identity/authorization).

Enable YouTube Data API v3 in the selected project and configure the consent screen
with TAGGR's correct name, terms and privacy links. The implementation requests
YouTube upload/read access and account email. Verified email identifies the Google
account for refreshed authorization and explicit revoke; the selected YouTube
channel is independently checked against the saved job. No backend auth code or
refresh token is requested, and tokens are never stored in upload job metadata.

GoogleYouTubeAuth uses AuthorizationClient, returns a pending resolution to the
foreground caller, checks grants and uses the token for account/channel lookup.
Background callers must stop for required consent and let the UI present it.
AuthorizationResult parsing, grant rejection and request construction are tested
with scripted responses; actual Google consent, channel access, token refresh and
revoke have not been exercised with a real account.

The user has been asked for existing project/signing registration information.
The native composer now exposes authorization, metadata/video selection, persisted
uploads, platform background execution and completed-video insertion. Their
implementation and scoped verification are recorded in youtube-upload.md.
Real Google consent, upload, refresh and revoke remain unverified until the
package/signing registration and an authorized test account are available.
Do not interpret scripted SDK/HTTP checks as a real-account verification.

The verified account email is now retained inside the encrypted schema-2 upload
job to bind later authorization to the same account. Tokens are still memory-only;
legacy jobs require a validated foreground binding before background execution.
