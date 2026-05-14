const fs = require("fs");
const { spawnSync } = require("child_process");

const APP_URL = "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";
const APP_HOST = "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";
const REQUIRED_IN_APP_HOSTS =
    `${APP_HOST} 6qfxa-ryaaa-aaaai-qbhsq-cai.ic0.app 6qfxa-ryaaa-aaaai-qbhsq-cai.raw.ic0.app id.ai identity.internetcomputer.org identity.ic0.app`.split(
        " ",
    );
const TEAM_ID = "AKN976G7AK";
const BUNDLE_ID = "network.taggr.ios";
const PUBLIC_ROUTE_PREFIXES =
    "/post /user /realm /transaction /transactions /tokens".split(" ");
const AASA_COMPONENTS =
    "/post/* /user/* /realm/* /transaction/* /transactions /transactions/* /tokens /tokens/*".split(
        " ",
    );
const COMMON_IOS_MARKERS =
    `invoke("share_url"|shareOrigin = isIOSApp()|toIOSUniversalLinkPath|TAGGR_CANONICAL_DOMAIN|${APP_HOST}|window.backendCache.stats?.canister_id|if (!firstSegment) return url|supported ? \`/\${route}\` : url|"post"|"user"|"realm"|"transaction"|"transactions"|"tokens"|getCanonicalDomain()|navigator.share|IOSReadOnlyTokenNotice`.split(
        "|",
    );

const read = (path) => fs.readFileSync(path, "utf8");
const has = (path, text) => read(path).includes(text);
const hasAll = (path, texts) => texts.every((text) => has(path, text));
const tauriSrc = () =>
    fs
        .readdirSync("src-tauri/src")
        .filter((file) => file.endsWith(".rs"))
        .map((file) => read(`src-tauri/src/${file}`))
        .join("\n");
const tauriHas = (text) => tauriSrc().includes(text);
const tauriHasAll = (texts) => texts.every(tauriHas);
const tauriSourceFiles = () =>
    fs
        .readdirSync("src-tauri/src", { recursive: true })
        .filter((file) => file.endsWith(".rs"))
        .map((file) => `src-tauri/src/${file}`);
const lineCount = (path) => read(path).split("\n").length;
const commandOk = (cmd, args) =>
    spawnSync(cmd, args, { encoding: "utf8", stdio: "pipe" }).status === 0;
const sameMembers = (actual, expected) =>
    actual.length === expected.length &&
    expected.every((item) => actual.includes(item));
const frontendSource = () =>
    fs
        .readdirSync("src/frontend/src")
        .filter((file) => file.endsWith(".tsx"))
        .map((file) => read(`src/frontend/src/${file}`))
        .join("\n");
const staticShareLinksMatchRoutes = () => {
    const index = read("src/frontend/src/index.tsx");
    const routeNames = Array.from(index.matchAll(/handler == "([^"]+)"/g)).map(
        ([, route]) => route,
    );
    const shareLinks = Array.from(
        frontendSource().matchAll(/shareLink="([a-z-]+)"/g),
    ).map(([, route]) => route);
    return shareLinks.every((route) => routeNames.includes(route));
};

