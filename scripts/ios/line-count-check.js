const fs = require("fs");

const MAX_LINES = 300;
const explicitFiles = [
    "src-tauri/build.rs",
    "src-tauri/Cargo.toml",
    "src-tauri/tauri.conf.json",
    "src-tauri/capabilities/default.json",
    "src-tauri/gen/apple/LaunchScreen.storyboard",
    "src/frontend/src/privacy.tsx",
    "src/frontend/assets/.well-known/apple-app-site-association",
    "src/backend/http/test.rs",
];

const filesIn = (dir, suffix, prefix = "") =>
    fs
        .readdirSync(dir, { recursive: true })
        .filter((file) => file.endsWith(suffix))
        .map((file) => `${dir}/${file}`)
        .filter((file) => file.startsWith(prefix || dir));

const files = [
    ...filesIn("docs/ios", ".md"),
    ...filesIn("scripts/ios", ".js"),
    ...filesIn("src-tauri/src", ".rs"),
    ...explicitFiles,
];

let failed = false;

for (const file of files) {
    const lines = fs
        .readFileSync(file, "utf8")
        .replace(/\n$/, "")
        .split("\n").length;
    if (lines > MAX_LINES) {
        console.error(`FAIL ${file} has ${lines} lines`);
        failed = true;
    } else {
        console.log(`PASS ${file} has ${lines} lines`);
    }
}

if (failed) process.exit(1);
console.log(`iOS line count check passed for ${files.length} files.`);
