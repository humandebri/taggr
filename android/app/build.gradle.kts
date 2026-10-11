import java.net.URI

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "org.taggr.android"
    compileSdk {
        version = release(37) { minorApiLevel = 0 }
    }

    defaultConfig {
        applicationId = "org.taggr.android"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
    buildTypes {
        val defaults =
            mapOf(
                "CANISTER_ID" to "6qfxa-ryaaa-aaaai-qbhsq-cai",
                "DOMAIN" to "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
                "CALLBACK_DOMAIN" to "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
                "DERIVATION_ORIGIN" to "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
                "API_BASE_URL" to "https://ic0.app",
                "II_URL" to "https://id.ai/authorize",
                "ROOT_KEY" to "",
            )
        for (variant in listOf("debug", "release")) getByName(variant) {
            for ((key, fallback) in defaults) {
                val value =
                    if (variant == "debug")
                        providers.gradleProperty("TAGGR_$key").orElse(fallback).get()
                    else fallback
                require(!value.contains('"') && !value.contains('\\') && !value.contains('\n')) {
                    "Invalid TAGGR_$key"
                }
                buildConfigField("String", "TAGGR_$key", "\"$value\"")
                if (key == "DOMAIN") {
                    val origin = URI("https://$value")
                    require(origin.host != null && origin.userInfo == null && origin.path.isNullOrEmpty())
                    manifestPlaceholders["taggrLinkHost"] = origin.host
                    manifestPlaceholders["taggrAutoVerify"] = origin.host != "localhost"
                }
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        resources.excludes +=
            setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*")
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-jdk8:1.10.2")

    // IC4J provides the IC envelope, principal and certificate verification.
    // TAGGR's legacy query methods carry raw JSON rather than Candid arguments.
    implementation("org.ic4j:ic4j-agent-android:0.9.0-native-SNAPSHOT")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.21.1")
    runtimeOnly("org.slf4j:slf4j-nop:2.0.17")
    implementation("org.commonmark:commonmark:0.30.0")
    implementation("com.google.zxing:core:3.5.4")
    // On-device post translation; models are downloaded only on explicit use over Wi-Fi.
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:language-id:17.0.6")
    // Google API authorization is independent from TAGGR/Internet Identity sign-in.
    implementation("com.google.android.gms:play-services-auth:22.0.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    // Compose otherwise resolves 3.5.0, whose reflective InputManager fails on API 37.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
