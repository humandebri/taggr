#!/usr/bin/env node
const http = require("http");
const fs = require("fs");
const path = require("path");
const { IDL } = require("@dfinity/candid");

const [listenPort, upstreamHost, upstreamPort = "8001", staticRoot] =
    process.argv.slice(2);
if (!listenPort || !upstreamHost) {
    console.error(
        "usage: host-header-proxy.js <listen-port> <upstream-host-header> [upstream-port] [static-root]",
    );
    process.exit(1);
}

const upstreamAgent = new http.Agent({ keepAlive: false });
const internetIdentityBackendHost = "rdmx6-jaaaa-aaaaa-aaadq-cai.localhost";
const resolvedStaticRoot = staticRoot ? path.resolve(staticRoot) : "";
const analyticsConfig = IDL.Variant({
    Plausible: IDL.Record({
        domain: IDL.Opt(IDL.Text),
        track_localhost: IDL.Opt(IDL.Bool),
        hash_mode: IDL.Opt(IDL.Bool),
        api_host: IDL.Opt(IDL.Text),
    }),
});
const frontendCanisterConfig = IDL.Record({
    fetch_root_key: IDL.Opt(IDL.Bool),
    featured_dashboard_apps: IDL.Opt(IDL.Vec(IDL.Text)),
    backend_canister_id: IDL.Principal,
    analytics_config: IDL.Opt(IDL.Opt(analyticsConfig)),
    related_origins: IDL.Opt(IDL.Vec(IDL.Text)),
    backend_origin: IDL.Text,
    dev_csp: IDL.Opt(IDL.Bool),
    dummy_auth: IDL.Opt(
        IDL.Opt(
            IDL.Record({
                prompt_for_index: IDL.Bool,
            }),
        ),
    ),
    feature_flags: IDL.Opt(IDL.Vec(IDL.Tuple(IDL.Text, IDL.Bool))),
});
const contentTypes = {
    "apple-app-site-association": "application/json",
    ".html": "text/html; charset=UTF-8",
    ".js": "application/javascript; charset=UTF-8",
    ".json": "application/json; charset=UTF-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".ico": "image/x-icon",
    ".md": "text/markdown; charset=UTF-8",
};

function serveStatic(request, response) {
    if (!resolvedStaticRoot || request.url.startsWith("/api/")) return false;
    if (request.method !== "GET" && request.method !== "HEAD") {
        response.writeHead(405, { "content-type": "text/plain" });
        response.end("Method not allowed.");
        return true;
    }
    const url = new URL(request.url, "http://127.0.0.1");
    const pathname = decodeURIComponent(url.pathname);
    const relativePath =
        pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
    const candidate = path.resolve(resolvedStaticRoot, relativePath);
    const indexPath = path.join(resolvedStaticRoot, "index.html");
    if (
        candidate !== resolvedStaticRoot &&
        !candidate.startsWith(`${resolvedStaticRoot}${path.sep}`)
    ) {
        response.writeHead(403, { "content-type": "text/plain" });
        response.end("Forbidden.");
        return true;
    }
    let filePath = candidate;
    const headers = {
        "cache-control": "no-store",
        "content-type":
            contentTypes[path.basename(filePath)] ||
            contentTypes[path.extname(filePath)] ||
            "application/octet-stream",
    };
    if (fs.existsSync(filePath)) {
        // Serve the requested file as-is.
    } else if (fs.existsSync(`${candidate}.gz`)) {
        filePath = `${candidate}.gz`;
        headers["content-encoding"] = "gzip";
        headers["content-type"] =
            contentTypes[path.basename(candidate)] ||
            contentTypes[path.extname(candidate)] ||
            "application/octet-stream";
    } else {
        filePath = indexPath;
        headers["content-type"] = contentTypes[".html"];
    }
    if (!fs.existsSync(filePath)) {
        response.writeHead(404, { "content-type": "text/plain" });
        response.end("Not found.");
        return true;
    }
    const stat = fs.statSync(filePath);
    response.writeHead(200, {
        ...headers,
        "content-length": stat.size,
    });
    if (request.method === "HEAD") {
        response.end();
        return true;
    }
    fs.createReadStream(filePath).pipe(response);
    return true;
}

function publicOrigin(request) {
    const proto = request.headers["x-forwarded-proto"] || "http";
    const host = request.headers["x-forwarded-host"] || request.headers.host;
    return `${proto}://${host}`;
}

function serveAuthCallbacks(request, response) {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname !== "/.well-known/ii-auth-callbacks") return false;
    if (request.method !== "GET" && request.method !== "HEAD") {
        response.writeHead(405, { "content-type": "text/plain" });
        response.end("Method not allowed.");
        return true;
    }
    const body = JSON.stringify({
        callbacks: [`${publicOrigin(request)}/ios-auth-callback`],
    });
    response.writeHead(200, {
        "access-control-allow-origin": "*",
        "cache-control": "no-store",
        "content-length": Buffer.byteLength(body),
        "content-type": "application/json; charset=UTF-8",
    });
    response.end(request.method === "HEAD" ? undefined : body);
    return true;
}

