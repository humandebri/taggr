#!/usr/bin/env bash
set -euo pipefail

required_didc_version="didc 0.5.4"
actual_version="$(didc --version 2>/dev/null || true)"
if [[ "$actual_version" != "$required_didc_version" ]]; then
    echo "expected $required_didc_version, got: ${actual_version:-<missing>}" >&2
    exit 1
fi

shasum -a 256 -c <<'HASHES'
e4bfa742f5097679fa38b325f5c0ef132567e6da12df196651c9c4a881e43b8b  src/backend/taggr.did
e4bfa742f5097679fa38b325f5c0ef132567e6da12df196651c9c4a881e43b8b  ios/TAGGR/Candid/taggr.did
2b4d3fe36fb6549cb2153353c85a0ff9a1567a821ed91565e092a6aa35aa57e6  ios/TAGGR/Candid/production/ledger.did
c31140bab35b6dbd606270dfeaad1575cf60869339a2bf2f3cd037f7683b5e8c  ios/TAGGR/Candid/production/cmc.did
a6ed7604883616717fe0742b11b19a37629f8a7183adfda5775558d22907004c  ios/TAGGR/Candid/production/management.did
a7ea759c13a123fe5db40b4686e7af88cbc74084ca4d50dbd7c39be3e5397efb  ios/TAGGR/Candid/production/bucket.did
HASHES

if ! cmp -s src/backend/taggr.did ios/TAGGR/Candid/taggr.did; then
    echo "ios/TAGGR/Candid/taggr.did is not synchronized with src/backend/taggr.did" >&2
    exit 1
fi

didc check ios/TAGGR/Candid/taggr.did
for interface in ios/TAGGR/Candid/production/*.did; do
    didc check "$interface"
done

if [[ -e ios/TAGGR/TAGGR/TaggrAPI/GeneratedCandidBindings.swift ]]; then
    echo "generated Swift must remain in Xcode Derived Sources" >&2
    exit 1
fi

if rg -n 'TaggrCandid\.(encode|decode)|TaggrCandid\.throwIfRejected' ios/TAGGR --glob '*.swift'; then
    echo "legacy TaggrCandid binary codec reference remains" >&2
    exit 1
fi

unexpected_raw="$(rg -l 'queryRaw|callRaw' ios/TAGGR/TAGGR --glob '*.swift' | rg -v '/TaggrAPI/TaggrAPI\.swift$' || true)"
if [[ -n "$unexpected_raw" ]]; then
    echo "raw IC API reference outside TaggrAPI transport adapter:" >&2
    echo "$unexpected_raw" >&2
    exit 1
fi
