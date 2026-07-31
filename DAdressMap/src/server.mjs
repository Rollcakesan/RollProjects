import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DigitalAddressClient,
  DigitalAddressError,
  normalizeAddressQuery,
  normalizeCode,
} from "./digital-address-client.mjs";

const PORT = Number(process.env.PORT) || 8080;
const PUBLIC_DIRECTORY = resolve(fileURLToPath(new URL("../public", import.meta.url)));
const MAX_BODY_BYTES = 4_096;
const CACHE_TTL_MS = 10 * 60 * 1000;
const client = new DigitalAddressClient();
const resultCache = new Map();
const requestBuckets = new Map();

const MIME_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml"],
  [".txt", "text/plain; charset=utf-8"],
  [".webmanifest", "application/manifest+json; charset=utf-8"],
  [".xml", "application/xml; charset=utf-8"],
]);

const SECURITY_HEADERS = {
  "Content-Security-Policy": [
    "default-src 'self'",
    "script-src 'self' https://maps.googleapis.com https://maps.gstatic.com",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https://maps.googleapis.com https://maps.gstatic.com https://streetviewpixels-pa.googleapis.com",
    "connect-src 'self' https://maps.googleapis.com https://maps.gstatic.com",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "upgrade-insecure-requests",
  ].join("; "),
  "Cross-Origin-Opener-Policy": "same-origin-allow-popups",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

const server = createServer(async (request, response) => {
  const requestUrl = new URL(request.url || "/", "http://localhost");

  try {
    if (
      request.method === "GET" &&
      (requestUrl.pathname === "/healthz" || requestUrl.pathname === "/api/health")
    ) {
      return sendJson(response, 200, { status: "ok" }, { "Cache-Control": "no-store" });
    }

    if (request.method === "GET" && requestUrl.pathname === "/api/config") {
      return sendJson(
        response,
        200,
        {
          googleMapsKey: process.env.GOOGLE_MAPS_BROWSER_KEY || "",
          apiMode: client.configured ? "production" : "demo",
          serviceName: "デジタルアドレスマップ",
        },
        { "Cache-Control": "public, max-age=300" },
      );
    }

    if (request.method === "POST" && requestUrl.pathname === "/api/lookup") {
      enforceRateLimit(request);
      const body = await readJsonBody(request);
      const cacheKey = `code:${normalizeCode(body.code)}`;
      const cached = resultCache.get(cacheKey);

      if (cached && cached.expiresAt > Date.now()) {
        return sendJson(response, 200, cached.value, { "Cache-Control": "no-store" });
      }

      const result = await client.lookup(body.code);
      resultCache.set(cacheKey, { value: result, expiresAt: Date.now() + CACHE_TTL_MS });
      pruneCache(resultCache);
      return sendJson(response, 200, result, { "Cache-Control": "no-store" });
    }

    if (request.method === "POST" && requestUrl.pathname === "/api/address-search") {
      enforceRateLimit(request);
      const body = await readJsonBody(request);
      const query = normalizeAddressQuery(body.address);
      const cacheKey = `address:${query}`;
      const cached = resultCache.get(cacheKey);

      if (cached && cached.expiresAt > Date.now()) {
        return sendJson(response, 200, cached.value, { "Cache-Control": "no-store" });
      }

      const result = await client.searchByAddress(query);
      resultCache.set(cacheKey, { value: result, expiresAt: Date.now() + CACHE_TTL_MS });
      pruneCache(resultCache);
      return sendJson(response, 200, result, { "Cache-Control": "no-store" });
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return sendJson(response, 405, { error: "METHOD_NOT_ALLOWED", message: "許可されていない操作です。" });
    }

    const isSharedSearchPage =
      (requestUrl.pathname === "/" || requestUrl.pathname === "/index.html") &&
      requestUrl.searchParams.has("code");

    return await serveStatic(
      requestUrl.pathname,
      request,
      response,
      isSharedSearchPage ? { "X-Robots-Tag": "noindex, follow" } : {},
    );
  } catch (error) {
    if (error instanceof DigitalAddressError) {
      return sendJson(response, error.status, { error: error.code, message: error.message });
    }

    console.error("Unhandled request error", error);
    return sendJson(response, 500, {
      error: "INTERNAL_ERROR",
      message: "一時的なエラーが発生しました。時間を置いて再度お試しください。",
    });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`DAdressMap listening on ${PORT}`);
});

async function serveStatic(pathname, request, response, extraHeaders = {}) {
  const requestedPath = pathname === "/" ? "/index.html" : pathname;
  const safePath = normalize(decodeURIComponent(requestedPath)).replace(/^(\.\.[/\\])+/u, "");
  const filePath = resolve(join(PUBLIC_DIRECTORY, safePath));

  if (!filePath.startsWith(`${PUBLIC_DIRECTORY}/`) && filePath !== PUBLIC_DIRECTORY) {
    return sendJson(response, 404, { error: "NOT_FOUND", message: "ページが見つかりません。" });
  }

  try {
    const fileStat = await stat(filePath);
    if (!fileStat.isFile()) throw new Error("Not a file");

    response.writeHead(200, {
      ...SECURITY_HEADERS,
      "Cache-Control": requestedPath === "/index.html" ? "no-cache" : "public, max-age=3600",
      "Content-Length": fileStat.size,
      "Content-Type": MIME_TYPES.get(extname(filePath)) || "application/octet-stream",
      ...extraHeaders,
    });

    if (request.method === "HEAD") return response.end();
    createReadStream(filePath).pipe(response);
  } catch {
    sendJson(response, 404, { error: "NOT_FOUND", message: "ページが見つかりません。" });
  }
}

function sendJson(response, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    ...SECURITY_HEADERS,
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "X-Robots-Tag": "noindex",
    ...extraHeaders,
  });
  response.end(body);
}

async function readJsonBody(request) {
  const contentType = request.headers["content-type"] || "";
  if (!contentType.startsWith("application/json")) {
    throw new DigitalAddressError("JSON形式で送信してください。", 415, "UNSUPPORTED_MEDIA_TYPE");
  }

  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
      throw new DigitalAddressError("送信データが大きすぎます。", 413, "PAYLOAD_TOO_LARGE");
    }
  }

  try {
    return JSON.parse(body || "{}");
  } catch {
    throw new DigitalAddressError("入力内容を読み取れませんでした。", 400, "INVALID_JSON");
  }
}

function enforceRateLimit(request) {
  const forwardedFor = request.headers["x-forwarded-for"];
  const clientIp = String(forwardedFor || request.socket.remoteAddress || "unknown")
    .split(",")[0]
    .trim();
  const now = Date.now();
  const windowMs = 10 * 60 * 1000;
  const current = requestBuckets.get(clientIp);

  if (!current || current.resetAt <= now) {
    requestBuckets.set(clientIp, { count: 1, resetAt: now + windowMs });
    pruneRateLimits(now);
    return;
  }

  current.count += 1;
  if (current.count > 40) {
    throw new DigitalAddressError(
      "検索回数が上限に達しました。少し待ってから再度お試しください。",
      429,
      "RATE_LIMITED",
    );
  }
}

function pruneRateLimits(now) {
  if (requestBuckets.size < 500) return;
  for (const [key, value] of requestBuckets) {
    if (value.resetAt <= now) requestBuckets.delete(key);
  }
}

function pruneCache(cache) {
  if (cache.size < 200) return;
  const now = Date.now();
  for (const [key, value] of cache) {
    if (value.expiresAt <= now) cache.delete(key);
  }
}
