#!/usr/bin/env node
const fs = require("fs");

const required = [
    "ios/TAGGR/TAGGR.xcodeproj/project.pbxproj",
    "ios/TAGGR/TAGGR/TAGGRApp.swift",
    "ios/TAGGR/TAGGR/AppState.swift",
    "ios/TAGGR/TAGGR/AppActions.swift",
    "ios/TAGGR/TAGGR/AppStores.swift",
    "ios/TAGGR/TAGGR/TaggrRuntimeConfig.swift",
    "ios/TAGGR/TAGGR/TaggrAPI/TaggrAPI.swift",
    "ios/TAGGR/TAGGR/TaggrAPI/CandidEncoder.swift",
    "ios/TAGGR/TAGGR/TaggrNavigation/TaggrNavigation.swift",
    "ios/TAGGR/TAGGR/Views/InboxView.swift",
    "ios/TAGGR/TAGGR/Views/PostDetailViews.swift",
    "ios/TAGGR/TAGGR/Views/RealmViews.swift",
    "ios/TAGGR/TAGGR/Views/SharedViews.swift",
    "ios/TAGGR/TAGGR/Views/UserImageLibraryView.swift",
    "ios/TAGGR/TAGGR/Views/AccountImagePagerView.swift",
    "ios/TAGGR/TAGGR/Views/AvatarSettingsViews.swift",
    "ios/TAGGR/TAGGR/TaggrModels/TaggrAccountImage.swift",
    "ios/TAGGR/TAGGR/TAGGR.entitlements",
];

const read = (path) => fs.readFileSync(path, "utf8");
const swiftFiles = (dir) =>
    fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
        const path = `${dir}/${entry.name}`;
        if (entry.isDirectory()) return swiftFiles(path);
        return path.endsWith(".swift") ? [path] : [];
    });
const missing = required.filter((path) => !fs.existsSync(path));
const failures = [];

if (missing.length) failures.push(`missing files: ${missing.join(", ")}`);
if (fs.existsSync("src-tauri")) failures.push("src-tauri must be removed");

const project = read("ios/TAGGR/TAGGR.xcodeproj/project.pbxproj");
if (!project.includes("PRODUCT_BUNDLE_IDENTIFIER = network.taggr.ios")) {
    failures.push("Swift app bundle id must be network.taggr.ios");
}
if (!project.includes("IPHONEOS_DEPLOYMENT_TARGET = 17.4")) {
    failures.push("Swift app deployment target must be iOS 17.4 or newer");
}

const entitlements = read("ios/TAGGR/TAGGR/TAGGR.entitlements");
if (!entitlements.includes("applinks:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io")) {
    failures.push(
        "Associated Domains entitlement is missing canonical TAGGR applinks host",
    );
}
if (
    !entitlements.includes("webcredentials:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io")
) {
    failures.push(
        "Associated Domains entitlement is missing canonical TAGGR webcredentials host",
    );
}

const api = read("ios/TAGGR/TAGGR/TaggrAPI/TaggrAPI.swift");
const stagingDeviceBuild = read("ios/scripts/staging-device-build.js");
const swiftSources = swiftFiles("ios/TAGGR/TAGGR").map(read).join("\n");
const appState = [
    read("ios/TAGGR/TAGGR/AppState.swift"),
    read("ios/TAGGR/TAGGR/AppActions.swift"),
].join("\n");
const runtimeConfig = read("ios/TAGGR/TAGGR/TaggrRuntimeConfig.swift");
for (const obsolete of [
    "WKWebView",
    "WebKit",
    "IdentityWebView",
    "WKScriptMessageHandler",
]) {
    if (swiftSources.includes(obsolete) || project.includes(obsolete)) {
        failures.push(`obsolete WebView implementation remains: ${obsolete}`);
    }
}
if (swiftSources.includes("isValidSignature")) {
    failures.push(
        "native runtime must not perform local Internet Identity delegation signature verification",
    );
}
if (
    !appState.includes("import AuthenticationServices") ||
    !appState.includes("import ICNativeClient") ||
    !appState.includes("ICInternetIdentityAuthenticator(") ||
    !appState.includes("ICIdentityStore(") ||
    !appState.includes("service: TaggrAppCoordinator.identityStoreService") ||
    !runtimeConfig.includes(
        'productionIdentityURL = URL(string: "https://id.ai/authorize")!',
    ) ||
    !runtimeConfig.includes("productionDerivationOrigin")
) {
    failures.push(
        "native Internet Identity auth must use ICNativeClient with ASWebAuthenticationSession and production derivation origin",
    );
}
if (
    !stagingDeviceBuild.includes(
        "const callbackDomain = `${canisterId}.icp0.io`;",
    ) ||
    !stagingDeviceBuild.includes("`TAGGR_CALLBACK_DOMAIN=${callbackDomain}`") ||
    !stagingDeviceBuild.includes("`applinks:${callbackDomain}`") ||
    !stagingDeviceBuild.includes("`webcredentials:${callbackDomain}`") ||
    !stagingDeviceBuild.includes(
        "`Callback: https://${callbackDomain}/ios-auth-callback`",
    )
) {
    failures.push(
        "staging device builds must use the canister icp0.io host for the ICRC-167 callback",
    );
}

