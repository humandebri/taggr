import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// Use the release or Play App Signing certificate, never a disposable debug key.
const fingerprint = process.argv[2]?.toUpperCase();
if (!fingerprint || !/^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(fingerprint)) {
    throw new Error(
        "Pass the actual app-signing SHA-256 fingerprint as 32 colon-separated bytes.",
    );
}
const target = fileURLToPath(
    new URL(
        "../../src/frontend/assets/.well-known/assetlinks.json",
        import.meta.url,
    ),
);
await writeFile(
    target,
    JSON.stringify(
        [
            {
                relation: ["delegate_permission/common.handle_all_urls"],
                target: {
                    namespace: "android_app",
                    package_name: "org.taggr.android",
                    sha256_cert_fingerprints: [fingerprint],
                },
            },
        ],
        null,
        4,
    ) + "\n",
);
console.log(
    `Prepared ${target}; review and deploy with the Android callback assets.`,
);