const checks = [
    [
        "Tauri loads TAGGR production URL",
        () => {
            const config = JSON.parse(read("src-tauri/tauri.conf.json"));
            return (
                config.build.devUrl === APP_URL &&
                config.build.frontendDist === APP_URL
            );
        },
    ],
    [
        "Tauri source files stay under 300 lines",
        () => tauriSourceFiles().every((path) => lineCount(path) <= 300),
    ],
    [
        "Tauri iOS bundle identity is fixed",
        () => {
            const config = JSON.parse(read("src-tauri/tauri.conf.json"));
            return (
                config.productName === "TAGGR" &&
                config.identifier === BUNDLE_ID &&
                config.bundle.iOS.developmentTeam === TEAM_ID
            );
        },
    ],
    [
        "Deep link config includes app link and taggr scheme",
        () => {
            const mobile = JSON.parse(read("src-tauri/tauri.conf.json"))
                .plugins["deep-link"].mobile;
            return (
                mobile.some(
                    (entry) =>
                        entry.scheme.includes("https") &&
                        entry.host === APP_HOST &&
                        entry.appLink === true &&
                        sameMembers(entry.pathPrefix, PUBLIC_ROUTE_PREFIXES),
                ) &&
                mobile.some(
                    (entry) =>
                        entry.scheme.includes("taggr") &&
                        entry.appLink === false,
                )
            );
        },
    ],
    [
        "Generated iOS project has URL scheme and associated domain",
        () =>
            fs.existsSync("src-tauri/gen/apple/assets/.gitkeep") &&
            [
                "src-tauri/Info.ios.plist",
                "src-tauri/gen/apple/taggr-ios_iOS/Info.plist",
            ].every((path) => has(path, "<string>taggr</string>")) &&
            has(
                "src-tauri/gen/apple/taggr-ios_iOS/taggr-ios_iOS.entitlements",
                `applinks:${APP_HOST}`,
            ),
    ],
    [
        "Generated iOS project app-bound domains match in-app hosts",
        () => {
            const project = read("src-tauri/gen/apple/project.yml");
            return REQUIRED_IN_APP_HOSTS.every(
                (host) =>
                    [
                        "src-tauri/Info.ios.plist",
                        "src-tauri/gen/apple/taggr-ios_iOS/Info.plist",
                    ].every((path) => has(path, `<string>${host}</string>`)) &&
                    project.includes(`- ${host}`) &&
                    tauriHas(host),
            );
        },
    ],
    [
        "AASA file targets the signed iOS bundle",
        () => {
            const aasa = JSON.parse(
                read(
                    "src/frontend/assets/.well-known/apple-app-site-association",
                ),
            );
            return aasa.applinks.details.some(
                (detail) =>
                    detail.appIDs.includes(`${TEAM_ID}.${BUNDLE_ID}`) &&
                    sameMembers(
                        detail.components.map((component) => component["/"]),
                        AASA_COMPONENTS,
                    ),
            );
        },
    ],
    [
        "Backend serves AASA through certified HTTP path",
        () =>
            has(
                "src/backend/assets.rs",
                "/.well-known/apple-app-site-association",
            ) &&
            has(
                "src/backend/assets.rs",
                "../../src/frontend/assets/.well-known/apple-app-site-association",
            ) &&
            has("src/backend/http.rs", "assets::asset_certified(path)") &&
            has(
                "src/backend/http/test.rs",
                "should_serve_aasa_without_upgrade",
            ) &&
            has("src/backend/http/test.rs", "application/json"),
    ],
    [
        "Remote capability exposes only the native share command",
        () => {
            const capability = JSON.parse(
                read("src-tauri/capabilities/default.json"),
            );
            return (
                capability.$schema === "../gen/schemas/capabilities.json" &&
                fs.existsSync("src-tauri/gen/schemas/capabilities.json") &&
                capability.remote.urls.length === 1 &&
                capability.remote.urls[0] === `${APP_URL}/**` &&
                sameMembers(capability.permissions, ["allow-share-url"]) &&
                !capability.permissions.includes("core:default")
            );
        },
    ],
    [
        "Tauri shell separates external navigation",
        () =>
            tauriHasAll([
                "handle_navigation",
                "should_open_externally",
                "app.opener().open_url",
                "window.open = (url, target, features)",
                "originalWindowOpen",
                "isIdentityUrl",
                'link.target !== "_blank"',
            ]),
    ],
    [
        "Tauri shell has loading, reload, and deep route normalization",
        () =>
            tauriHasAll([
                "taggr-ios-loading",
                "taggr-ios-error",
                "location.reload()",
                "ERROR_PAGE_URL",
                "error_page_url",
                "about:blank#taggr-ios-error",
                "on_web_content_process_terminate",
                "FIRST_LOAD_TIMEOUT_MS",
                "firstLoadFinished",
                "initial_webview_url",
                "bootstrap_target_url",
                "contains_supported_deep_link",
                "external_initial_links",
                "isBootstrapDocument",
                "isAppDocument",
                "!isBootstrapDocument() && !isAppDocument()",
                "navigateToApp",
                "about:blank",
                "canonical_https_to_url",
                "is_supported_public_route",
                "route_to_app_url",
            ]),
    ],
    [
        "Frontend uses iOS share sheet and read-only token policy",
        () =>
            tauriHasAll([
                "share_url",
                "validate_share_url",
                "url.username().is_empty()",
                "url.query().is_none()",
                "UIActivityViewController",
                "popoverPresentationController",
                "setSourceView",
            ]) &&
            hasAll("src-tauri/capabilities/default.json", [
                "allow-share-url",
            ]) &&
            hasAll("src-tauri/build.rs", ["AppManifest"]) &&
            hasAll("src/frontend/src/common.tsx", COMMON_IOS_MARKERS) &&
            has("src/frontend/src/settings.tsx", 'shareLink="settings"') &&
            staticShareLinksMatchRoutes() &&
            has("src/frontend/src/wallet.tsx", "!isIOSApp()") &&
            has(
                "src/frontend/src/wallet.tsx",
                "Credit minting is unavailable in the iOS app.",
            ) &&
            has(
                "src/frontend/src/welcome.tsx",
                "Use an invite or the web app",
            ) &&
            has("src/frontend/src/tokens.tsx", "!isIOSApp()") &&
            has("src/frontend/src/links.tsx", "!isIOSApp()") &&
            has("src/frontend/src/distribution.tsx", "!isIOSApp()") &&
            has("src/frontend/src/distribution.tsx", "delay_weekly_chores") &&
            has("src/frontend/src/settings.tsx", "nextSettings.icrcWallet") &&
            has("src/frontend/src/settings.tsx", "nextMode =") &&
            has("src/frontend/src/form.tsx", "IOS_PROPOSAL_TYPES") &&
            has("src/frontend/src/proposals.tsx", "isIOSApp()") &&
            has(
                "src/frontend/src/proposals.tsx",
                "token and ICP transfer proposals are read-only",
            ),
    ],
    [
        "Privacy route and App Review notes exist",
        () =>
            has("src/frontend/src/index.tsx", 'handler == "privacy"') &&
            fs.existsSync("docs/ios/app_store_review.md") &&
            fs.existsSync("docs/ios/tauri_completion_audit.md"),
    ],
];

const failures = checks.filter(([, check]) => !check()).map(([name]) => name);

if (failures.length > 0) {
    console.error("iOS Tauri audit failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
}

console.log(`iOS Tauri audit passed (${checks.length} checks).`);

const xcodeReady =
    commandOk("xcrun", ["simctl", "list", "runtimes", "--json"]) &&
    commandOk("xcrun", ["--show-sdk-path", "--sdk", "iphoneos"]);

if (!xcodeReady) {
    console.warn(
        "iOS runtime audit skipped: full Xcode, simctl, or iphoneos SDK is unavailable.",
    );
    process.exit(0);
}

console.log("iOS runtime audit passed.");
