const fs = require("fs");
const zlib = require("zlib");

const BUNDLE = "dist/frontend/index.js.gz";
const INDEX = "dist/frontend/index.html";

const fail = (message) => {
    console.error(`FAIL ${message}`);
    process.exitCode = 1;
};
const pass = (message) => console.log(`PASS ${message}`);

const readBundle = () => {
    if (!fs.existsSync(BUNDLE)) {
        fail(`${BUNDLE} is missing; run NODE_ENV=production npm run build`);
        return "";
    }
    try {
        return zlib.gunzipSync(fs.readFileSync(BUNDLE)).toString("utf8");
    } catch (error) {
        fail(`${BUNDLE} is not readable gzip: ${error.message}`);
        return "";
    }
};

if (fs.existsSync(INDEX)) {
    pass(`${INDEX} exists`);
} else {
    fail(`${INDEX} is missing; run NODE_ENV=production npm run build`);
}

const bundle = readBundle();
const requiredTexts = [
    "Privacy policy",
    "Data stored by TAGGR",
    "iOS app data",
    "Third-party services",
    "Internet Identity",
    "Token and wallet surfaces",
    "HELP Realm",
    "OpenChat Community",
    "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
];

for (const text of requiredTexts) {
    if (bundle.includes(text)) {
        pass(`frontend bundle includes: ${text}`);
    } else {
        fail(`frontend bundle missing: ${text}`);
    }
}

if (process.exitCode) {
    console.error("Local iOS frontend bundle check failed.");
} else {
    console.log("Local iOS frontend bundle check passed.");
}
