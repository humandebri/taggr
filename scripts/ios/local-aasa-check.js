const fs = require("fs");

const TEAM_ID = "AKN976G7AK";
const BUNDLE_ID = "network.taggr.ios";
const EXPECTED_APP_ID = `${TEAM_ID}.${BUNDLE_ID}`;
const REQUIRED_COMPONENTS = [
    "/post/*",
    "/user/*",
    "/realm/*",
    "/transaction/*",
    "/transactions",
    "/transactions/*",
    "/tokens",
    "/tokens/*",
];
const MAX_AASA_BYTES = 128 * 1024;
const AASA_FILES = [
    "src/frontend/assets/.well-known/apple-app-site-association",
    "dist/frontend/.well-known/apple-app-site-association",
];

const fail = (message) => {
    console.error(`FAIL ${message}`);
    process.exitCode = 1;
};
const pass = (message) => console.log(`PASS ${message}`);
const sameMembers = (actual, expected) =>
    actual.length === expected.length &&
    expected.every((item) => actual.includes(item));

const checkAasaFile = (path) => {
    if (!fs.existsSync(path)) {
        fail(`${path} is missing; run NODE_ENV=production npm run build`);
        return;
    }

    const bytes = fs.readFileSync(path);
    if (bytes.length <= MAX_AASA_BYTES) {
        pass(`${path} is at most 128 KB`);
    } else {
        fail(`${path} exceeds 128 KB`);
    }

    let json;
    try {
        json = JSON.parse(bytes.toString("utf8"));
        pass(`${path} is valid JSON`);
    } catch (error) {
        fail(`${path} is invalid JSON: ${error.message}`);
        return;
    }

    const details = json?.applinks?.details;
    if (!Array.isArray(details)) {
        fail(`${path} missing applinks.details`);
        return;
    }

    const appIds = details.flatMap((detail) =>
        Array.isArray(detail.appIDs) ? detail.appIDs : [detail.appID],
    );
    if (appIds.includes(EXPECTED_APP_ID)) {
        pass(`${path} includes ${EXPECTED_APP_ID}`);
    } else {
        fail(`${path} missing ${EXPECTED_APP_ID}`);
    }

    const components = details.flatMap((detail) =>
        Array.isArray(detail.components) ? detail.components : [],
    );
    const componentPaths = components.map((component) => component?.["/"]);
    if (sameMembers(componentPaths, REQUIRED_COMPONENTS)) {
        pass(`${path} components match public TAGGR routes`);
    } else {
        fail(`${path} components do not match public TAGGR routes`);
    }
};

for (const path of AASA_FILES) checkAasaFile(path);

if (process.exitCode) {
    console.error("Local iOS AASA check failed.");
} else {
    console.log("Local iOS AASA check passed.");
}
