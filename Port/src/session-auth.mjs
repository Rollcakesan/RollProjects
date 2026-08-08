import { createHmac, timingSafeEqual } from "node:crypto";
import { AuthError } from "./google-auth.mjs";

const DEFAULT_MAX_AGE_SECONDS = 30 * 24 * 60 * 60;
const SESSION_COOKIE_NAME = "port_session";

export class SessionManager {
  constructor({ secret, now = () => Date.now(), maxAgeSeconds = DEFAULT_MAX_AGE_SECONDS } = {}) {
    this.secret = String(secret || "");
    this.now = now;
    this.maxAgeSeconds = maxAgeSeconds;
    if (this.secret && this.secret.length < 32) throw new Error("PORT_SESSION_SECRET must be at least 32 characters");
  }

  createCookie(user, { secure = true } = {}) {
    this.assertConfigured();
    const payload = Buffer.from(JSON.stringify({
      version: 1,
      expiresAt: Math.floor(this.now() / 1_000) + this.maxAgeSeconds,
      user: normalizeUser(user),
    })).toString("base64url");
    const value = `${payload}.${this.sign(payload)}`;
    return serializeCookie(value, { maxAge: this.maxAgeSeconds, secure });
  }

  clearCookie({ secure = true } = {}) {
    return serializeCookie("", { maxAge: 0, secure });
  }

  verifyCookieHeader(header) {
    this.assertConfigured();
    const value = parseCookies(header).get(SESSION_COOKIE_NAME);
    if (!value || value.length > 4_000) throw new AuthError("Googleログインが必要です。");
    const separator = value.lastIndexOf(".");
    if (separator <= 0) throw new AuthError("ログイン情報を読み取れません。");
    const payload = value.slice(0, separator);
    const signature = value.slice(separator + 1);
    const expected = this.sign(payload);
    if (!safeEqual(signature, expected)) throw new AuthError("ログイン情報を確認できません。");

    let session;
    try {
      session = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    } catch {
      throw new AuthError("ログイン情報を読み取れません。");
    }
    const nowSeconds = Math.floor(this.now() / 1_000);
    if (session.version !== 1 || !Number.isFinite(session.expiresAt) || session.expiresAt <= nowSeconds) {
      throw new AuthError("ログインの有効期限が切れています。");
    }
    return normalizeUser(session.user);
  }

  sign(payload) {
    return createHmac("sha256", this.secret).update(payload).digest("base64url");
  }

  assertConfigured() {
    if (!this.secret) throw new AuthError("ログインセッションが設定されていません。", 503, "AUTH_NOT_CONFIGURED");
  }
}

function normalizeUser(value) {
  const user = value && typeof value === "object" ? value : {};
  const subject = String(user.subject || "");
  const email = String(user.email || "").slice(0, 320);
  const name = String(user.name || email || "Google User").slice(0, 120);
  const picture = String(user.picture || "");
  if (!subject || subject.length > 255) throw new AuthError("ログイン情報を読み取れません。");
  return { subject, email, name, picture: validHttpsUrl(picture) };
}

function validHttpsUrl(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" ? parsed.toString() : "";
  } catch {
    return "";
  }
}

function parseCookies(value) {
  const cookies = new Map();
  for (const part of String(value || "").split(";")) {
    const separator = part.indexOf("=");
    if (separator <= 0) continue;
    cookies.set(part.slice(0, separator).trim(), part.slice(separator + 1).trim());
  }
  return cookies;
}

function serializeCookie(value, { maxAge, secure }) {
  const attributes = [
    `${SESSION_COOKIE_NAME}=${value}`,
    "Path=/",
    "HttpOnly",
    "SameSite=Lax",
    `Max-Age=${maxAge}`,
  ];
  if (secure) attributes.push("Secure");
  return attributes.join("; ");
}

function safeEqual(left, right) {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}