function serveAuthCallbackTerminal(request, response) {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname !== "/ios-auth-callback") return false;
    if (request.method !== "GET" && request.method !== "HEAD") {
        response.writeHead(405, { "content-type": "text/plain" });
        response.end("Method not allowed.");
        return true;
    }
    const body =
        '<!doctype html><meta charset="utf-8"><title>TAGGR sign-in</title><p>Authentication complete. You can return to TAGGR.</p>';
    response.writeHead(200, {
        "cache-control": "no-store",
        "content-length": Buffer.byteLength(body),
        "content-type": "text/html; charset=UTF-8",
    });
    response.end(request.method === "HEAD" ? undefined : body);
    return true;
}

function shouldRewriteUpstreamBody(headers) {
    if (resolvedStaticRoot) return false;
    const contentType = String(headers["content-type"] || "");
    return (
        contentType.includes("text/html") ||
        contentType.includes("application/javascript") ||
        contentType.includes("text/javascript") ||
        contentType.includes("application/json")
    );
}

function rewriteLocalhostOrigins(body, request) {
    const origin = publicOrigin(request);
    const rewritten = body.replaceAll(
        /http:\/\/[a-z0-9-]+\.localhost:\d+/gi,
        origin,
    );
    return rewritten.replace(
        /data-canister-config="([^"]+)"/,
        (_match, encodedConfig) => {
            const buffer = Buffer.from(encodedConfig, "base64");
            const arrayBuffer = buffer.buffer.slice(
                buffer.byteOffset,
                buffer.byteOffset + buffer.byteLength,
            );
            const [config] = IDL.decode([frontendCanisterConfig], arrayBuffer);
            config.backend_origin = origin;
            config.related_origins = [[origin]];
            const nextConfig = Buffer.from(
                IDL.encode([frontendCanisterConfig], [config]),
            ).toString("base64");
            return `data-canister-config="${nextConfig}"`;
        },
    );
}

const server = http.createServer((request, response) => {
    if (serveAuthCallbacks(request, response)) return;
    if (serveAuthCallbackTerminal(request, response)) return;
    if (serveStatic(request, response)) return;

    const headers = { ...request.headers };
    delete headers["accept-encoding"];
    delete headers["x-forwarded-host"];
    delete headers["x-original-host"];
    delete headers["forwarded"];
    delete headers[":authority"];
    delete headers.connection;
    delete headers["keep-alive"];
    delete headers["proxy-connection"];
    delete headers.te;
    delete headers.trailer;
    delete headers.upgrade;
    if (request.url.startsWith("/api/")) {
        headers.host = `127.0.0.1:${upstreamPort}`;
    } else if (!resolvedStaticRoot && request.url.startsWith("/.config")) {
        headers.host = `${internetIdentityBackendHost}:${upstreamPort}`;
    } else {
        headers.host = upstreamHost;
    }
    headers["accept-encoding"] = "identity";
    headers.connection = "close";

    let completed = false;
    const fail = (status, message) => {
        if (completed) return;
        completed = true;
        if (!response.headersSent) {
            response.writeHead(status, { "content-type": "text/plain" });
        }
        response.end(message);
    };

    const upstream = http.request(
        {
            hostname: "127.0.0.1",
            port: upstreamPort,
            method: request.method,
            path: request.url,
            headers,
            agent: upstreamAgent,
        },
        (upstreamResponse) => {
            completed = true;
            if (shouldRewriteUpstreamBody(upstreamResponse.headers)) {
                const chunks = [];
                upstreamResponse.on("data", (chunk) => chunks.push(chunk));
                upstreamResponse.on("end", () => {
                    const headers = { ...upstreamResponse.headers };
                    delete headers["content-length"];
                    const body = rewriteLocalhostOrigins(
                        Buffer.concat(chunks).toString("utf8"),
                        request,
                    );
                    headers["content-length"] = Buffer.byteLength(body);
                    response.writeHead(
                        upstreamResponse.statusCode || 502,
                        headers,
                    );
                    response.end(body);
                });
                return;
            }
            response.writeHead(
                upstreamResponse.statusCode || 502,
                upstreamResponse.headers,
            );
            upstreamResponse.pipe(response);
        },
    );

    upstream.setTimeout(30000, () => {
        fail(504, "Upstream timed out.");
        upstream.destroy();
    });

    upstream.on("error", (error) => {
        fail(502, error.message);
    });

    response.on("close", () => {
        if (!completed) upstream.destroy();
    });

    request.pipe(upstream);
});

server.requestTimeout = 35000;
server.headersTimeout = 36000;

server.on("clientError", (_error, socket) => {
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
});

server.listen(Number(listenPort), "0.0.0.0");
