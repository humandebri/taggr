const fs = require("fs");

const read = (path) => fs.readFileSync(path, "utf8");
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

if (process.exitCode) {
    console.error("iOS App Review preflight failed.");
} else {
    console.log("iOS App Review preflight passed.");
}
