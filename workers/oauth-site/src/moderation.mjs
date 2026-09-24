export const CANISTERS = ["6qfxa-ryaaa-aaaai-qbhsq-cai"];
export const validID = (id) => Number.isSafeInteger(id) && id >= 0;
const uuid = (id) =>
    typeof id === "string" &&
    /^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$/i.test(
        id,
    );
const json = (body, status = 200) =>
    Response.json(body, {
        status,
        headers: {
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
        },
    });
const fail = (message, status = 400) => {
    throw Object.assign(new Error(message), { status });
};

export function validateReport(body) {
    if (
        !body ||
        !uuid(body.id) ||
        !CANISTERS.includes(body.canisterID) ||
        !validID(body.userID) ||
        (body.postID != null && !validID(body.postID))
    )
        fail("Invalid report target");
    if (
        typeof body.reason !== "string" ||
        !body.reason.trim() ||
        [...body.reason].length > 2000
    )
        fail("Reason must be 1–2000 characters");
    return {
        id: body.id.toLowerCase(),
        canisterID: body.canisterID,
        userID: body.userID,
        postID: body.postID ?? null,
        reason: body.reason.trim(),
    };
}

async function readReport(request) {
    if (!request.headers.get("content-type")?.startsWith("application/json"))
        fail("JSON required", 415);
    const reader = request.body?.getReader();
    if (!reader) fail("Body required");
    const chunks = [];
    let size = 0;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.length;
            if (size > 8192) {
                await reader.cancel();
                fail("Request too large", 413);
            }
            chunks.push(value);
        }
    } finally {
        reader.releaseLock();
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
    }
    let body;
    try {
        body = JSON.parse(
            new TextDecoder("utf-8", { fatal: true }).decode(bytes),
        );
    } catch {
        fail("Invalid JSON");
    }
    return validateReport(body);
}

export async function moderationFetch(request, env) {
    const url = new URL(request.url);
    if (!["/api/reports", "/api/moderation"].includes(url.pathname))
        return null;
    try {
        if (
            (url.pathname === "/api/reports" && request.method !== "POST") ||
            (url.pathname === "/api/moderation" && request.method !== "GET")
        )
            return json({ error: "Method not allowed" }, 405);
        if (!env.MODERATION_DB) fail("Service not configured", 503);
        const db = env.MODERATION_DB;
        if (url.pathname === "/api/moderation") {
            const canisterID = url.searchParams.get("canisterID");
            if (!CANISTERS.includes(canisterID)) fail("Unsupported canister");
            const [version, targets] = await db.batch([
                db.prepare(
                    "SELECT COALESCE(MAX(id),0) AS version FROM restrictions",
                ),
                db
                    .prepare(
                        "SELECT kind,target_id FROM restrictions WHERE id IN (SELECT MAX(id) FROM restrictions WHERE canister_id=?1 GROUP BY kind,target_id) AND active=1",
                    )
                    .bind(canisterID),
            ]);
            return json({
                canisterID,
                version: version.results[0].version,
                postIDs: targets.results
                    .filter((r) => r.kind === "post")
                    .map((r) => r.target_id),
                userIDs: targets.results
                    .filter((r) => r.kind === "user")
                    .map((r) => r.target_id),
            });
        }
        const origin = request.headers.get("origin");
        if (origin && origin !== url.origin) fail("Invalid origin", 403);
        if (!env.REPORT_LIMITER) fail("Service not configured", 503);
        // Anonymous reports have no trustworthy account ID. Shared networks share this coarse abuse limit.
        const { success } = await env.REPORT_LIMITER.limit({
            key:
                "taggr-ios-reports:" +
                (request.headers.get("cf-connecting-ip") || "local"),
        });
        if (!success)
            return json(
                { error: "Too many reports. Please retry in a minute." },
                429,
            );
        const report = await readReport(request);
        await db
            .prepare(
                "INSERT OR IGNORE INTO reports(id,canister_id,user_id,post_id,reason,received_at) VALUES(?1,?2,?3,?4,?5,?6)",
            )
            .bind(
                report.id,
                report.canisterID,
                report.userID,
                report.postID,
                report.reason,
                Date.now(),
            )
            .run();
        const saved = await db
            .prepare(
                "SELECT canister_id,user_id,post_id,reason FROM reports WHERE id=?1",
            )
            .bind(report.id)
            .first();
        if (
            !saved ||
            saved.canister_id !== report.canisterID ||
            saved.user_id !== report.userID ||
            saved.post_id !== report.postID ||
            saved.reason !== report.reason
        )
            fail("Report ID already used", 409);
        return json({ id: report.id, status: "received" }, 201);
    } catch (error) {
        if (!error.status)
            console.error("moderation_request_failed", { path: url.pathname });
        return json(
            {
                error: error.status
                    ? error.message
                    : "Service temporarily unavailable. Please retry.",
            },
            error.status || 503,
        );
    }
}
