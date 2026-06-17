const fs = require("fs");

const read = (path) => fs.readFileSync(path, "utf8");
const has = (path, text) => read(path).includes(text);
const fail = (message) => {
    console.error(`FAIL ${message}`);
    process.exitCode = 1;
};
const pass = (message) => console.log(`PASS ${message}`);

const reviewDoc = "docs/ios/app_store_review.md";
const runbookDoc = "docs/ios/submission_runbook.md";
const requiredFiles = [
    reviewDoc,
    runbookDoc,
    "docs/ios/app_privacy_answers.md",
    "docs/ios/swift_requirements.md",
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
    "read-only token/crypto surfaces",
    "Universal Links",
];

for (const text of requiredReviewText) {
    if (review.includes(text)) pass(`review notes include: ${text}`);
    else fail(`review notes missing: ${text}`);
}

const linksChecks = [
    ["src/frontend/src/app/legacy/LegacyRoute.tsx", 'current.name === "links"'],
    ["src/frontend/src/app/legacy/LegacyRoute.tsx", 'current.name === "privacy"'],
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
    ["src/frontend/src/privacy.tsx", "push notification token collection"],
    ["src/frontend/src/privacy.tsx", "HELP"],
    ["src/frontend/src/privacy.tsx", "OpenChat"],
    ["src/frontend/src/common.tsx", "report"],
    ["src/frontend/src/profile.tsx", "FlagButton"],
    ["src/frontend/src/profile.tsx", "block"],
    ["docs/ios/app_privacy_answers.md", "Privacy Policy URL"],
    ["docs/ios/app_privacy_answers.md", "Tracking: No"],
    ["docs/ios/app_privacy_answers.md", "User Content"],
    ["docs/ios/app_privacy_answers.md", "Identifiers"],
    ["docs/ios/app_privacy_answers.md", "Financial Info"],
    ["docs/ios/app_privacy_answers.md", "read-only token/wallet surfaces"],
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
