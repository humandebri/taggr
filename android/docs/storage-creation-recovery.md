# Storage creation response-loss verification — 2026-10-08

Two ordinary signed-in Android app journeys verified the existing storage-creation recovery workflow against a dedicated local NNS and TAGGR development canister. Each public fixture user received fake local ICP. A task-owned HTTPS proxy forwarded a request, received the upstream response, then deliberately closed the client connection once. No mainnet payment or real user identity was involved.

| Lost response           | Independent result before recovery                                                                                                   | Result after full emulator restart and one Check and continue tap |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Management install_code | Bucket was Running with the exact fresh TAGGR bucket_wasm_hash; authenticated management status confirmed the module and controllers | Existing module was retained and registration completed           |
| TAGGR set_bucket        | Authenticated user query already contained the created bucket                                                                        | Pending state cleared and the same registered bucket remained     |

For each separate user, the proxy trace contains exactly one transfer, one notify_create_canister, one install_code and one set_bucket across creation and recovery. The second recovery therefore did not resend registration. Independent authenticated backend readback confirms both final bucket associations. These checks establish recovery for completed operations whose responses were lost; they do not cover every rejected, partially executed or unavailable-network outcome. No production source change was necessary for these cases.

Evidence is retained in the ignored .build/android/storage-recovery directory: install-recovery-summary.json, installed-status-before-recovery.json, expected-bucket-hash.json, install-user-after-recovery.json, registration-recovery-summary.json, registration-status-before-recovery.json, registration-user-before-recovery.json, registration-user-after-recovery.json, calls.jsonl and the corresponding UI XML/logs.

Automation limitations are retained rather than counted as app failures: an early UI dump produced invalid XML during a settings transition; the helper now validates fresh XML with bounded retries. The first install-loss driver also asserted an offscreen payment heading after already observing the recovery control. Both bounded emulator intervals shut down normally; subsequent recovery used a fresh full startup. A successful guard summary establishes resource monitoring and shutdown, while separate UI logs and backend readbacks establish workflow success.

The dedicated API 33 AVD used a 2048 MiB guest, software graphics, no snapshots and no concurrent Gradle build. Registration-response-loss monitoring recorded peak emulator RSS 5252 MiB and aggregate Codex RSS 2845–2867 MiB with no guard trigger. Aggregate process RSS does not measure unique physical memory. These short checks do not establish that a long-session Codex or emulator memory leak has been fixed.

Production signing, public Android callback deployment, real Internet Identity passkeys and real Google authorization/upload remain outside this verification.

The final registration-recovery interval (emulator-check-20261008-185206) passed its bounded monitor with peak emulator RSS 5120 MiB, aggregate Codex RSS baseline 2537 MiB / peak 2644 MiB, no guard trigger and emulator exit 0. The owned test proxy, local network, AVD and two public-fixture CLI identities were then removed or stopped. Task TLS and fixture private-key files were deleted. Other identities and shared AVDs were retained.

After shutdown, the public-default Debug configuration was rebuilt successfully with all 255 JVM tests passing, Lint and both app/test APK assembly passing. cargo fmt --all -- --check and cargo check --locked -j 2 passed. public-default-final-check.json records the restored configuration; no Release rebuild or change to the preceding unsigned Release checkpoint was needed.
