const https = require("https");

const APP_HOST =
    process.env.IOS_AASA_HOST || "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io";
const TEAM_ID = "AKN976G7AK";
const BUNDLE_ID = "network.taggr.ios";
const EXPECTED_APP_ID = `${TEAM_ID}.${BUNDLE_ID}`;
const AASA_PATHS = ["/.well-known/apple-app-site-association"];
const REQUIRED_PATHS = ["/*"];
const MAX_AASA_BYTES = 128 * 1024;

const fail = (message) => {
    console.error(`FAIL ${message}`);
    process.exitCode = 1;
};
const pass = (message) => console.log(`PASS ${message}`);
const sameMembers = (actual, expected) =>
    actual.length === expected.length &&
    expected.every((item) => actual.includes(item));

const checkAasa = (path) =>
    new Promise((resolve) => {
        const url = `https://${APP_HOST}${path}`;
        https
            .get(
                url,
                { headers: { Accept: "application/json" } },
                (response) => {
                    const chunks = [];
                    response.on("data", (chunk) => chunks.push(chunk));
                    response.on("end", () => {
                        const bodyBytes = Buffer.concat(chunks);
                        const body = bodyBytes.toString("utf8");

                        if (response.statusCode === 200) {
                            pass(`AASA HTTP 200 at ${url}`);
                        } else {
                            fail(
                                `AASA returned HTTP ${response.statusCode} at ${url}`,
                            );
                        }

                        if (!String(response.statusCode).startsWith("3")) {
                            pass(`AASA response is not a redirect at ${url}`);
                        } else {
                            fail(`AASA response must not redirect at ${url}`);
                        }

                        if (bodyBytes.length <= MAX_AASA_BYTES) {
                            pass(`AASA body is at most 128 KB at ${url}`);
                        } else {
                            fail(`AASA body exceeds 128 KB at ${url}`);
                        }

                        const contentType =
                            response.headers["content-type"] || "";
                        if (contentType.includes("application/json")) {
                            pass(
                                `AASA content-type is ${contentType} at ${url}`,
                            );
                        } else {
                            fail(
                                `AASA content-type is ${contentType || "missing"} at ${url}`,
                            );
                        }

                        let json;
                        try {
                            json = JSON.parse(body);
                            pass(`AASA is valid JSON at ${url}`);
                        } catch (error) {
                            fail(
                                `AASA is invalid JSON at ${url}: ${error.message}`,
                            );
                            resolve();
                            return;
                        }

                        const details = json?.applinks?.details;
                        if (Array.isArray(details)) {
                            pass(`AASA applinks.details exists at ${url}`);
                        } else {
                            fail(`AASA applinks.details is missing at ${url}`);
                            resolve();
                            return;
                        }

                        const hasAppId = details.some(
                            (detail) => detail.appID === EXPECTED_APP_ID,
                        );

                        if (hasAppId) {
                            pass(`AASA includes ${EXPECTED_APP_ID} at ${url}`);
                        } else {
                            fail(`AASA missing ${EXPECTED_APP_ID} at ${url}`);
                        }

                        const aasaPaths = details.flatMap((detail) =>
                            Array.isArray(detail.paths) ? detail.paths : [],
                        );
                        if (sameMembers(aasaPaths, REQUIRED_PATHS)) {
                            pass(
                                `AASA paths exactly match TAGGR universal links at ${url}`,
                            );
                        } else {
                            fail(
                                `AASA paths do not exactly match TAGGR universal links at ${url}`,
                            );
                        }

                        const webcredentials = json?.webcredentials?.apps;
                        if (
                            Array.isArray(webcredentials) &&
                            webcredentials.includes(EXPECTED_APP_ID)
                        ) {
                            pass(
                                `AASA includes ${EXPECTED_APP_ID} webcredentials at ${url}`,
                            );
                        } else {
                            fail(
                                `AASA missing ${EXPECTED_APP_ID} webcredentials at ${url}`,
                            );
                        }

                        resolve();
                    });
                },
            )
            .on("error", (error) => {
                fail(`AASA request failed at ${url}: ${error.message}`);
                resolve();
            });
    });

(async () => {
    for (const path of AASA_PATHS) {
        await checkAasa(path);
    }
})();
