import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  ProviderError,
  getWeatherDetail,
  getWeatherFeed,
  searchBooks,
  searchDatasets,
  searchLaws,
  searchMapPlaces,
} from "./providers.mjs";

const PORT = Number(process.env.PORT) || 8080;
const PUBLIC_DIRECTORY = resolve(fileURLToPath(new URL("../public", import.meta.url)));
const responseCache = new Map();
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
    "script-src 'self' https://cdn.jsdelivr.net",
    "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
    "img-src 'self' data: https://cyberjapandata.gsi.go.jp https://cdn.jsdelivr.net",
    "connect-src 'self'",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "upgrade-insecure-requests",
  ].join("; "),
  "Cross-Origin-Opener-Policy": "same-origin",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(self)",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

const server = createServer(async (request, response) => {
  const requestUrl = new URL(request.url || "/", "http://localhost");

  try {
    if (request.method === "GET" && ["/healthz", "/api/health"].includes(requestUrl.pathname)) {
      return sendJson(response, 200, { status: "ok", service: "JInfo" }, { "Cache-Control": "no-store" });
    }

    if (request.method === "GET" && requestUrl.pathname.startsWith("/api/")) {
      enforceRateLimit(request);

      if (requestUrl.pathname === "/api/laws") {
        const limit = requestUrl.searchParams.get("limit");
        return await cachedJson(response, `laws:${requestUrl.searchParams.get("q")}:${limit}`, 15 * 60_000, () =>
          searchLaws(requestUrl.searchParams.get("q"), limit),
        );
      }
      if (requestUrl.pathname === "/api/weather") {
        const feed = requestUrl.searchParams.get("feed") || "extra";
        return await cachedJson(response, `weather:${feed}`, 60_000, () => getWeatherFeed(feed));
      }
      if (requestUrl.pathname === "/api/weather-detail") {
        const sourceUrl = requestUrl.searchParams.get("url") || "";
        return await cachedJson(response, `weather-detail:${sourceUrl}`, 5 * 60_000, () =>
          getWeatherDetail(sourceUrl),
        );
      }
      if (requestUrl.pathname === "/api/datasets") {
        const limit = requestUrl.searchParams.get("limit");
        return await cachedJson(response, `datasets:${requestUrl.searchParams.get("q")}:${limit}`, 15 * 60_000, () =>
          searchDatasets(requestUrl.searchParams.get("q"), limit),
        );
      }
      if (requestUrl.pathname === "/api/books") {
        const limit = requestUrl.searchParams.get("limit");
        return await cachedJson(response, `books:${requestUrl.searchParams.get("q")}:${limit}`, 15 * 60_000, () =>
          searchBooks(requestUrl.searchParams.get("q"), limit),
        );
      }
      if (requestUrl.pathname === "/api/map-search") {
        return await cachedJson(response, `map:${requestUrl.searchParams.get("q")}`, 60 * 60_000, () =>
          searchMapPlaces(requestUrl.searchParams.get("q")),
        );
      }
      return sendJson(response, 404, { error: "NOT_FOUND", message: "APIが見つかりません。" });
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return sendJson(response, 405, { error: "METHOD_NOT_ALLOWED", message: "許可されていない操作です。" });
    }

    return await serveStatic(requestUrl.pathname, request, response);
  } catch (error) {
    if (error instanceof ProviderError) {
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
  console.log(`JInfo listening on ${PORT}`);
});

async function cachedJson(response, cacheKey, ttlMs, loader) {
  const cached = responseCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) {
    return sendJson(response, 200, { ...cached.value, cached: true }, { "Cache-Control": "no-store" });
  }
  const value = await loader();
  responseCache.set(cacheKey, { value, expiresAt: Date.now() + ttlMs });
  pruneCache();
  return sendJson(response, 200, { ...value, cached: false }, { "Cache-Control": "no-store" });
}

async function serveStatic(pathname, request, response) {
  const routeFiles = new Map([
    ["/", "/index.html"],
    ["/laws", "/laws.html"],
    ["/map", "/map.html"],
    ["/datasets", "/datasets.html"],
    ["/books", "/books.html"],
    ["/weather-detail", "/weather-detail.html"],
  ]);
  const requestedPath = routeFiles.get(pathname) || pathname;
  let safePath;
  try {
    safePath = normalize(decodeURIComponent(requestedPath)).replace(/^(\.\.[/\\])+/u, "");
  } catch {
    return sendJson(response, 400, { error: "INVALID_PATH", message: "URLを読み取れません。" });
  }
  const filePath = resolve(join(PUBLIC_DIRECTORY, safePath));
  if (!filePath.startsWith(`${PUBLIC_DIRECTORY}/`) && filePath !== PUBLIC_DIRECTORY) {
    return sendJson(response, 404, { error: "NOT_FOUND", message: "ページが見つかりません。" });
  }

  try {
    const fileStat = await stat(filePath);
    if (!fileStat.isFile()) throw new Error("Not a file");
    const extension = extname(filePath);
    const requiresRevalidation = [".html", ".css", ".js"].includes(extension);
    response.writeHead(200, {
      ...SECURITY_HEADERS,
      "Cache-Control": requiresRevalidation ? "no-cache" : "public, max-age=3600",
      "Content-Length": fileStat.size,
      "Content-Type": MIME_TYPES.get(extension) || "application/octet-stream",
    });
    if (request.method === "HEAD") return response.end();
    createReadStream(filePath).pipe(response);
  } catch {
    return sendJson(response, 404, { error: "NOT_FOUND", message: "ページが見つかりません。" });
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

function enforceRateLimit(request) {
  const clientIp = String(request.headers["x-forwarded-for"] || request.socket.remoteAddress || "unknown")
    .split(",")[0]
    .trim();
  const now = Date.now();
  const current = requestBuckets.get(clientIp);
  if (!current || current.resetAt <= now) {
    requestBuckets.set(clientIp, { count: 1, resetAt: now + 10 * 60_000 });
    pruneRateLimits(now);
    return;
  }
  current.count += 1;
  if (current.count > 80) {
    throw new ProviderError("検索回数が上限に達しました。少し待ってから再度お試しください。", 429, "RATE_LIMITED");
  }
}

function pruneCache() {
  if (responseCache.size < 300) return;
  const now = Date.now();
  for (const [key, value] of responseCache) {
    if (value.expiresAt <= now) responseCache.delete(key);
  }
}

function pruneRateLimits(now) {
  if (requestBuckets.size < 1_000) return;
  for (const [key, value] of requestBuckets) {
    if (value.resetAt <= now) requestBuckets.delete(key);
  }
}
