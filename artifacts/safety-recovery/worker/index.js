var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/safety-ui.mjs
var escape = /* @__PURE__ */ __name((value) => String(value).replace(
  /[&<>"']/g,
  (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[char]
), "escape");
function safetyHTML(admin, canisters2) {
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TAGGR \u2014 ${admin ? "Safety administration" : "Terms & safety"}</title>
<style>html{color-scheme:dark;font-family:system-ui;background:#111216;color:#f2f3ee}body{max-width:850px;margin:auto;padding:24px;line-height:1.6}a{color:#43d7cc}h1{line-height:1.2}label{display:block;margin:16px 0}input,select,textarea,button{font:inherit;padding:10px;border:1px solid #777;border-radius:6px;box-sizing:border-box}textarea,input,select{display:block;width:100%;max-width:100%}button{cursor:pointer;background:#253d3a;color:#fff;margin:6px 6px 6px 0}button:disabled{opacity:.5}article{padding:18px;border:1px solid #777;border-radius:8px;margin:18px 0;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere}#status{min-height:2em}.warning{color:#ffcc66}</style>
<body data-admin="${admin}" data-canister="${escape(canisters2[0] || "")}">
<a href="/about">TAGGR</a> \xB7 <a href="/terms">Terms</a> \xB7 <a href="/privacy-policy">Privacy</a>
<h1>${admin ? "Safety administration" : "Terms & safety"}</h1>
<p>Objectionable content and abusive behavior are not tolerated in the TAGGR iOS app. Report concerns below or use Report and Block in the app. The operator reviews reports and acts on violations within 24 hours.</p>
<p>Actions here restrict content and accounts in the official iOS app, not the underlying decentralized network. To appeal a restriction, include the affected post or user ID below.</p>
<p id="status" role="status" aria-live="polite"></p>
${admin ? `<p class="warning">Reports are unverified submissions. Check the actual post and author before restricting. Restricting does not close a report: resolve it only after all required actions are complete.</p>
<button id="reload" type="button">Refresh</button><label>Report view<select id="report-view"><option value="0">Open and reviewing</option><option value="1">All, including closed</option></select></label><section id="reports" aria-label="Reports"></section><button id="older" type="button">Older reports</button>
<h2>Restrict or restore</h2><form id="action"><label>Canister<select name="canisterID">${canisters2.map((id) => `<option>${escape(id)}</option>`).join("")}</select></label>
<label>Target<select name="kind"><option value="post">Post</option><option value="user">User</option></select></label><label>Target ID<input name="targetID" type="number" min="0" step="1" required></label>
<label>Action<select name="action"><option value="restrict">Restrict in iOS</option><option value="restore">Restore in iOS</option></select></label><label>Related report ID (optional)<input name="reportID"></label><label>Decision reason<textarea name="reason" required maxlength="2000"></textarea></label><button>Save decision</button></form>
<h2>Active restrictions</h2><pre id="restrictions"></pre><h2>Recent decisions</h2><pre id="audit"></pre>` : `<h2>Contact the iOS safety operator</h2><form id="contact"><label>Concern or appeal<textarea name="reason" required maxlength="2000" rows="6"></textarea></label><label>Your email (optional, only if you want a reply)<input name="replyEmail" type="email" maxlength="254" autocomplete="email"></label><p>Do not send passwords, Google tokens, private keys, or private photos. Closed report text is deleted after 90 days. Technical request data is used to limit abuse.</p><button>Send to operator</button></form>`}
<script src="/safety.js" defer><\/script></body></html>`;
}
__name(safetyHTML, "safetyHTML");
var safetyScript = `
const status = document.getElementById('status');
async function api(path, body) {
    const response = await fetch(path, body ? {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)} : {cache:'no-store'});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Request failed');
    return result;
}
function errorMessage(error) { status.textContent = error.message; }
const contact = document.getElementById('contact');
let reportID = crypto.randomUUID();
if (contact) {
    contact.addEventListener('input', () => { reportID = crypto.randomUUID(); });
    contact.addEventListener('submit', async event => {
        event.preventDefault(); const button = contact.querySelector('button'); button.disabled = true;
        try {
            const fields = Object.fromEntries(new FormData(contact));
            const result = await api('/api/safety/reports', {id:reportID,canisterID:document.body.dataset.canister,kind:'contact',reason:fields.reason,replyEmail:fields.replyEmail || null});
            status.textContent = 'Received. Reference: ' + result.id; contact.reset(); reportID = crypto.randomUUID();
        } catch(error) { errorMessage(error); } finally { button.disabled = false; }
    });
}
if (document.body.dataset.admin === 'true') {
    let before = null;
    let beforeID = null;
    const list = document.getElementById('reports');
    async function reload(older = false) {
        if (!older) { before = null; beforeID = null; }
        const query = new URLSearchParams({includeClosed:document.getElementById('report-view').value});
        if (before != null) { query.set('before', before); query.set('beforeID', beforeID); }
        const data = await api('/api/admin/safety/reports?' + query);
        if (!older) list.replaceChildren();
        for (const report of data.reports) {
            const card = document.createElement('article');
            const title = document.createElement('h2'); title.textContent = report.kind + ': ' + report.id; card.append(title);
            const details = document.createElement('p'); details.textContent = report.status + ' \u2014 Due: ' + new Date(report.received_at + 86400000).toLocaleString() + ' \u2014 Post: ' + (report.post_id ?? '\u2014') + ' / User: ' + (report.user_id ?? '\u2014'); card.append(details);
            const reason = document.createElement('pre'); reason.textContent = report.reason; card.append(reason);
            if (report.reply_email) { const reply = document.createElement('p'); reply.textContent = 'Reply email: ' + report.reply_email; card.append(reply); }
            if (report.post_id != null) { const link = document.createElement('a'); link.href = 'https://' + report.canister_id + '.icp0.io/#/post/' + report.post_id; link.textContent = 'Check original post (external; may contain unsafe content)'; link.target = '_blank'; link.rel = 'noopener noreferrer'; card.append(link); }
            for (const action of ['reviewing','resolved','dismissed']) {
                const button = document.createElement('button'); button.textContent = action;
                button.addEventListener('click', async () => {
                    const reason = prompt('Decision reason'); if (!reason?.trim()) return;
                    button.disabled = true;
                    try { await api('/api/admin/safety/actions', {canisterID:report.canister_id,reportID:report.id,action,reason}); status.textContent = 'Decision saved'; await reload(); }
                    catch(error) { errorMessage(error); } finally { button.disabled = false; }
                }); card.append(button);
            }
            list.append(card);
        }
        before = data.reports.at(-1)?.received_at ?? null;
        beforeID = data.reports.at(-1)?.id ?? null;
        document.getElementById('older').disabled = data.reports.length < 100;
        document.getElementById('restrictions').textContent = JSON.stringify(data.restrictions, null, 2);
        document.getElementById('audit').textContent = JSON.stringify(data.audit, null, 2);
    }
    document.getElementById('reload').addEventListener('click', () => reload().catch(errorMessage));
    document.getElementById('report-view').addEventListener('change', () => reload().catch(errorMessage));
    document.getElementById('older').addEventListener('click', () => reload(true).catch(errorMessage));
    document.getElementById('action').addEventListener('submit', async event => {
        event.preventDefault(); const form = event.currentTarget;
        const data = Object.fromEntries(new FormData(form)); data.targetID = Number(data.targetID); if (!data.reportID) delete data.reportID;
        if (!confirm(data.action + ' ' + data.kind + ' ' + data.targetID + ' for all official iOS users?')) return;
        const button = form.querySelector('button'); button.disabled = true;
        try { await api('/api/admin/safety/actions', data); status.textContent = 'Decision saved'; await reload(); }
        catch(error) { errorMessage(error); } finally { button.disabled = false; }
    });
    reload().catch(errorMessage);
}
`;

// src/safety.mjs
var encoder = new TextEncoder();
var headers = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "x-frame-options": "DENY",
  "content-security-policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
};
var json = /* @__PURE__ */ __name((value, status = 200) => Response.json(value, { status, headers }), "json");
var fail = /* @__PURE__ */ __name((message, status = 400) => {
  throw Object.assign(new Error(message), { status });
}, "fail");
var integer = /* @__PURE__ */ __name((value) => Number.isSafeInteger(value) && value >= 0, "integer");
var canisters = /* @__PURE__ */ __name((env) => (env.SAFETY_CANISTERS || "").split(",").filter(Boolean), "canisters");
var uuid = /* @__PURE__ */ __name((value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
  value
), "uuid");
async function boundedJSON(request) {
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
  try {
    return JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes)
    );
  } catch {
    fail("Invalid JSON");
  }
}
__name(boundedJSON, "boundedJSON");
function validateReport(body, env) {
  if (!body || !uuid(body.id) || !canisters(env).includes(body.canisterID))
    fail("Invalid report target");
  if (!["post", "user", "block", "contact"].includes(body.kind))
    fail("Invalid report kind");
  if (body.kind === "post" && !integer(body.postID)) fail("Post ID required");
  if (body.kind !== "contact" && !integer(body.userID))
    fail("User ID required");
  if (body.userID != null && !integer(body.userID)) fail("Invalid user ID");
  if (body.kind !== "post" && body.postID != null) fail("Unexpected post ID");
  if (body.kind !== "contact" && body.replyEmail != null)
    fail("Reply email is only accepted for contact requests");
  if (typeof body.reason !== "string" || !body.reason.trim() || [...body.reason].length > 2e3)
    fail("Reason must be 1\u20132000 characters");
  if (body.replyEmail != null && (typeof body.replyEmail !== "string" || body.replyEmail.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.replyEmail)))
    fail("Invalid reply email");
  return { ...body, reason: body.reason.trim() };
}
__name(validateReport, "validateReport");
function checkOrigin(request, env, required = false) {
  const origin = request.headers.get("origin");
  if ((required || origin) && origin !== env.SAFETY_ORIGIN)
    fail("Invalid origin", 403);
}
__name(checkOrigin, "checkOrigin");
async function rateLimit(request, env, now) {
  if (!env.SAFETY_RATE_SALT) fail("Safety service is not configured", 503);
  const ip = request.headers.get("cf-connecting-ip") || "local";
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(env.SAFETY_RATE_SALT),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const hash = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(ip))
  );
  const bucket = `${Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("")}:${Math.floor(now / 3e5)}`;
  const row = await env.SAFETY_DB.prepare(
    "INSERT INTO safety_rate_limits VALUES(?1,1,?2) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count"
  ).bind(bucket, now + 864e5).first();
  if (row.count > 10)
    fail("Too many reports. Please retry in five minutes.", 429);
}
__name(rateLimit, "rateLimit");
function decodeBase64URL(value) {
  return Uint8Array.from(
    atob(value.replace(/-/g, "+").replace(/_/g, "/")),
    (char) => char.charCodeAt(0)
  );
}
__name(decodeBase64URL, "decodeBase64URL");
async function verifyAdmin(request, env, fetcher = fetch) {
  if (!env.ACCESS_ISSUER || !env.ACCESS_AUD || !env.SAFETY_ADMIN_EMAIL)
    fail("Admin access is not configured", 503);
  const token = request.headers.get("cf-access-jwt-assertion");
  if (!token || token.length > 16e3) fail("Authentication required", 401);
  try {
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error();
    const header2 = JSON.parse(
      new TextDecoder().decode(decodeBase64URL(parts[0]))
    );
    const claims = JSON.parse(
      new TextDecoder().decode(decodeBase64URL(parts[1]))
    );
    const now = Date.now() / 1e3;
    if (header2.alg !== "RS256" || claims.iss !== env.ACCESS_ISSUER || !Array.isArray(claims.aud) || !claims.aud.includes(env.ACCESS_AUD) || !Number.isFinite(claims.exp) || claims.exp <= now || claims.nbf != null && claims.nbf > now || claims.email !== env.SAFETY_ADMIN_EMAIL)
      throw new Error();
    const response = await fetcher(
      `${env.ACCESS_ISSUER}/cdn-cgi/access/certs`,
      { signal: AbortSignal.timeout(5e3) }
    );
    if (!response.ok) throw new Error();
    const { keys } = await response.json();
    const jwk = keys.find(
      (key2) => key2.kid === header2.kid && key2.kty === "RSA"
    );
    if (!jwk) throw new Error();
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );
    if (!await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      decodeBase64URL(parts[2]),
      encoder.encode(`${parts[0]}.${parts[1]}`)
    ))
      throw new Error();
    return claims.email;
  } catch {
    fail("Invalid administrator credentials", 403);
  }
}
__name(verifyAdmin, "verifyAdmin");
async function policy(url, env) {
  const canisterID = url.searchParams.get("canisterID");
  if (!canisters(env).includes(canisterID)) fail("Unsupported canister");
  const [version, rows] = await env.SAFETY_DB.batch([
    env.SAFETY_DB.prepare("SELECT version FROM safety_version WHERE id=1"),
    env.SAFETY_DB.prepare(
      "SELECT kind,target_id FROM restrictions WHERE canister_id=?1 AND active=1"
    ).bind(canisterID)
  ]);
  const issuedAt = Date.now() / 1e3;
  return json({
    canisterID,
    version: version.results[0].version,
    issuedAt,
    expiresAt: issuedAt + 900,
    postIDs: rows.results.filter((row) => row.kind === "post").map((row) => row.target_id),
    userIDs: rows.results.filter((row) => row.kind === "user").map((row) => row.target_id)
  });
}
__name(policy, "policy");
async function receive(request, env, ctx) {
  checkOrigin(request, env);
  const body = validateReport(await boundedJSON(request), env);
  const now = Date.now();
  await rateLimit(request, env, now);
  await env.SAFETY_DB.batch([
    env.SAFETY_DB.prepare(
      "INSERT OR IGNORE INTO reports(id,canister_id,kind,post_id,user_id,reason,reply_email,received_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)"
    ).bind(
      body.id,
      body.canisterID,
      body.kind,
      body.postID ?? null,
      body.userID ?? null,
      body.reason,
      body.replyEmail ?? null,
      now
    ),
    env.SAFETY_DB.prepare(
      "INSERT OR IGNORE INTO notification_outbox(report_id,stage,next_attempt_at) VALUES(?1,0,?2)"
    ).bind(body.id, now)
  ]);
  const saved = await env.SAFETY_DB.prepare(
    "SELECT * FROM reports WHERE id=?1"
  ).bind(body.id).first();
  if (!saved || saved.canister_id !== body.canisterID || saved.kind !== body.kind || saved.post_id !== (body.postID ?? null) || saved.user_id !== (body.userID ?? null) || saved.reason !== body.reason || saved.reply_email !== (body.replyEmail ?? null))
    fail("Report ID already used", 409);
  ctx.waitUntil(deliverNotifications(env));
  return json({ id: body.id, status: "received" }, 201);
}
__name(receive, "receive");
async function deliverNotifications(env) {
  if (!env.SAFETY_DB || !env.SAFETY_EMAIL || !env.SAFETY_ADMIN_EMAIL || !env.SAFETY_FROM_EMAIL)
    return;
  const now = Date.now();
  const { results } = await env.SAFETY_DB.prepare(
    "SELECT n.report_id,n.stage,r.received_at FROM notification_outbox n JOIN reports r ON r.id=n.report_id WHERE n.delivered_at IS NULL AND n.next_attempt_at<=?1 AND (n.stage=0 OR r.status IN ('open','reviewing')) ORDER BY n.next_attempt_at LIMIT 20"
  ).bind(now).all();
  for (const row of results) {
    const claimed = await env.SAFETY_DB.prepare(
      "UPDATE notification_outbox SET attempts=attempts+1,next_attempt_at=?1 WHERE report_id=?2 AND stage=?3 AND delivered_at IS NULL AND next_attempt_at<=?4 RETURNING attempts"
    ).bind(now + 3e5, row.report_id, row.stage, now).first();
    if (!claimed) continue;
    try {
      const text = `TAGGR iOS safety report ${row.report_id}
${row.stage ? `${row.stage}-hour reminder
` : ""}Review and act by ${new Date(row.received_at + 864e5).toISOString()}.
${env.SAFETY_ORIGIN}/admin/safety`;
      await env.SAFETY_EMAIL.send({
        from: env.SAFETY_FROM_EMAIL,
        to: env.SAFETY_ADMIN_EMAIL,
        subject: `TAGGR safety: ${row.stage ? "action reminder" : "new report"}`,
        text,
        html: `<p>${text.split("\n").join("<br>")}</p>`
      });
      await env.SAFETY_DB.prepare(
        "UPDATE notification_outbox SET delivered_at=?1 WHERE report_id=?2 AND stage=?3"
      ).bind(Date.now(), row.report_id, row.stage).run();
    } catch {
      await env.SAFETY_DB.prepare(
        "UPDATE notification_outbox SET next_attempt_at=?1 WHERE report_id=?2 AND stage=?3"
      ).bind(
        now + Math.min(
          216e5,
          3e5 * 2 ** Math.min(claimed.attempts, 6)
        ),
        row.report_id,
        row.stage
      ).run();
      console.error("safety_notification_failed", {
        reportID: row.report_id,
        stage: row.stage
      });
    }
  }
}
__name(deliverNotifications, "deliverNotifications");
async function scheduledSafety(env) {
  if (!env.SAFETY_DB) return;
  const now = Date.now();
  await env.SAFETY_DB.batch([
    ...[12, 20].map(
      (stage) => env.SAFETY_DB.prepare(
        "INSERT OR IGNORE INTO notification_outbox(report_id,stage,next_attempt_at) SELECT id,?1,?2 FROM reports WHERE status IN ('open','reviewing') AND received_at<=?3"
      ).bind(stage, now, now - stage * 36e5)
    ),
    env.SAFETY_DB.prepare(
      "DELETE FROM reports WHERE closed_at IS NOT NULL AND closed_at<?1"
    ).bind(now - 90 * 864e5),
    env.SAFETY_DB.prepare(
      "DELETE FROM safety_rate_limits WHERE expires_at<?1"
    ).bind(now)
  ]);
  await deliverNotifications(env);
}
__name(scheduledSafety, "scheduledSafety");
async function adminAction(request, env, actor) {
  checkOrigin(request, env, true);
  const body = await boundedJSON(request);
  if (!body || !canisters(env).includes(body.canisterID) || typeof body.reason !== "string" || !body.reason.trim() || [...body.reason].length > 2e3)
    fail("Target and reason required");
  if (!["restrict", "restore", "reviewing", "dismissed", "resolved"].includes(
    body.action
  ))
    fail("Invalid action");
  if (body.reportID != null) {
    if (!uuid(body.reportID)) fail("Invalid report");
    const report = await env.SAFETY_DB.prepare(
      "SELECT canister_id FROM reports WHERE id=?1"
    ).bind(body.reportID).first();
    if (!report || report.canister_id !== body.canisterID)
      fail("Report not found", 404);
  }
  const statements = [];
  if (["restrict", "restore"].includes(body.action)) {
    if (!["post", "user"].includes(body.kind) || !integer(body.targetID))
      fail("Invalid restriction target");
    statements.push(
      env.SAFETY_DB.prepare(
        "INSERT INTO restrictions VALUES(?1,?2,?3,?4) ON CONFLICT(canister_id,kind,target_id) DO UPDATE SET active=excluded.active"
      ).bind(
        body.canisterID,
        body.kind,
        body.targetID,
        body.action === "restrict" ? 1 : 0
      )
    );
    statements.push(
      env.SAFETY_DB.prepare(
        "UPDATE safety_version SET version=version+1 WHERE id=1"
      )
    );
  } else {
    if (!body.reportID) fail("Report required");
    statements.push(
      env.SAFETY_DB.prepare(
        "UPDATE reports SET status=?1,closed_at=?2 WHERE id=?3"
      ).bind(
        body.action,
        body.action === "reviewing" ? null : Date.now(),
        body.reportID
      )
    );
  }
  statements.push(
    env.SAFETY_DB.prepare(
      "INSERT INTO safety_audit VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"
    ).bind(
      crypto.randomUUID(),
      body.reportID ?? null,
      body.canisterID,
      body.kind ?? "report",
      body.targetID ?? null,
      body.action,
      body.reason.trim(),
      actor,
      Date.now()
    )
  );
  await env.SAFETY_DB.batch(statements);
  return json({ status: "saved" });
}
__name(adminAction, "adminAction");
async function safetyFetch(request, env, ctx) {
  const url = new URL(request.url);
  if (!["/safety", "/safety.js", "/admin/safety"].includes(url.pathname) && !url.pathname.startsWith("/api/safety/") && !url.pathname.startsWith("/api/admin/safety/"))
    return null;
  try {
    if (url.pathname === "/safety.js" && request.method === "GET")
      return new Response(safetyScript, {
        headers: {
          ...headers,
          "content-type": "text/javascript; charset=utf-8"
        }
      });
    if (url.pathname === "/safety" && request.method === "GET")
      return new Response(safetyHTML(false, canisters(env)), {
        headers: {
          ...headers,
          "content-type": "text/html; charset=utf-8"
        }
      });
    const admin = url.pathname === "/admin/safety" || url.pathname.startsWith("/api/admin/safety/");
    const actor = admin ? await verifyAdmin(request, env) : null;
    if (url.pathname === "/admin/safety" && request.method === "GET")
      return new Response(safetyHTML(true, canisters(env)), {
        headers: {
          ...headers,
          "content-type": "text/html; charset=utf-8"
        }
      });
    if (!env.SAFETY_DB) fail("Safety service is not configured", 503);
    if (url.pathname === "/api/safety/policy" && request.method === "GET")
      return await policy(url, env);
    if (url.pathname === "/api/safety/reports" && request.method === "POST")
      return await receive(request, env, ctx);
    if (url.pathname === "/api/admin/safety/reports" && request.method === "GET") {
      const before = Number(
        url.searchParams.get("before") || Date.now() + 1
      );
      if (!Number.isSafeInteger(before) || before < 0)
        fail("Invalid cursor");
      const beforeID = url.searchParams.get("beforeID") || "~";
      if (beforeID !== "~" && !uuid(beforeID)) fail("Invalid cursor ID");
      const reports = await env.SAFETY_DB.prepare(
        "SELECT * FROM reports WHERE (received_at<?1 OR (received_at=?1 AND id<?2)) AND (?3=1 OR status IN ('open','reviewing')) ORDER BY received_at DESC,id DESC LIMIT 100"
      ).bind(
        before,
        beforeID,
        url.searchParams.get("includeClosed") === "1" ? 1 : 0
      ).all();
      const restrictions = await env.SAFETY_DB.prepare(
        "SELECT * FROM restrictions WHERE active=1"
      ).all();
      const audit = await env.SAFETY_DB.prepare(
        "SELECT * FROM safety_audit ORDER BY created_at DESC LIMIT 100"
      ).all();
      return json({
        reports: reports.results,
        restrictions: restrictions.results,
        audit: audit.results
      });
    }
    if (url.pathname === "/api/admin/safety/actions" && request.method === "POST")
      return await adminAction(request, env, actor);
    return json({ error: "Not found" }, 404);
  } catch (error) {
    if (!error.status)
      console.error("safety_request_failed", { path: url.pathname });
    return json(
      {
        error: error.status ? error.message : "Safety service temporarily unavailable"
      },
      error.status || 503
    );
  }
}
__name(safetyFetch, "safetyFetch");

// src/index.mjs
var SOURCE_URL = "https://github.com/TaggrNetwork/Taggr";
var POLICY_EFFECTIVE_DATE = "September 9, 2026";
var styles = `
:root {
  color-scheme: dark;
  --ink: #f2f3ee;
  --muted: #a9aca4;
  --panel: #202126;
  --line: #373940;
  --cyan: #43d7cc;
  --yellow: #ffe100;
  --black: #111216;
}
* { box-sizing: border-box; }
html { background: var(--black); }
body {
  margin: 0;
  color: var(--ink);
  background:
    linear-gradient(90deg, rgba(67,215,204,.035) 1px, transparent 1px),
    linear-gradient(rgba(67,215,204,.035) 1px, transparent 1px),
    var(--black);
  background-size: 32px 32px;
  font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 17px;
  line-height: 1.65;
}
a { color: var(--cyan); text-underline-offset: .2em; }
a:hover { color: var(--ink); }
a:focus-visible { outline: 3px solid var(--yellow); outline-offset: 4px; }
.shell { width: min(760px, calc(100% - 40px)); margin: 0 auto; }
header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  padding: 28px 0;
  border-bottom: 1px solid var(--line);
}
.brand { display: inline-flex; align-items: center; gap: 12px; color: var(--ink); text-decoration: none; }
.mark {
  display: grid;
  place-items: center;
  width: 42px;
  height: 42px;
  color: var(--black);
  background: var(--yellow);
  border-radius: 8px;
  font: 900 25px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.wordmark { font-weight: 850; letter-spacing: .06em; }
nav { display: flex; flex-wrap: wrap; gap: 16px; font-size: 14px; }
main { padding: 72px 0 96px; }
.eyebrow { color: var(--cyan); font: 700 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .12em; text-transform: uppercase; }
h1 { max-width: 690px; margin: 18px 0 22px; font-size: clamp(40px, 8vw, 72px); line-height: .98; letter-spacing: -.055em; }
.legal h1 { font-size: clamp(38px, 7vw, 62px); }
h2 { margin: 52px 0 14px; font-size: 25px; line-height: 1.2; letter-spacing: -.02em; }
h3 { margin: 30px 0 8px; font-size: 18px; }
p, li { color: #d6d8d1; }
.lead { max-width: 650px; color: var(--ink); font-size: 21px; }
.actions { display: flex; flex-wrap: wrap; gap: 12px; margin: 34px 0 58px; }
.button { display: inline-block; padding: 11px 17px; border: 1px solid var(--cyan); border-radius: 7px; text-decoration: none; font-weight: 750; }
.button.primary { color: var(--black); background: var(--cyan); }
.facts { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1px; margin: 50px 0; padding: 1px; background: var(--line); border-radius: 10px; overflow: hidden; }
.fact { min-height: 140px; padding: 22px; background: var(--panel); }
.fact strong { display: block; margin-bottom: 8px; color: var(--yellow); font: 800 13px/1.3 ui-monospace, SFMono-Regular, Menlo, monospace; text-transform: uppercase; }
.fact span { color: var(--ink); font-weight: 700; }
.note { margin: 32px 0; padding: 20px 22px; border-left: 4px solid var(--yellow); background: var(--panel); }
.meta { color: var(--muted); font-size: 14px; }
ul { padding-left: 24px; }
li + li { margin-top: 8px; }
footer { padding: 26px 0 42px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }
@media (max-width: 650px) {
  header { align-items: flex-start; flex-direction: column; }
  main { padding-top: 52px; }
  .facts { grid-template-columns: 1fr; }
  .fact { min-height: auto; }
}
@media (prefers-reduced-motion: no-preference) {
  .mark { transition: transform .18s ease; }
  .brand:hover .mark { transform: rotate(-4deg); }
}
`;
var header = `
<header>
  <a class="brand" href="/" aria-label="TAGGR home"><span class="mark" aria-hidden="true">#</span><span class="wordmark">TAGGR</span></a>
  <nav aria-label="Legal information"><a href="/privacy-policy">Privacy</a><a href="/terms">Terms</a></nav>
</header>`;
var footer = `
<footer>
  <div>TAGGR is a decentralized social network on the Internet Computer.</div>
  <div><a href="/privacy-policy">Privacy</a> \xB7 <a href="/terms">Terms</a> \xB7 <a href="${SOURCE_URL}">Open-source project</a></div>
</footer>`;
function layout({ title, description, body, legal = false }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="${description}">
  <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='12' fill='%23ffe100'/%3E%3Ctext x='32' y='47' text-anchor='middle' font-size='46' font-family='monospace' font-weight='900'%3E%23%3C/text%3E%3C/svg%3E">
  <title>${title}</title>
  <style>${styles}</style>
</head>
<body>
  <div class="shell">${header}<main${legal ? ' class="legal"' : ""}>${body}</main>${footer}</div>
</body>
</html>`;
}
__name(layout, "layout");
var home = layout({
  title: "TAGGR \u2014 Decentralized social networking",
  description: "Official information, privacy policy, and terms for the TAGGR iOS app.",
  body: `
      <div class="eyebrow">Official TAGGR iOS app information</div>
      <h1>TAGGR is a decentralized social network and publishing app.</h1>
      <p class="lead">TAGGR runs on the Internet Computer. Its iOS app lets people read and publish posts, join topic-based communities, manage their public profile and wallet, and optionally upload a video they select to their own YouTube channel.</p>
      <p>This public website explains the TAGGR app, its optional Google and YouTube integration, and its data practices. All app-information and legal pages are publicly accessible; safety administration is private.</p>
      <div class="actions"><a class="button primary" href="/privacy-policy">Read the TAGGR Privacy Policy</a><a class="button" href="/terms">Read the Terms of Use</a></div>
      <h2>What the TAGGR iOS app does</h2>
      <ul>
        <li>Displays public TAGGR posts, profiles, reactions, and communities.</li>
        <li>Lets a TAGGR user create posts and interact with communities.</li>
        <li>Lets a user review wallet information and initiate supported wallet actions.</li>
        <li>Optionally connects the user\u2019s Google account so the user can upload a selected video to their own YouTube channel.</li>
      </ul>
      <div class="facts" aria-label="TAGGR principles">
        <div class="fact"><strong>Public by design</strong><span>Posts and profiles can be stored on-chain and visible to anyone.</span></div>
        <div class="fact"><strong>User initiated</strong><span>Wallet actions and YouTube uploads happen only when a signed-in user starts them.</span></div>
        <div class="fact"><strong>No ad tracking</strong><span>The iOS app contains no advertising or analytics SDK.</span></div>
      </div>
      <h2>YouTube connection</h2>
      <p>YouTube connection is optional. TAGGR requests Google user data only to identify the YouTube channel chosen by the signed-in user and to upload a video when that user explicitly starts an upload. TAGGR does not use Google user data for advertising, analytics, or unrelated features.</p>
      <p>The selected video is transferred directly from the iOS device to YouTube. Videos and Google authorization tokens are not sent to TAGGR canisters or a developer-operated server. Full details about the Google data accessed, its use, device storage, sharing, retention, revocation, and deletion are in the <a href="/privacy-policy">TAGGR Privacy Policy</a>.</p>
    `
});
var privacy = layout({
  title: "Privacy Policy \u2014 TAGGR",
  description: "How the TAGGR iOS app accesses, uses, stores, shares, and deletes data, including Google user data.",
  legal: true,
  body: `
      <div class="eyebrow">Legal</div>
      <h1>TAGGR iOS App Privacy Policy</h1>
      <p class="meta">Effective ${POLICY_EFFECTIVE_DATE}</p>
      <p class="lead">This policy applies specifically to the TAGGR iOS app and explains how it accesses, uses, stores, shares, retains, and deletes information, including Google and YouTube user data. TAGGR is a decentralized social network, so information a user chooses to publish can be public and stored on-chain.</p>
      <p>This is the official privacy policy for the TAGGR iOS app, maintained by the TAGGR open-source project. It is not a template or a policy for an unrelated service.</p>

      <h2>Google user data disclosure summary</h2>
      <ul>
        <li><strong>Data collected or accessed:</strong> the connected YouTube channel ID and title, Google authorization credentials, and the video and metadata the user explicitly selects for upload.</li>
        <li><strong>Purpose:</strong> to display the destination channel and upload the selected video to that channel only when the user requests it.</li>
        <li><strong>Storage:</strong> Google credentials and temporary upload state remain in protected storage on the user\u2019s iOS device; they are not stored in a TAGGR canister or developer-operated server.</li>
        <li><strong>Sharing:</strong> the selected upload data is transferred only to Google/YouTube to perform the requested upload. TAGGR does not sell it or disclose it to advertisers or data brokers.</li>
        <li><strong>Retention and deletion:</strong> incomplete local upload jobs expire after seven days. Disconnecting YouTube revokes authorization and deletes local YouTube upload state.</li>
      </ul>

      <h2>Information handled by TAGGR</h2>
      <ul>
        <li>Posts, comments, reactions, reports, realm activity, uploaded files, and profile information a user chooses to submit.</li>
        <li>Public identifiers, including Internet Identity principals and TAGGR user identifiers.</li>
        <li>Public ledger information and wallet actions expressly initiated by the signed-in user.</li>
        <li>An Internet Identity session stored locally on the device to keep the user signed in.</li>
      </ul>
      <p>Public content and public identifiers submitted to the Internet Computer may be visible to anyone and may not be fully erasable because of the decentralized, append-only nature of the service.</p>

      <h2>Google and YouTube user data</h2>
      <p>Connecting YouTube is optional and begins only when the user selects \u201CConnect YouTube.\u201D Google shows a consent screen before access is granted.</p>
      <h3>Data accessed</h3>
      <ul>
        <li><code>youtube.readonly</code>: the ID and title of the user\u2019s YouTube channel, obtained with <code>channels.list</code> and <code>mine=true</code>.</li>
        <li><code>youtube.upload</code>: permission to upload a video selected by the user and set the title, description, and privacy status entered by the user.</li>
        <li>Google OAuth access and refresh credentials managed by the Google Sign-In SDK on the user\u2019s device.</li>
      </ul>
      <h3>How the data is used</h3>
      <p>The channel ID and title are used only to show and verify the destination channel before upload. Authorization credentials are used only to access the YouTube Data API for the connected account. A completed video\u2019s canonical YouTube URL is inserted into the user\u2019s TAGGR draft and becomes public only if the user submits that draft.</p>
      <h3>Storage and retention</h3>
      <p>Google authorization credentials are stored by Google Sign-In in protected device storage. TAGGR does not send them to a TAGGR canister or a developer-operated server. A selected video and resumable-upload metadata may be stored temporarily in protected app storage so an interrupted upload can continue. Upload jobs are removed after completion is acknowledged, cancellation, explicit disconnection, or expiry; incomplete jobs expire after seven days.</p>
      <h3>Sharing</h3>
      <p>The selected video and metadata are sent directly from the device to YouTube at the user\u2019s request. TAGGR does not sell Google user data, use it for advertising, or share it with data brokers. Google user data is not used to train generalized artificial intelligence or machine-learning models.</p>
      <h3>Disconnecting and deleting Google data</h3>
      <p>A user can select \u201CDisconnect YouTube\u201D in TAGGR. This revokes TAGGR\u2019s Google authorization and removes local YouTube upload state. A user can also revoke access at <a href="https://myaccount.google.com/connections">Google Account Connections</a>. Videos already uploaded to YouTube remain in the user\u2019s YouTube account and can be managed or deleted there.</p>
      <div class="note">TAGGR\u2019s use and transfer of information received from Google APIs adheres to the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including the Limited Use requirements.</div>

      <h2>Photos and videos</h2>
      <p>The app accesses only media the user explicitly selects with the system picker. TAGGR does not scan the user\u2019s photo library. A video selected for YouTube is handled as described above.</p>

      <h2>Analytics, advertising, and tracking</h2>
      <p>The TAGGR iOS app contains no analytics SDK or advertising SDK and does not perform advertising tracking. It does not collect native contacts, precise location, microphone recordings, HealthKit data, or push-notification tokens.</p>

      <h2>Third-party services</h2>
      <p>Internet Identity provides authentication. Google Sign-In and the YouTube Data API provide optional YouTube connection and upload. Public Internet Computer ledgers provide wallet information. External community links open their respective services, whose own terms and privacy policies apply.</p>

      <h2>Security</h2>
      <p>The iOS app uses platform-protected storage for authentication and upload state. No system can guarantee absolute security. Users should protect access to their device and disconnect services they no longer use.</p>

      <h2>Children</h2>
      <p>TAGGR is not directed to children under the age required to consent to online services in their jurisdiction.</p>

      <h2>iOS safety reports and moderation</h2>
      <p>When you report content, block a user, or contact the iOS safety operator, the app or contact form sends the target canister, post or user IDs, your reason, a random request ID, and an optional reply email to the developer-operated Cloudflare service. Google tokens, Internet Identity private keys, and your photo library are not sent. Reports are unverified submissions and never automatically suspend an account.</p>
      <p>Cloudflare Workers and D1 process and store reports. The operator receives a private email notification containing a report reference, deadline, and management link. Closed report text and optional reply emails are deleted after 90 days. Active restrictions and decision records are retained as needed to enforce restrictions and handle appeals. Do not include private information in a report. Request IP addresses are processed for abuse prevention; hashed rate-limit records expire after one day. Cloudflare may process network data under its service policies.</p>
      <p>Terms acceptance version and time, personal blocks, pending block notifications, and a short-lived moderation policy cache are stored on your device. The app checks the safety policy using the target canister ID without sending your Google or Internet Identity credentials.</p>
      <h2>Changes and contact</h2>
      <p>This policy may be updated when TAGGR\u2019s data practices change. The effective date above identifies the current version. Contact the iOS operator privately through the <a href="/safety">safety and contact form</a>. Do not post private safety reports to a public issue tracker.</p>
    `
});
var terms = layout({
  title: "Terms of Use \u2014 TAGGR",
  description: "Terms governing use of the TAGGR iOS app and its optional YouTube upload feature.",
  legal: true,
  body: `
      <div class="eyebrow">Legal</div>
      <h1>Terms of Use</h1>
      <p class="meta">Effective ${POLICY_EFFECTIVE_DATE}</p>
      <p class="lead">These terms apply to the TAGGR iOS app and the official services described on this site. By using TAGGR, you agree to use the service lawfully and take responsibility for the content and transactions you initiate.</p>

      <h2>Decentralized service</h2>
      <p>TAGGR runs on the Internet Computer. Public posts, profiles, identifiers, moderation records, and ledger activity can be visible to anyone and may remain available after publication. Availability, governance decisions, and protocol behavior can depend on decentralized infrastructure outside the control of individual app maintainers.</p>

      <h2>Your account and actions</h2>
      <p>You are responsible for securing your device and authentication methods. Wallet transfers, reward withdrawals, credit minting, publication, and other actions occur only when you initiate them. Review destinations and amounts before confirming irreversible actions.</p>

      <h2>Your content</h2>
      <p>You retain responsibility for content you submit. You must have the rights and permissions necessary to publish it. Do not submit unlawful content, malware, impersonation, targeted harassment, or material that infringes another person\u2019s privacy or intellectual-property rights. Community and realm moderation rules may also apply.</p>

      <h2>YouTube uploads</h2>
      <p>YouTube connection is optional. You may upload only videos you are authorized to upload. Your use of YouTube is also governed by the <a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a> and the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>. Disconnecting TAGGR does not delete videos already uploaded to your YouTube channel.</p>

      <h2>No warranty</h2>
      <p>TAGGR is provided on an \u201Cas is\u201D and \u201Cas available\u201D basis to the extent permitted by law. No guarantee is made that the service will be uninterrupted, error-free, or suitable for a particular purpose. Nothing on TAGGR constitutes financial, legal, or investment advice.</p>

      <h2>iOS end-user agreement and safety</h2>
      <p>You must explicitly accept this agreement before using user-generated content in the iOS app. There is zero tolerance for objectionable content or abusive users, including sexual exploitation, pornography, threats, targeted harassment, hateful abuse, and illegal material. Do not upload or link to such content.</p>
      <p>The iOS app does not display posts marked NSFW and filters existing moderation restrictions. Use Report on a post or profile to notify the operator without any token or credit requirement. Block immediately removes that user's content from your iOS experience and notifies the operator. Reports and blocks are reviewed, not treated as automatic proof of a violation.</p>
      <p>The iOS operator reviews reports and acts on violations within 24 hours, removing violating content from the official iOS app and suspending the responsible users' access to that app. These actions do not delete data from Internet Computer canisters or prevent use through independent clients. Unmarked objectionable content may escape filtering; please report it.</p>
      <p>Contact the operator or appeal a restriction through the <a href="/safety">safety and contact form</a>. The iOS app requires a recent safety policy to display or publish user-generated content; during an extended safety-service outage these features are temporarily unavailable.</p>
      <h2>Changes and support</h2>
      <p>These terms may be updated as the service changes. The effective date above identifies the current version. Questions and public issue reports can be submitted through the <a href="${SOURCE_URL}/issues">TAGGR open-source project issue tracker</a>.</p>
    `
});
var pages = /* @__PURE__ */ new Map([
  ["/", home],
  ["/about", home],
  ["/about/", home],
  ["/privacy", privacy],
  ["/privacy/", privacy],
  ["/privacy-policy", privacy],
  ["/privacy-policy/", privacy],
  ["/terms", terms],
  ["/terms/", terms]
]);
var securityHeaders = {
  "cache-control": "public, max-age=0, must-revalidate, no-transform",
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "permissions-policy": "camera=(), geolocation=(), microphone=()",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY"
};
var index_default = {
  async scheduled(_event, env) {
    await scheduledSafety(env);
  },
  async fetch(request, env = {}, ctx = { waitUntil() {
  } }) {
    const safety = await safetyFetch(request, env, ctx);
    if (safety) return safety;
    const url = new URL(request.url);
    const method = request.method.toUpperCase();
    if (method !== "GET" && method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { allow: "GET, HEAD" }
      });
    }
    if (url.pathname === "/robots.txt") {
      return new Response(
        method === "HEAD" ? null : "User-agent: *\nAllow: /\n",
        {
          headers: {
            "content-type": "text/plain; charset=utf-8",
            ...securityHeaders
          }
        }
      );
    }
    const page = pages.get(url.pathname);
    if (!page) {
      return new Response(method === "HEAD" ? null : "Not Found", {
        status: 404,
        headers: securityHeaders
      });
    }
    return new Response(method === "HEAD" ? null : page, {
      headers: {
        "cache-control": "public, max-age=300",
        "content-type": "text/html; charset=utf-8",
        ...securityHeaders
      }
    });
  }
};
export {
  index_default as default
};
//# sourceMappingURL=index.js.map
