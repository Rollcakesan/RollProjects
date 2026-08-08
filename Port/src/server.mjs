import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ProfileStore, StoreError } from "./store.mjs";
import { AuthError, GoogleTokenVerifier } from "./google-auth.mjs";
import { SessionManager } from "./session-auth.mjs";
import { normalizeProfile, normalizeSlug, profileSummary, publicProfile, ValidationError } from "./validation.mjs";

const PORT = Number(process.env.PORT) || 8080;
const PUBLIC_DIRECTORY = resolve(fileURLToPath(new URL("../public", import.meta.url)));
const PROFILE_TEMPLATE_PATH = join(PUBLIC_DIRECTORY, "profile.html");
const store = new ProfileStore();
const auth = new GoogleTokenVerifier({ clientId: process.env.GOOGLE_CLIENT_ID });
const sessions = new SessionManager({ secret: process.env.PORT_SESSION_SECRET });
const requestBuckets = new Map();
const profileCatalogCache = { expiresAt: 0, profiles: null, pending: null };

const MIME_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".txt", "text/plain; charset=utf-8"],
  [".webmanifest", "application/manifest+json; charset=utf-8"],
  [".xml", "application/xml; charset=utf-8"],
]);

const SECURITY_HEADERS = {
  "Content-Security-Policy": [
    "default-src 'self'",
    "script-src 'self' https://accounts.google.com",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https:",
    "connect-src 'self' https://accounts.google.com",
    "frame-src https://accounts.google.com",
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
    if (request.method === "GET" && ["/healthz", "/api/health"].includes(requestUrl.pathname)) {
      return sendJson(response, 200, {
        status: "ok",
        service: "Port",
        storage: process.env.PROFILE_BUCKET ? "gcs" : "local",
        googleLogin: Boolean(process.env.GOOGLE_CLIENT_ID),
      });
    }

    if (requestUrl.pathname.startsWith("/api/")) {
      enforceRateLimit(request, request.method === "GET" ? 180 : 40);
      enforceSameOriginMutation(request);
      return await handleApi(request, response, requestUrl);
    }

    if (request.method === "GET" && requestUrl.pathname.startsWith("/media/")) {
      return await serveMedia(requestUrl.pathname, response);
    }

    if (request.method === "GET" && requestUrl.pathname.startsWith("/u/")) {
      return await serveProfile(request, requestUrl.pathname, response);
    }

    if (!["GET", "HEAD"].includes(request.method || "")) {
      return sendJson(response, 405, { error: "METHOD_NOT_ALLOWED", message: "許可されていない操作です。" });
    }

    return await serveStatic(requestUrl.pathname, request, response);
  } catch (error) {
    if (error instanceof ValidationError || error instanceof StoreError || error instanceof AuthError) {
      return sendJson(response, error.status, { error: error.code, message: error.message });
    }
    console.error("Unhandled request error", error);
    return sendJson(response, 500, { error: "INTERNAL_ERROR", message: "一時的なエラーが発生しました。" });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Port listening on ${PORT}`);
});

async function handleApi(request, response, requestUrl) {
  const profileMatch = requestUrl.pathname.match(/^\/api\/profiles\/([^/]+)$/u);

  if (request.method === "GET" && requestUrl.pathname === "/api/config") {
    return sendJson(response, 200, { googleClientId: process.env.GOOGLE_CLIENT_ID || "" });
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/session") {
    const body = await readJsonBody(request);
    const user = await auth.verifyCredential(body.credential);
    return sendJson(response, 200, { user }, { "Set-Cookie": sessions.createCookie(user, { secure: isSecureRequest(request) }) });
  }

  if (request.method === "GET" && requestUrl.pathname === "/api/session") {
    const user = await authenticate(request);
    return sendJson(response, 200, { user });
  }

  if (request.method === "DELETE" && requestUrl.pathname === "/api/session") {
    return sendJson(response, 200, {}, { "Set-Cookie": sessions.clearCookie({ secure: isSecureRequest(request) }) });
  }

  if (request.method === "GET" && requestUrl.pathname === "/api/me/profiles") {
    const user = await authenticate(request);
    const profiles = await store.getProfilesForOwner(user.subject);
    return sendJson(response, 200, { profiles: profiles.map(profileSummary) });
  }

  if (request.method === "GET" && requestUrl.pathname === "/api/discover") {
    const limit = Math.min(Math.max(Number.parseInt(requestUrl.searchParams.get("limit") || "8", 10) || 8, 1), 24);
    const cursor = Math.min(Math.max(Number.parseInt(requestUrl.searchParams.get("cursor") || "0", 10) || 0, 0), 100_000);
    const requestedSeed = requestUrl.searchParams.get("seed") || "";
    const seed = /^[a-zA-Z0-9_-]{8,64}$/u.test(requestedSeed) ? requestedSeed : randomUUID();
    const profiles = orderProfiles(await getProfileCatalog(), seed);
    const nextCursor = Math.min(cursor + limit, profiles.length);
    return sendJson(
      response,
      200,
      { profiles: profiles.slice(cursor, nextCursor).map(publicProfile), seed, nextCursor, hasMore: nextCursor < profiles.length },
      { "Cache-Control": "no-store" },
    );
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/profiles") {
    const user = await authenticate(request);
    const body = await readJsonBody(request);
    const slug = normalizeSlug(body.slug);
    const normalized = normalizeProfile(body.profile, { allowDataImages: true });
    const now = new Date().toISOString();
    const materialized = await materializeImages(normalized, slug);
    const profile = {
      ...materialized,
      slug,
      ownerSubject: user.subject,
      ownerEmail: user.email,
      ownerName: user.name,
      ownerPicture: user.picture,
      createdAt: now,
      updatedAt: now,
    };
    await store.createProfile(slug, profile);
    invalidateProfileCatalog();
    return sendJson(response, 201, { profile: publicProfile(profile) }, { Location: `/u/${slug}` });
  }

  if (profileMatch) {
    const slug = normalizeSlug(decodeURIComponent(profileMatch[1]));
    const current = await store.getProfile(slug);

    if (request.method === "GET") {
      return sendJson(response, 200, { profile: publicProfile(current) }, { "Cache-Control": "public, max-age=60" });
    }

    if (request.method === "PUT") {
      const user = await authenticate(request);
      assertOwner(current, user);
      const body = await readJsonBody(request);
      const normalized = normalizeProfile(body.profile, { allowDataImages: true });
      const materialized = await materializeImages(normalized, slug);
      const profile = {
        ...materialized,
        slug,
        ownerSubject: current.ownerSubject,
        ownerEmail: user.email,
        ownerName: user.name,
        ownerPicture: user.picture,
        createdAt: current.createdAt,
        updatedAt: new Date().toISOString(),
      };
      await store.updateProfile(slug, profile);
      invalidateProfileCatalog();
      await cleanupUnusedImages(slug, profile);
      return sendJson(response, 200, { profile: publicProfile(profile) });
    }

    if (request.method === "DELETE") {
      const user = await authenticate(request);
      assertOwner(current, user);
      await store.deleteProfile(slug, user.subject);
      invalidateProfileCatalog();
      response.writeHead(204, { ...SECURITY_HEADERS, "Cache-Control": "no-store", "X-Robots-Tag": "noindex" });
      return response.end();
    }
  }

  return sendJson(response, 404, { error: "NOT_FOUND", message: "APIが見つかりません。" });
}

async function materializeImages(profile, slug) {
  const output = structuredClone(profile);
  const [avatarUrl, coverUrl, thumbnailUrls] = await Promise.all([
    materializeImage(output.avatarUrl, slug),
    materializeImage(output.coverUrl, slug),
    Promise.all(output.links.map((link) => materializeImage(link.thumbnailUrl, slug))),
  ]);
  output.avatarUrl = avatarUrl;
  output.coverUrl = coverUrl;
  output.links.forEach((link, index) => { link.thumbnailUrl = thumbnailUrls[index]; });
  return output;
}

async function materializeImage(value, slug) {
  if (!String(value || "").startsWith("data:image/")) return value;
  const commaIndex = value.indexOf(",");
  const bytes = Buffer.from(value.slice(commaIndex + 1), "base64");
  if (!bytes.length || bytes.length > 550_000) throw new ValidationError("画像が大きすぎます。");
  return await store.putImage(slug, randomUUID(), bytes);
}

async function authenticate(request) {
  return sessions.verifyCookieHeader(request.headers.cookie);
}

function assertOwner(profile, user) {
  if (!profile.ownerSubject || profile.ownerSubject !== user.subject) {
    throw new AuthError("このプロフィールを編集する権限がありません。", 403, "FORBIDDEN");
  }
}

async function serveMedia(pathname, response) {
  const match = pathname.match(/^\/media\/([^/]+)\/([^/]+)$/u);
  if (!match) return sendJson(response, 404, { error: "NOT_FOUND", message: "画像が見つかりません。" });
  const slug = normalizeSlug(decodeURIComponent(match[1]));
  const filename = decodeURIComponent(match[2]);
  const bytes = await store.getImage(slug, filename);
  response.writeHead(200, {
    ...SECURITY_HEADERS,
    "Cache-Control": "public, max-age=31536000, immutable",
    "Content-Length": bytes.length,
    "Content-Type": "image/webp",
  });
  response.end(bytes);
}

async function serveProfile(request, pathname, response) {
  const slug = normalizeSlug(decodeURIComponent(pathname.slice(3)));
  const profile = publicProfile(await store.getProfile(slug));
  const template = await readFile(PROFILE_TEMPLATE_PATH, "utf8");
  const title = `${profile.displayName}｜Port`;
  const description = profile.headline || profile.bio || `${profile.displayName}のリンクプロフィール`;
  const image = absoluteUrl(profile.avatarUrl || profile.coverUrl || "/og-image.svg");
  const canonical = `https://port.rollprojects.com/u/${encodeURIComponent(slug)}`;
  const fallbackLinks = profile.links
    .map((link) => `<li><a href="${escapeAttribute(link.url)}">${escapeHtml(link.label)}</a></li>`)
    .join("");
  const fallback = `<section class="profile-fallback"><h1>${escapeHtml(profile.displayName)}</h1><p>${escapeHtml(description)}</p><ul>${fallbackLinks}</ul></section>`;
  const profileJson = JSON.stringify(profile).replaceAll("<", "\\u003c");
  const bootstrapJson = await createBootstrapJson(request);
  const html = template
    .replaceAll("{{TITLE}}", escapeHtml(title))
    .replaceAll("{{DESCRIPTION}}", escapeAttribute(description))
    .replaceAll("{{IMAGE}}", escapeAttribute(image))
    .replaceAll("{{CANONICAL}}", canonical)
    .replace("<!--PROFILE_JSON-->", profileJson)
    .replace("<!--SESSION_JSON-->", bootstrapJson)
    .replace("<!--PROFILE_FALLBACK-->", fallback);
  response.writeHead(200, {
    ...SECURITY_HEADERS,
    "Cache-Control": "private, no-store",
    "Content-Length": Buffer.byteLength(html),
    "Content-Type": "text/html; charset=utf-8",
  });
  response.end(html);
}

async function serveStatic(pathname, request, response) {
  const routeFiles = new Map([
    ["/", "/index.html"],
    ["/create", "/index.html"],
    ["/dashboard", "/index.html"],
  ]);
  const requestedPath = pathname.startsWith("/edit/") ? "/index.html" : routeFiles.get(pathname) || pathname;
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
    if (!fileStat.isFile() || filePath === PROFILE_TEMPLATE_PATH) throw new Error("Not public");
    const extension = extname(filePath);
    if (extension === ".html") {
      const template = await readFile(filePath, "utf8");
      const html = template.replace("<!--SESSION_JSON-->", await createBootstrapJson(request));
      response.writeHead(200, {
        ...SECURITY_HEADERS,
        "Cache-Control": "private, no-store",
        "Content-Length": Buffer.byteLength(html),
        "Content-Type": "text/html; charset=utf-8",
        ...(["/create", "/dashboard"].includes(pathname) || pathname.startsWith("/edit/") ? { "X-Robots-Tag": "noindex, nofollow" } : {}),
      });
      if (request.method === "HEAD") return response.end();
      return response.end(html);
    }
    const requiresRevalidation = [".html", ".css", ".js"].includes(extension);
    response.writeHead(200, {
      ...SECURITY_HEADERS,
      "Cache-Control": requiresRevalidation ? "no-cache" : "public, max-age=3600",
      "Content-Length": fileStat.size,
      "Content-Type": MIME_TYPES.get(extension) || "application/octet-stream",
      ...(["/create", "/dashboard"].includes(pathname) || pathname.startsWith("/edit/") ? { "X-Robots-Tag": "noindex, nofollow" } : {}),
    });
    if (request.method === "HEAD") return response.end();
    createReadStream(filePath).pipe(response);
  } catch {
    return sendJson(response, 404, { error: "NOT_FOUND", message: "ページが見つかりません。" });
  }
}

