import { createReadStream } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { AuthError, GoogleTokenVerifier } from "./google-auth.mjs";
import { SessionManager } from "./session-auth.mjs";
import { createStore, StoreError } from "./store.mjs";
import { normalizeArticle, normalizeProfile, normalizeReply, normalizeUserId, publicUser, searchTokenFor, ValidationError } from "./validation.mjs";

const PORT = Number(process.env.PORT) || 8080;
const PUBLIC = resolve(fileURLToPath(new URL("../public", import.meta.url)));
const store = await createStore();
const auth = new GoogleTokenVerifier({ clientId: process.env.GOOGLE_CLIENT_ID });
const sessions = new SessionManager({ secret: process.env.ROLLPROJECT_SESSION_SECRET });
const buckets = new Map();
const SECURITY = {
  "Content-Security-Policy": "default-src 'self'; script-src 'self' https://accounts.google.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://lh3.googleusercontent.com; connect-src 'self' https://accounts.google.com; frame-src https://accounts.google.com; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
  "Cross-Origin-Opener-Policy": "same-origin-allow-popups", "Permissions-Policy": "camera=(), microphone=(), geolocation=()", "Referrer-Policy": "strict-origin-when-cross-origin", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
};

const server = createServer(async (request, response) => {
  const url = new URL(request.url || "/", "http://localhost");
  try {
    if (request.method === "GET" && ["/healthz", "/api/health"].includes(url.pathname)) return json(response, 200, { status: "ok", service: "RollProject", storage: process.env.K_SERVICE ? "firestore" : "local", googleLogin: Boolean(process.env.GOOGLE_CLIENT_ID) });
    if (url.pathname.startsWith("/api/")) { rateLimit(request, request.method === "GET" ? 180 : 45); sameOriginMutation(request); return await api(request, response, url); }
    if (!["GET", "HEAD"].includes(request.method || "")) return json(response, 405, { error: "METHOD_NOT_ALLOWED", message: "許可されていない操作です。" });
    return await staticFile(url.pathname, request, response);
  } catch (error) {
    if (error instanceof ValidationError || error instanceof StoreError || error instanceof AuthError) return json(response, error.status, { error: error.code, message: error.message });
    if (error?.code === "INVALID_ARGUMENT" || error?.code === 9) return json(response, 503, { error: "INDEX_REQUIRED", message: "Firestoreインデックスを作成中です。" });
    console.error(error); return json(response, 500, { error: "INTERNAL_ERROR", message: "一時的なエラーが発生しました。" });
  }
});

async function api(request, response, url) {
  if (request.method === "GET" && url.pathname === "/api/config") return json(response, 200, { googleClientId: process.env.GOOGLE_CLIENT_ID || "" });
  if (request.method === "POST" && url.pathname === "/api/session") { const user = await auth.verifyCredential((await body(request)).credential); return json(response, 200, { user: await sessionView(user) }, { "Set-Cookie": sessions.createCookie(user, { secure: secureRequest(request) }) }); }
  if (request.method === "GET" && url.pathname === "/api/session") { const identity = authenticate(request); return json(response, 200, { user: await sessionView(identity) }); }
  if (request.method === "DELETE" && url.pathname === "/api/session") return json(response, 200, {}, { "Set-Cookie": sessions.clearCookie({ secure: secureRequest(request) }) });
  if (request.method === "PUT" && url.pathname === "/api/me/profile") { const identity = authenticate(request); const profile = normalizeProfile(await body(request)); const user = await store.saveProfile(identity.subject, profile, identity); return json(response, 200, { user: sessionUser(identity, user) }); }
  if (request.method === "GET" && url.pathname === "/api/articles") return json(response, 200, { articles: await store.listLatest(40) }, { "Cache-Control": "public, max-age=15" });
  if (request.method === "GET" && url.pathname === "/api/search") { const { normalized, token } = searchTokenFor(url.searchParams.get("q")); return json(response, 200, { query: normalized, articles: await store.searchArticles(normalized, token, 40) }); }
  if (request.method === "POST" && url.pathname === "/api/articles") { const identity = authenticate(request); const user = await requireProfile(identity); const article = await store.createArticle(identity.subject, user, normalizeArticle(await body(request))); return json(response, 201, { article }, { Location: `/${article.userId}/${article.articleId}` }); }
  const userMatch = url.pathname.match(/^\/api\/users\/([^/]+)$/u);
  if (userMatch && request.method === "GET") { const userId = normalizeUserId(decodeURIComponent(userMatch[1])); const user = await store.getPublicUser(userId); if (!user) throw new StoreError("ユーザーが見つかりません。", 404, "NOT_FOUND"); return json(response, 200, { user: publicUser(user), articles: await store.listByUser(userId) }); }
  const articleMatch = url.pathname.match(/^\/api\/articles\/([^/]+)\/([^/]+)$/u);
  if (articleMatch) {
    const userId = normalizeUserId(decodeURIComponent(articleMatch[1])); const articleId = decodeURIComponent(articleMatch[2]);
    if (!/^[a-zA-Z0-9_-]{8,32}$/u.test(articleId)) throw new StoreError("記事が見つかりません。", 404, "NOT_FOUND");
    if (request.method === "GET") return json(response, 200, { article: await store.getArticle(userId, articleId) });
    if (request.method === "PUT") { const identity = authenticate(request); return json(response, 200, { article: await store.updateArticle(identity.subject, userId, articleId, normalizeArticle(await body(request))) }); }
  }
  const replyMatch = url.pathname.match(/^\/api\/articles\/([^/]+)\/([^/]+)\/replies$/u);
  if (replyMatch && request.method === "POST") { const identity = authenticate(request); const user = await requireProfile(identity); const reply = await store.addReply(identity.subject, user, normalizeUserId(decodeURIComponent(replyMatch[1])), decodeURIComponent(replyMatch[2]), normalizeReply(await body(request))); return json(response, 201, { reply }); }
  return json(response, 404, { error: "NOT_FOUND", message: "APIが見つかりません。" });
}

