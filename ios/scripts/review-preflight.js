const fs = require("fs");

const read = (path) => fs.readFileSync(path, "utf8");
const has = (path, text) => read(path).includes(text);
const fail = (message) => {
    console.error(`FAIL ${message}`);
    process.exitCode = 1;
};
const pass = (message) => console.log(`PASS ${message}`);

const reviewDoc = "ios/docs/app_store_review.md";
const runbookDoc = "ios/docs/submission_runbook.md";
const listingDoc = "ios/docs/app_store_listing.md";
const requiredFiles = [
    reviewDoc,
    runbookDoc,
    listingDoc,
    "ios/docs/app_privacy_answers.md",
    "ios/docs/swift_requirements.md",
    "src/frontend/src/privacy.tsx",
    "src/frontend/src/links.tsx",
    "src/frontend/assets/.well-known/apple-app-site-association",
];

for (const file of requiredFiles) {
    if (fs.existsSync(file)) pass(`${file} exists`);
    else fail(`${file} is missing`);
}

if (!fs.existsSync(reviewDoc)) process.exit(1);

const review = read(reviewDoc);
const placeholders = [
    "<email or Internet Identity instructions>",
    "<invite code>",
    "<support contact>",
    "APPREVIEW-TODO-PRODUCTION-INVITE",
];

for (const placeholder of placeholders) {
    if (review.includes(placeholder)) {
        fail(`App Review placeholder remains: ${placeholder}`);
    }
}

const requiredReviewText = [
    "TAGGR is a decentralized social network",
    "user-generated content",
    "report posts/users",
    "block users",
    "Privacy policy route",
    "wallet operations",
    "Universal Links",
];

for (const text of requiredReviewText) {
    if (review.includes(text)) pass(`review notes include: ${text}`);
    else fail(`review notes missing: ${text}`);
}

const linksChecks = [
    ["src/frontend/src/index.tsx", 'handler == "links"'],
    ["src/frontend/src/index.tsx", 'handler == "privacy"'],
    ["src/frontend/src/landing.tsx", 'href="/#/links"'],
    ["src/frontend/src/links.tsx", 'href="#/privacy"'],
    ["src/frontend/src/links.tsx", "#/realm/HELP"],
    ["src/frontend/src/links.tsx", "OpenChat Community"],
    ["src/frontend/src/privacy.tsx", "Data stored by TAGGR"],
    ["src/frontend/src/privacy.tsx", "iOS app data"],
    ["src/frontend/src/privacy.tsx", "Third-party services"],
    ["src/frontend/src/privacy.tsx", "Internet Identity"],
    ["src/frontend/src/privacy.tsx", "Token and wallet surfaces"],
    ["src/frontend/src/privacy.tsx", "no analytics SDK"],
    ["src/frontend/src/privacy.tsx", "advertising SDK"],
    ["src/frontend/src/privacy.tsx", "APNs device token"],
    ["src/frontend/src/privacy.tsx", "HELP"],
    ["src/frontend/src/privacy.tsx", "OpenChat"],
    ["src/frontend/src/common.tsx", "report"],
    ["src/frontend/src/profile.tsx", "FlagButton"],
    ["src/frontend/src/profile.tsx", "block"],
    ["ios/docs/app_privacy_answers.md", "Privacy Policy URL"],
    ["ios/docs/app_privacy_answers.md", "Tracking: No"],
    ["ios/docs/app_privacy_answers.md", "User Content"],
    ["ios/docs/app_privacy_answers.md", "Identifiers"],
    ["ios/docs/app_privacy_answers.md", "Financial Info"],
    ["ios/docs/app_privacy_answers.md", "Account supports ICP transfers"],
    [listingDoc, "Subtitle: `Decentralized social network`"],
    [listingDoc, "Promotional Text"],
    [listingDoc, "Description"],
    [listingDoc, "Keywords"],
    [listingDoc, "What's New"],
    [listingDoc, "Privacy Policy URL"],
    [listingDoc, "Support URL"],
    [listingDoc, "Screenshot Set"],
    [listingDoc, "6.9-inch"],
    [listingDoc, "portrait screenshots first"],
    [listingDoc, "1320 x 2868"],
    ["ios/TAGGR/TAGGR/Views/RootView.swift", "ProfileView()"],
    ["ios/TAGGR/TAGGR/Views/AuthSettingsViews.swift", "Send ICP"],
    ["ios/TAGGR/TAGGR/Views/AuthSettingsViews.swift", "Mint 1k credits"],
    ["ios/TAGGR/TAGGR/Views/ProfileViews.swift", "struct ProfileView"],
    ["ios/TAGGR/TAGGR/Views/ProfileViews.swift", "toggleBlock(userId:"],
    ["ios/TAGGR/TAGGR/Views/ProfileViews.swift", "ReportUserSheet"],
    ["ios/TAGGR/TAGGR/Views/AuthSettingsViews.swift", "createUser(name:"],
];

for (const [file, text] of linksChecks) {
    if (has(file, text)) pass(`${file} includes ${text}`);
    else fail(`${file} missing ${text}`);
}

if (process.exitCode) {
    console.error("iOS App Review preflight failed.");
} else {
    console.log("iOS App Review preflight passed.");
}
