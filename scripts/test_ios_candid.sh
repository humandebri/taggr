#!/usr/bin/env bash
set -euo pipefail

# Run the generated Candid bindings in Xcode. The explicit flag is required for
# non-interactive builds because Xcode otherwise asks the developer to trust
# the package build tool plugin.
xcodebuild \
    -project ios/TAGGR/TAGGR.xcodeproj \
    -scheme TAGGR \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -configuration Debug \
    build-for-testing \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO

xcodebuild \
    -project ios/TAGGR/TAGGR.xcodeproj \
    -scheme TAGGR \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -configuration Debug \
    -parallel-testing-enabled NO \
    test-without-building \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