async function createBootstrapJson(request) {
  let user = null;
  let profiles = [];
  try {
    user = await authenticate(request);
    profiles = (await store.getProfilesForOwner(user.subject)).map(profileSummary);
  } catch (error) {
    if (!(error instanceof AuthError)) throw error;
  }
  return JSON.stringify({
    googleClientId: process.env.GOOGLE_CLIENT_ID || "",
    user,
    profiles,
  }).replaceAll("<", "\\u003c");
}

async function readJsonBody(request) {
  const contentLength = Number(request.headers["content-length"] || 0);
  if (contentLength > 5_000_000) throw new ValidationError("送信データが大きすぎます。", 413, "PAYLOAD_TOO_LARGE");
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > 5_000_000) throw new ValidationError("送信データが大きすぎます。", 413, "PAYLOAD_TOO_LARGE");
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new ValidationError("JSONを読み取れません。");
  }
}

function sendJson(response, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    ...SECURITY_HEADERS,
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
    "Content-Type": "application/json; charset=utf-8",
    "X-Robots-Tag": "noindex",
    ...extraHeaders,
  });
  response.end(body);
}

function enforceRateLimit(request, limit) {
  const clientIp = String(request.headers["x-forwarded-for"] || request.socket.remoteAddress || "unknown").split(",")[0].trim();
  const key = `${clientIp}:${request.method === "GET" ? "read" : "write"}`;
  const now = Date.now();
  if (requestBuckets.size > 2_000) {
    for (const [bucketKey, candidate] of requestBuckets) {
      if (candidate.resetAt <= now) requestBuckets.delete(bucketKey);
    }
  }
  const bucket = requestBuckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    requestBuckets.set(key, { count: 1, resetAt: now + 10 * 60_000 });
    return;
  }
  bucket.count += 1;
  if (bucket.count > limit) throw new ValidationError("操作回数が上限に達しました。少し待ってください。", 429, "RATE_LIMITED");
}

