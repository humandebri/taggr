const fs = require("fs");
const zlib = require("zlib");
const vm = require("vm");

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
if (bundle.trim()) {
    try {
        new vm.Script(bundle, { filename: BUNDLE });
        pass("frontend JavaScript bundle parses");
    } catch (error) {
        fail(`frontend JavaScript bundle is invalid: ${error.message}`);
    }
} else if (!process.exitCode) {
    fail(`${BUNDLE} is empty`);
}

if (process.exitCode) {
    console.error("Local iOS frontend bundle check failed.");
} else {
    console.log("Local iOS frontend bundle check passed.");
}