const rootView = read("ios/TAGGR/TAGGR/Views/RootView.swift");
const navigation = read(
    "ios/TAGGR/TAGGR/TaggrNavigation/TaggrNavigation.swift",
);
const profileViews = read("ios/TAGGR/TAGGR/Views/ProfileViews.swift");
const settingsViews = read("ios/TAGGR/TAGGR/Views/AuthSettingsViews.swift");
const models = read("ios/TAGGR/TAGGR/TaggrModels/TaggrModels.swift");
const accountImages = read(
    "ios/TAGGR/TAGGR/TaggrModels/TaggrAccountImage.swift",
);
const feedViews = [
    read("ios/TAGGR/TAGGR/Views/FeedViews.swift"),
    read("ios/TAGGR/TAGGR/Views/PostInteractionViews.swift"),
    read("ios/TAGGR/TAGGR/Views/RealmListViews.swift"),
].join("\n");
const userImageLibrary = read(
    "ios/TAGGR/TAGGR/Views/UserImageLibraryView.swift",
);
const accountImagePager = read(
    "ios/TAGGR/TAGGR/Views/AccountImagePagerView.swift",
);
const avatarSettingsViews = read(
    "ios/TAGGR/TAGGR/Views/AvatarSettingsViews.swift",
);
const viewSources = swiftFiles("ios/TAGGR/TAGGR/Views").map(read).join("\n");
if (/Task\s*\{\s*await state\.loadPost\(/.test(viewSources)) {
    failures.push(
        "post navigation must load through the destination route task, not an unstructured View task",
    );
}
if (profileViews.includes("state.loadProfile(")) {
    failures.push(
        "profile data must load through the root route task, not ProfileView",
    );
}
if (
    !rootView.includes("ProfileView()") ||
    !profileViews.includes("struct ProfileView")
) {
    failures.push("native profile route must render ProfileView");
}
if (
    !navigation.includes(
        'case "transaction", "transactions", "tokens", "wallet", "auction":',
    ) ||
    !navigation.includes("return .settings") ||
    !settingsViews.includes('Label("Send ICP"') ||
    !settingsViews.includes('Label("Mint 1k credits"') ||
    !appState.includes("func sendICP") ||
    !api.includes("func transferICP")
) {
    failures.push(
        "native token and wallet routes must open Account with ICP transfer and credit minting enabled",
    );
}
if (
    !profileViews.includes("toggleBlock(userId:") ||
    !profileViews.includes("ReportUserSheet")
) {
    failures.push("native profile route must expose block and report controls");
}
if (
    !appState.includes("func report(userId:") ||
    !feedViews.includes("state.report(userId: post.user") ||
    !profileViews.includes("state.report(userId: user.id")
) {
    failures.push(
        "native report controls must call the backend report API with a user id",
    );
}
if (
    !settingsViews.includes("createUser(name:") ||
    !api.includes("func createUser")
) {
    failures.push("native settings route must expose TAGGR user creation");
}
if (
    !rootView.includes("InboxView()") ||
    !rootView.includes(".badge(state.unreadNotificationCount)") ||
    !models.includes("TaggrNotificationEntry") ||
    !appState.includes("markNotificationsRead")
) {
    failures.push("native inbox route and notification model must be present");
}
if (
    !rootView.includes("PostDetailView()") ||
    !rootView.includes("RealmDetailView(realmName:") ||
    !appState.includes("navigateToPost") ||
    !appState.includes("navigateToRealm")
) {
    failures.push("native post and realm detail routes must be present");
}
if (
    !swiftSources.includes("PhotosPicker") ||
    !api.includes("func bucketWrite") ||
    !models.includes("let bucket: String?")
) {
    failures.push("native image posting must use personal media bucket refs");
}
if (
    !settingsViews.includes('Label("Photos"') ||
    !profileViews.includes('Label("Photos"') ||
    !rootView.includes("UserImageLibraryView(") ||
    !appState.includes("func loadUserPosts") ||
    !accountImages.includes("struct TaggrAccountImage") ||
    !userImageLibrary.includes("TaggrAccountImage.yearGroups") ||
    !userImageLibrary.includes("loadUserPosts(") ||
    !userImageLibrary.includes("handle: handle") ||
    !accountImagePager.includes("ShareLink")
) {
    failures.push(
        "native user photo review mode must expose profile/account entry points and a year-grouped ShareLink image browser",
    );
}
if (
    !profileViews.includes("profileStats") ||
    !profileViews.includes("profileLinks") ||
    !models.includes("let deactivated: Bool?")
) {
    failures.push("native profile details and stats must be present");
}
if (
    !settingsViews.includes("AccountAvatarSettingsPanel") ||
    !avatarSettingsViews.includes('TextField("https://example.com/icon.jpg"') ||
    !avatarSettingsViews.includes("AvatarImagePickerSheet") ||
    !avatarSettingsViews.includes("updateCurrentUserAvatarURL") ||
    !appState.includes('updateJSON("update_user_settings"') ||
    !models.includes('static let settingKey = "avatar_url"') ||
    !models.includes("let authorAvatarURL: String?") ||
    !feedViews.includes("AsyncImage(url: avatarURL)") ||
    feedViews.includes("initials(for:")
) {
    failures.push(
        "native avatar icons must use avatar_url settings, posted-image selection, update_user_settings, and image-based AvatarView without text initials",
    );
}
if (
    !appState.includes("authorProfilesByUserID") ||
    !appState.includes("loadingAuthorProfileIDs") ||
    !appState.includes("authorProfileRetryAfter") ||
    !appState.includes('api.query("users_data"') ||
    !appState.includes("func prefetchAuthorProfile") ||
    !feedViews.includes("state.avatarURLString(for: post)") ||
    !feedViews.includes("state.prefetchAuthorProfile(for: post)")
) {
    failures.push(
        "native feed avatars must resolve author profiles with an iOS-only in-memory cache instead of relying on post meta avatar fields",
    );
}

const packageJson = read("package.json");
if (packageJson.includes("@tauri-apps/") || packageJson.includes('"tauri"')) {
    failures.push(
        "package.json must not contain Tauri dependencies or scripts",
    );
}

if (failures.length) {
    console.error("Swift iOS audit failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
}

console.log("Swift iOS audit passed.");