async function getProfileCatalog() {
  if (profileCatalogCache.profiles && profileCatalogCache.expiresAt > Date.now()) return profileCatalogCache.profiles;
  if (profileCatalogCache.pending) return await profileCatalogCache.pending;
  profileCatalogCache.pending = store.getAllProfiles().then((profiles) => {
    profileCatalogCache.profiles = profiles;
    profileCatalogCache.expiresAt = Date.now() + 60_000;
    return profiles;
  }).finally(() => { profileCatalogCache.pending = null; });
  return await profileCatalogCache.pending;
}

function invalidateProfileCatalog() {
  profileCatalogCache.expiresAt = 0;
  profileCatalogCache.profiles = null;
}

async function cleanupUnusedImages(slug, profile) {
  const prefix = `/media/${encodeURIComponent(slug)}/`;
  const filenames = [profile.avatarUrl, profile.coverUrl, ...profile.links.map((link) => link.thumbnailUrl)]
    .filter((value) => String(value || "").startsWith(prefix))
    .map((value) => decodeURIComponent(value.slice(prefix.length)));
  try {
    await store.deleteAssetsExcept(slug, filenames);
  } catch (error) {
    console.error("Unused image cleanup failed", error);
  }
}

function enforceSameOriginMutation(request) {
  if (["GET", "HEAD"].includes(request.method || "")) return;
  if (request.headers["x-port-request"] !== "1") {
    throw new AuthError("リクエストを確認できません。", 403, "INVALID_REQUEST_ORIGIN");
  }
}

function isSecureRequest(request) {
  return String(request.headers["x-forwarded-proto"] || "").split(",")[0].trim() === "https"
    || !String(request.headers.host || "").startsWith("localhost");
}

function orderProfiles(profiles, seed) {
  return profiles
    .map((profile) => ({ profile, rank: createHash("sha256").update(`${seed}:${profile.slug}`).digest("hex") }))
    .sort((left, right) => left.rank.localeCompare(right.rank))
    .map(({ profile }) => profile);
}

function absoluteUrl(value) {
  if (/^https?:\/\//u.test(value)) return value;
  return `https://port.rollprojects.com${value.startsWith("/") ? value : `/${value}`}`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/gu, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

function escapeAttribute(value) {
  return escapeHtml(String(value).replace(/[\n\r]/gu, " "));
}
