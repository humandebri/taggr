import { moderationFetch } from "./moderation.mjs";

const SOURCE_URL = "https://github.com/TaggrNetwork/Taggr";
const POLICY_EFFECTIVE_DATE = "September 9, 2026";

const styles = `
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

const header = `
<header>
  <a class="brand" href="/" aria-label="TAGGR home"><span class="mark" aria-hidden="true">#</span><span class="wordmark">TAGGR</span></a>
  <nav aria-label="Legal information"><a href="/privacy-policy">Privacy</a><a href="/terms">Terms</a></nav>
</header>`;

const footer = `
<footer>
  <div>TAGGR is a decentralized social network on the Internet Computer.</div>
  <div><a href="/privacy-policy">Privacy</a> · <a href="/terms">Terms</a> · <a href="${SOURCE_URL}">Open-source project</a></div>
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

const home = layout({
    title: "TAGGR — Decentralized social networking",
    description:
        "Official information, privacy policy, and terms for the TAGGR iOS app.",
    body: `
      <div class="eyebrow">Official TAGGR iOS app information</div>
      <h1>TAGGR is a decentralized social network and publishing app.</h1>
      <p class="lead">TAGGR runs on the Internet Computer. Its iOS app lets people read and publish posts, join topic-based communities, manage their public profile and wallet, and optionally upload a video they select to their own YouTube channel.</p>
      <p>This public website explains the TAGGR app, its optional Google and YouTube integration, and its data practices. All app-information and legal pages are publicly accessible.</p>
      <div class="actions"><a class="button primary" href="/privacy-policy">Read the TAGGR Privacy Policy</a><a class="button" href="/terms">Read the Terms of Use</a></div>
      <h2>What the TAGGR iOS app does</h2>
      <ul>
        <li>Displays public TAGGR posts, profiles, reactions, and communities.</li>
        <li>Lets a TAGGR user create posts and interact with communities.</li>
        <li>Lets a user review wallet information and initiate supported wallet actions.</li>
        <li>Optionally connects the user’s Google account so the user can upload a selected video to their own YouTube channel.</li>
      </ul>
      <div class="facts" aria-label="TAGGR principles">
        <div class="fact"><strong>Public by design</strong><span>Posts and profiles can be stored on-chain and visible to anyone.</span></div>
        <div class="fact"><strong>User initiated</strong><span>Wallet actions and YouTube uploads happen only when a signed-in user starts them.</span></div>
        <div class="fact"><strong>No ad tracking</strong><span>The iOS app contains no advertising or analytics SDK.</span></div>
      </div>
      <h2>YouTube connection</h2>
      <p>YouTube connection is optional. TAGGR requests Google user data only to identify the YouTube channel chosen by the signed-in user and to upload a video when that user explicitly starts an upload. TAGGR does not use Google user data for advertising, analytics, or unrelated features.</p>
      <p>The selected video is transferred directly from the iOS device to YouTube. Videos and Google authorization tokens are not sent to TAGGR canisters or a developer-operated server. Full details about the Google data accessed, its use, device storage, sharing, retention, revocation, and deletion are in the <a href="/privacy-policy">TAGGR Privacy Policy</a>.</p>
    `,
});

