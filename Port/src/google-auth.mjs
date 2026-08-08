import { createPublicKey, verify } from "node:crypto";

const GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_ISSUERS = new Set(["accounts.google.com", "https://accounts.google.com"]);

export class AuthError extends Error {
  constructor(message, status = 401, code = "UNAUTHENTICATED") {
    super(message);
    this.name = "AuthError";
    this.status = status;
    this.code = code;
  }
}

export class GoogleTokenVerifier {
  constructor({ clientId, fetchFn = fetch, now = () => Date.now(), certsUrl = GOOGLE_CERTS_URL } = {}) {
    this.clientId = String(clientId || "").trim();
    this.fetchFn = fetchFn;
    this.now = now;
    this.certsUrl = certsUrl;
    this.jwks = null;
  }

  async verifyCredential(credential) {
    if (!this.clientId) throw new AuthError("Googleログインが設定されていません。", 503, "AUTH_NOT_CONFIGURED");
    if (!credential || credential.length > 8_000) throw new AuthError("Googleログイン情報を読み取れません。");

    const parts = credential.split(".");
    if (parts.length !== 3) throw new AuthError("Googleログイン情報を読み取れません。");

    const header = parseSegment(parts[0]);
    const payload = parseSegment(parts[1]);
    if (header.alg !== "RS256" || !header.kid) throw new AuthError("Googleログインの署名形式が不正です。");

    const jwk = await this.getJwk(header.kid);
    const key = createPublicKey({ key: jwk, format: "jwk" });
    const signed = Buffer.from(`${parts[0]}.${parts[1]}`, "utf8");
    const signature = Buffer.from(parts[2], "base64url");
    if (!verify("RSA-SHA256", signed, key, signature)) throw new AuthError("Googleログインの署名を確認できません。");

    const nowSeconds = Math.floor(this.now() / 1_000);
    if (!GOOGLE_ISSUERS.has(payload.iss)) throw new AuthError("Googleログインの発行元が不正です。");
    if (payload.aud !== this.clientId) throw new AuthError("Googleログインの対象が一致しません。");
    if (!Number.isFinite(payload.exp) || payload.exp <= nowSeconds) throw new AuthError("Googleログインの有効期限が切れています。");
    if (Number.isFinite(payload.iat) && payload.iat > nowSeconds + 120) throw new AuthError("Googleログインの発行時刻が不正です。");
    if (!payload.sub || payload.email_verified !== true) throw new AuthError("確認済みGoogleアカウントが必要です。");

    return {
      subject: String(payload.sub),
      email: String(payload.email || ""),
      name: String(payload.name || payload.email || "Google User").slice(0, 120),
      picture: validPicture(payload.picture),
    };
  }

  async getJwk(keyId) {
    const cached = this.jwks;
    if (cached && cached.expiresAt > this.now()) {
      const key = cached.keys.find((candidate) => candidate.kid === keyId);
      if (key) return key;
    }

    const response = await this.fetchFn(this.certsUrl);
    if (!response.ok) throw new AuthError("Googleログインの署名鍵を取得できません。", 503, "AUTH_PROVIDER_UNAVAILABLE");
    const payload = await response.json();
    const maxAge = Number(response.headers.get("cache-control")?.match(/max-age=(\d+)/u)?.[1] || 300);
    this.jwks = { keys: Array.isArray(payload.keys) ? payload.keys : [], expiresAt: this.now() + maxAge * 1_000 };
    const key = this.jwks.keys.find((candidate) => candidate.kid === keyId);
    if (!key) throw new AuthError("Googleログインの署名鍵が見つかりません。");
    return key;
  }
}

function parseSegment(value) {
  try {
    return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
  } catch {
    throw new AuthError("Googleログイン情報を読み取れません。");
  }
}

function validPicture(value) {
  const candidate = String(value || "");
  try {
    const parsed = new URL(candidate);
    return parsed.protocol === "https:" ? parsed.toString() : "";
  } catch {
    return "";
  }
}
