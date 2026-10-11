package org.taggr.android.data

import java.net.URI
import java.util.Base64
import org.ic4j.agent.Agent
import org.ic4j.agent.android.ICClientConfiguration
import org.taggr.android.BuildConfig

/** Debug overrides never enter release builds. No intent can select a trust root. */
object TaggrRuntime {
    val domain: String
        get() = BuildConfig.TAGGR_DOMAIN

    val callback: URI
        get() = URI("https://${BuildConfig.TAGGR_CALLBACK_DOMAIN}/android-auth-callback")

    val localMediaOrigin: URI?
        get() =
            if (BuildConfig.DEBUG && URI(BuildConfig.TAGGR_API_BASE_URL).host == "localhost")
                URI(BuildConfig.TAGGR_API_BASE_URL)
            else null

    fun configuration() =
        ICClientConfiguration(
            canisterId = BuildConfig.TAGGR_CANISTER_ID,
            derivationOrigin = BuildConfig.TAGGR_DERIVATION_ORIGIN,
            apiBaseURL = URI(BuildConfig.TAGGR_API_BASE_URL),
            internetIdentityURL = URI(BuildConfig.TAGGR_II_URL),
            delegationLifetime = java.time.Duration.ofDays(30),
            rootKey =
                if (BuildConfig.DEBUG && BuildConfig.TAGGR_ROOT_KEY.isNotEmpty())
                    Base64.getDecoder().decode(BuildConfig.TAGGR_ROOT_KEY)
                else Agent.mainnetRootKey(),
        )
}