const privacy = layout({
    title: "Privacy Policy — TAGGR",
    description:
        "How the TAGGR iOS app accesses, uses, stores, shares, and deletes data, including Google user data.",
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
        <li><strong>Storage:</strong> Google credentials and temporary upload state remain in protected storage on the user’s iOS device; they are not stored in a TAGGR canister or developer-operated server.</li>
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
      <p>Connecting YouTube is optional and begins only when the user selects “Connect YouTube.” Google shows a consent screen before access is granted.</p>
      <h3>Data accessed</h3>
      <ul>
        <li><code>youtube.readonly</code>: the ID and title of the user’s YouTube channel, obtained with <code>channels.list</code> and <code>mine=true</code>.</li>
        <li><code>youtube.upload</code>: permission to upload a video selected by the user and set the title, description, and privacy status entered by the user.</li>
        <li>Google OAuth access and refresh credentials managed by the Google Sign-In SDK on the user’s device.</li>
      </ul>
      <h3>How the data is used</h3>
      <p>The channel ID and title are used only to show and verify the destination channel before upload. Authorization credentials are used only to access the YouTube Data API for the connected account. A completed video’s canonical YouTube URL is inserted into the user’s TAGGR draft and becomes public only if the user submits that draft.</p>
      <h3>Storage and retention</h3>
      <p>Google authorization credentials are stored by Google Sign-In in protected device storage. TAGGR does not send them to a TAGGR canister or a developer-operated server. A selected video and resumable-upload metadata may be stored temporarily in protected app storage so an interrupted upload can continue. Upload jobs are removed after completion is acknowledged, cancellation, explicit disconnection, or expiry; incomplete jobs expire after seven days.</p>
      <h3>Sharing</h3>
      <p>The selected video and metadata are sent directly from the device to YouTube at the user’s request. TAGGR does not sell Google user data, use it for advertising, or share it with data brokers. Google user data is not used to train generalized artificial intelligence or machine-learning models.</p>
      <h3>Disconnecting and deleting Google data</h3>
      <p>A user can select “Disconnect YouTube” in TAGGR. This revokes TAGGR’s Google authorization and removes local YouTube upload state. A user can also revoke access at <a href="https://myaccount.google.com/connections">Google Account Connections</a>. Videos already uploaded to YouTube remain in the user’s YouTube account and can be managed or deleted there.</p>
      <div class="note">TAGGR’s use and transfer of information received from Google APIs adheres to the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including the Limited Use requirements.</div>

      <h2>Photos and videos</h2>
      <p>The app accesses only media the user explicitly selects with the system picker. TAGGR does not scan the user’s photo library. A video selected for YouTube is handled as described above.</p>

      <h2>Analytics, advertising, and tracking</h2>
      <p>The TAGGR iOS app contains no analytics SDK or advertising SDK and does not perform advertising tracking. It does not collect native contacts, precise location, microphone recordings, HealthKit data, or push-notification tokens.</p>

      <h2>Third-party services</h2>
      <p>Internet Identity provides authentication. Google Sign-In and the YouTube Data API provide optional YouTube connection and upload. Public Internet Computer ledgers provide wallet information. External community links open their respective services, whose own terms and privacy policies apply.</p>

      <h2>Security</h2>
      <p>The iOS app uses platform-protected storage for authentication and upload state. No system can guarantee absolute security. Users should protect access to their device and disconnect services they no longer use.</p>

      <h2>Children</h2>
      <p>TAGGR is not directed to children under the age required to consent to online services in their jurisdiction.</p>

      <h2>iOS reports and moderation</h2>
      <p>Report on a post or profile sends the target canister, post or user ID, your reason, and a random request ID to the operator's Cloudflare Worker. Reports are stored in D1 for manual review; no token or credit balance is required. Reports do not automatically hide content. Do not include passwords, private keys, or other sensitive information.</p>
      <p>The operator can hide individual posts or a user's content in the official iOS app. The public list contains only target IDs and a version, not report text or decision reasons. Closed reports are deleted after 90 days during the operator's review process. Display decisions and their reasons are retained for review and reversal.</p>
      <p>Terms acceptance, personal blocks, and the last fetched display-stop list are stored on your device. Signed-in block choices are synchronized with TAGGR when possible. The app fetches the display-stop list without sending your identity credentials. IP addresses are used transiently by Cloudflare's rate limiter to limit report abuse; they are not stored in the report database.</p>
      <h2>Changes and contact</h2>
      <p>This policy may be updated when TAGGR’s data practices change. The effective date above identifies the current version. Contact the iOS operator through <a href="https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/FF">@FF on TAGGR</a>. Profile posts and replies are public. Send private safety reports using Report in the iOS app.</p>
    `,
});

const terms = layout({
    title: "Terms of Use — TAGGR",
    description:
        "Terms governing use of the TAGGR iOS app and its optional YouTube upload feature.",
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
      <p>You retain responsibility for content you submit. You must have the rights and permissions necessary to publish it. Do not submit unlawful content, malware, impersonation, targeted harassment, or material that infringes another person’s privacy or intellectual-property rights. Community and realm moderation rules may also apply.</p>

      <h2>YouTube uploads</h2>
      <p>YouTube connection is optional. You may upload only videos you are authorized to upload. Your use of YouTube is also governed by the <a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a> and the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>. Disconnecting TAGGR does not delete videos already uploaded to your YouTube channel.</p>

      <h2>No warranty</h2>
      <p>TAGGR is provided on an “as is” and “as available” basis to the extent permitted by law. No guarantee is made that the service will be uninterrupted, error-free, or suitable for a particular purpose. Nothing on TAGGR constitutes financial, legal, or investment advice.</p>

      <h2>iOS end-user agreement and safety</h2>
      <p>You must explicitly accept this agreement before using user-generated content in the iOS app. There is zero tolerance for objectionable content or abusive users, including sexual exploitation, pornography, threats, targeted harassment, hateful abuse, and illegal material. Do not upload or link to such content.</p>
      <p>The iOS app does not display posts marked NSFW and retains existing content filtering. Report on a post or profile submits a concern within the app without tokens or credits. The app confirms receipt only after storage succeeds. Block immediately hides that user's content from your iOS experience.</p>
      <p>The operator reviews reports within 24 hours and can hide a post or a user's content in the official iOS app. This does not delete content from Internet Computer, disable the underlying account, or restrict other clients. Reports are not automatically treated as proof of a violation. Unmarked objectionable content may escape filtering; please report it.</p>
      <p>If the display-stop list cannot be updated, the app continues using the last fetched list. Newly issued or lifted restrictions take effect after a successful update; service failure does not prevent normal app use.</p>
      <p>For support or appeals, contact <a href="https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/FF">@FF on TAGGR</a>. Profile posts and replies are public. Send private safety reports using Report in the iOS app.</p>
      <h2>Changes and support</h2>
      <p>These terms may be updated as the service changes. The effective date above identifies the current version. Questions and public issue reports can be submitted through the <a href="${SOURCE_URL}/issues">TAGGR open-source project issue tracker</a>.</p>
    `,
});

