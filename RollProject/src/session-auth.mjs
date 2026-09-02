import { createHmac, timingSafeEqual } from "node:crypto";
import { AuthError } from "./google-auth.mjs";

const COOKIE_NAME = "rollproject_session";

export class SessionManager {
  constructor({ secret, now = () => Date.now(), maxAgeSeconds = 30 * 24 * 60 * 60 } = {}) {
    this.secret = String(secret || "");
    this.now = now;
    this.maxAgeSeconds = maxAgeSeconds;
    if (this.secret && this.secret.length < 32) throw new Error("ROLLPROJECT_SESSION_SECRET must be at least 32 characters");
  }

  createCookie(user, { secure = true } = {}) {
    this.assertConfigured();
    const payload = Buffer.from(JSON.stringify({ v: 1, exp: Math.floor(this.now() / 1000) + this.maxAgeSeconds, user: cleanUser(user) })).toString("base64url");
    return serialize(`${payload}.${this.sign(payload)}`, this.maxAgeSeconds, secure);
  }

  clearCookie({ secure = true } = {}) { return serialize("", 0, secure); }

  verifyCookieHeader(header) {
    this.assertConfigured();
    const value = parseCookies(header).get(COOKIE_NAME);
    if (!value || value.length > 4000) throw new AuthError("Googleログインが必要です。");
    const index = value.lastIndexOf(".");
    if (index <= 0 || !safeEqual(value.slice(index + 1), this.sign(value.slice(0, index)))) throw new AuthError("ログイン情報を確認できません。");
    let session;
    try { session = JSON.parse(Buffer.from(value.slice(0, index), "base64url")); } catch { throw new AuthError("ログイン情報を読み取れません。"); }
    if (session.v !== 1 || session.exp <= Math.floor(this.now() / 1000)) throw new AuthError("ログインの有効期限が切れています。");
    return cleanUser(session.user);
  }

  sign(value) { return createHmac("sha256", this.secret).update(value).digest("base64url"); }
  assertConfigured() { if (!this.secret) throw new AuthError("ログインセッションが設定されていません。", 503, "AUTH_NOT_CONFIGURED"); }
}

function cleanUser(user) {
  const subject = String(user?.subject || "");
  if (!subject || subject.length > 255) throw new AuthError("ログイン情報を読み取れません。");
  return { subject, email: String(user.email || "").slice(0, 320), name: String(user.name || "Google User").slice(0, 120), picture: String(user.picture || "").slice(0, 1000) };
}
function parseCookies(value) {
  const result = new Map();
  for (const part of String(value || "").split(";")) { const index = part.indexOf("="); if (index > 0) result.set(part.slice(0, index).trim(), part.slice(index + 1).trim()); }
  return result;
}
function serialize(value, maxAge, secure) {
  return [`${COOKIE_NAME}=${value}`, "Path=/", "HttpOnly", "SameSite=Lax", `Max-Age=${maxAge}`, secure ? "Secure" : ""].filter(Boolean).join("; ");
}
function safeEqual(left, right) {
  const a = Buffer.from(left); const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}
