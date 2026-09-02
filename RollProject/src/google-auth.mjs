import { createPublicKey, verify } from "node:crypto";

const GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";

export class AuthError extends Error {
  constructor(message, status = 401, code = "AUTH_REQUIRED") {
    super(message);
    this.name = "AuthError";
    this.status = status;
    this.code = code;
  }
}

export class GoogleTokenVerifier {
  constructor({ clientId, fetchFn = fetch, now = () => Date.now() } = {}) {
    this.clientId = String(clientId || "");
    this.fetchFn = fetchFn;
    this.now = now;
    this.keys = new Map();
    this.expiresAt = 0;
  }

  async verifyCredential(credential) {
    if (!this.clientId) throw new AuthError("Googleログインが設定されていません。", 503, "AUTH_NOT_CONFIGURED");
    const parts = String(credential || "").split(".");
    if (parts.length !== 3) throw new AuthError("Googleログインを確認できませんでした。");
    let header;
    let payload;
    try {
      header = JSON.parse(Buffer.from(parts[0], "base64url"));
      payload = JSON.parse(Buffer.from(parts[1], "base64url"));
    } catch {
      throw new AuthError("Googleログインを確認できませんでした。");
    }
    if (header.alg !== "RS256" || !header.kid) throw new AuthError("Googleログインを確認できませんでした。");
    const key = await this.getKey(header.kid);
    const valid = verify("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), key, Buffer.from(parts[2], "base64url"));
    const nowSeconds = Math.floor(this.now() / 1000);
    const validIssuer = payload.iss === "accounts.google.com" || payload.iss === "https://accounts.google.com";
    if (!valid || !validIssuer || payload.aud !== this.clientId || payload.exp <= nowSeconds || payload.iat > nowSeconds + 300 || !payload.sub || payload.email_verified !== true) {
      throw new AuthError("Googleログインを確認できませんでした。");
    }
    return {
      subject: String(payload.sub),
      email: String(payload.email || "").slice(0, 320),
      name: String(payload.name || payload.email || "Google User").slice(0, 120),
      picture: safePicture(payload.picture),
    };
  }

  async getKey(kid) {
    if (this.now() >= this.expiresAt || !this.keys.has(kid)) await this.refreshKeys();
    const key = this.keys.get(kid);
    if (!key) throw new AuthError("Googleログインを確認できませんでした。");
    return key;
  }

  async refreshKeys() {
    const response = await this.fetchFn(GOOGLE_CERTS_URL);
    if (!response.ok) throw new AuthError("Googleログインを確認できませんでした。", 503, "AUTH_UNAVAILABLE");
    const data = await response.json();
    this.keys = new Map((data.keys || []).filter((key) => key.kid).map((key) => [key.kid, createPublicKey({ key, format: "jwk" })]));
    const maxAge = /max-age=(\d+)/u.exec(response.headers.get("cache-control") || "")?.[1];
    this.expiresAt = this.now() + (Number(maxAge) || 300) * 1000;
  }
}

function safePicture(value) {
  try {
    const url = new URL(String(value || ""));
    return url.protocol === "https:" ? url.toString() : "";
  } catch { return ""; }
}