const pages = new Map([
    ["/", home],
    ["/about", home],
    ["/about/", home],
    ["/privacy", privacy],
    ["/privacy/", privacy],
    ["/privacy-policy", privacy],
    ["/privacy-policy/", privacy],
    ["/terms", terms],
    ["/terms/", terms],
]);

const securityHeaders = {
    "cache-control": "public, max-age=0, must-revalidate, no-transform",
    "content-security-policy":
        "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "permissions-policy": "camera=(), geolocation=(), microphone=()",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
};

export default {
    async fetch(request, env = {}) {
        const result = await moderationFetch(request, env);
        if (result) return result;
        const url = new URL(request.url);
        const method = request.method.toUpperCase();
        if (method !== "GET" && method !== "HEAD") {
            return new Response("Method Not Allowed", {
                status: 405,
                headers: { allow: "GET, HEAD" },
            });
        }
        if (url.pathname === "/robots.txt") {
            return new Response(
                method === "HEAD" ? null : "User-agent: *\nAllow: /\n",
                {
                    headers: {
                        "content-type": "text/plain; charset=utf-8",
                        ...securityHeaders,
                    },
                },
            );
        }
        const page = pages.get(url.pathname);
        if (!page) {
            return new Response(method === "HEAD" ? null : "Not Found", {
                status: 404,
                headers: securityHeaders,
            });
        }
        return new Response(method === "HEAD" ? null : page, {
            headers: {
                "cache-control": "public, max-age=300",
                "content-type": "text/html; charset=utf-8",
                ...securityHeaders,
            },
        });
    },
};