async function sessionView(identity) { return sessionUser(identity, await store.getMe(identity.subject)); }
function sessionUser(identity, profile) { return { name: identity.name, email: identity.email, picture: identity.picture, profile: profile ? publicUser(profile) : null }; }
async function requireProfile(identity) { const profile = await store.getMe(identity.subject); if (!profile) throw new ValidationError("最初にユーザーIDを設定してください。", 409, "PROFILE_REQUIRED"); return profile; }
function authenticate(request) { return sessions.verifyCookieHeader(request.headers.cookie); }

async function staticFile(pathname, request, response) {
  const asset = pathname === "/" ? "/index.html" : pathname;
  const direct = resolve(PUBLIC, `.${asset}`);
  const safe = direct.startsWith(`${PUBLIC}/`);
  if (safe && [".js", ".css", ".svg", ".webmanifest"].includes(extname(direct))) {
    try { const info = await stat(direct); if (info.isFile()) return stream(direct, request, response, extname(direct) === ".js" ? "text/javascript; charset=utf-8" : extname(direct) === ".css" ? "text/css; charset=utf-8" : "application/octet-stream", "public, max-age=300"); } catch {}
  }
  const html = await readFile(join(PUBLIC, "index.html")); response.writeHead(200, { ...SECURITY, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" }); if (request.method === "HEAD") return response.end(); response.end(html);
}
function stream(path, request, response, contentType, cache) { response.writeHead(200, { ...SECURITY, "Content-Type": contentType, "Cache-Control": cache }); if (request.method === "HEAD") return response.end(); createReadStream(path).pipe(response); }
async function body(request) { const chunks = []; let size = 0; for await (const chunk of request) { size += chunk.length; if (size > 80_000) throw new ValidationError("送信内容が大きすぎます。", 413, "PAYLOAD_TOO_LARGE"); chunks.push(chunk); } try { return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); } catch { throw new ValidationError("JSONを読み取れません。", 400, "INVALID_JSON"); } }
function json(response, status, value, headers = {}) { response.writeHead(status, { ...SECURITY, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers }); response.end(JSON.stringify(value)); }
function secureRequest(request) { return request.headers["x-forwarded-proto"] === "https" || (request.headers.host && !request.headers.host.startsWith("localhost")); }
function sameOriginMutation(request) { if (["GET", "HEAD", "OPTIONS"].includes(request.method || "")) return; if (request.headers["x-rollproject-request"] !== "1") throw new AuthError("リクエストを確認できません。", 403, "INVALID_REQUEST_ORIGIN"); }
function rateLimit(request, maximum) { const key = String(request.headers["x-forwarded-for"] || request.socket.remoteAddress || "unknown").split(",")[0]; const now = Date.now(); const current = buckets.get(key); if (!current || current.resetAt < now) { buckets.set(key, { count: 1, resetAt: now + 60_000 }); return; } current.count += 1; if (current.count > maximum) throw new StoreError("操作が多すぎます。しばらく待ってください。", 429, "RATE_LIMITED"); if (buckets.size > 5000) for (const [id, item] of buckets) if (item.resetAt < now) buckets.delete(id); }

server.listen(PORT, "0.0.0.0", () => console.log(`RollProject listening on ${PORT}`));
