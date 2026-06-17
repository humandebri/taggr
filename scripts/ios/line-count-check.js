#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const roots = ["ios/TAGGR/TAGGR", "ios/TAGGR/TAGGRTests", "scripts/ios"];
const maxLines = 320;

const walk = (dir) => {
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
        const target = path.join(dir, entry.name);
        if (entry.isDirectory()) return walk(target);
        return target;
    });
};

const files = roots
    .flatMap(walk)
    .filter((file) => /\.(swift|js)$/.test(file))
    .filter((file) => !file.endsWith("completion-audit.js"));

const failures = files
    .map((file) => ({
        file,
        lines: fs.readFileSync(file, "utf8").split("\n").length,
    }))
    .filter(({ lines }) => lines > maxLines);

if (failures.length) {
    console.error(`iOS authored files must stay under ${maxLines} lines:`);
    for (const failure of failures) {
        console.error(`- ${failure.file}: ${failure.lines}`);
    }
    process.exit(1);
}

console.log(`iOS line-count check passed (${files.length} files).`);
