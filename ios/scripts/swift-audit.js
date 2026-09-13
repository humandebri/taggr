#!/usr/bin/env node
const { execFileSync } = require("child_process");

const plist = (path) =>
    JSON.parse(
        execFileSync("plutil", ["-convert", "json", "-o", "-", path], {
            encoding: "utf8",
        }),
    );
const failures = [];
const project = plist("ios/TAGGR/TAGGR.xcodeproj/project.pbxproj");
const objects = project.objects;
const app = Object.values(objects).find(
    (object) =>
        object.isa === "PBXNativeTarget" &&
        object.productType === "com.apple.product-type.application" &&
        object.name === "TAGGR",
);
if (!app) throw new Error("TAGGR application target is missing");
for (const id of objects[app.buildConfigurationList].buildConfigurations) {
    const configuration = objects[id];
    const projectConfiguration = objects[
        objects[project.rootObject].buildConfigurationList
    ].buildConfigurations
        .map((id) => objects[id])
        .find((item) => item.name === configuration.name);
    const settings = {
        ...projectConfiguration.buildSettings,
        ...configuration.buildSettings,
    };
    if (settings.PRODUCT_BUNDLE_IDENTIFIER !== "network.taggr.ios")
        failures.push(`${configuration.name}: incorrect bundle identifier`);
    if (
        Number(settings.IPHONEOS_DEPLOYMENT_TARGET) < 17.4 ||
        !settings.IPHONEOS_DEPLOYMENT_TARGET
    )
        failures.push(
            `${configuration.name}: deployment target must be at least 17.4`,
        );
    if (!settings.CODE_SIGN_ENTITLEMENTS)
        failures.push(`${configuration.name}: missing entitlements setting`);
    else {
        const entitlements = plist(
            `ios/TAGGR/${settings.CODE_SIGN_ENTITLEMENTS}`,
        );
        const domains =
            entitlements["com.apple.developer.associated-domains"] || [];
        for (const service of ["applinks", "webcredentials"]) {
            if (
                !domains.includes(
                    `${service}:6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io`,
                )
            )
                failures.push(
                    `${configuration.name}: missing canonical ${service} domain`,
                );
        }
    }
    const info = plist(`ios/TAGGR/${settings.INFOPLIST_FILE}`);
    if (info.CFBundleIdentifier !== "$(PRODUCT_BUNDLE_IDENTIFIER)")
        failures.push(
            `${configuration.name}: Info.plist must use the configured bundle identifier`,
        );
}
if (failures.length) {
    console.error(failures.join("\n"));
    process.exit(1);
}
console.log("Swift iOS project settings audit passed.");
