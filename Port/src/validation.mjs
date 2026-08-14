const SLUG_PATTERN = /^[a-z0-9](?:[a-z0-9_-]{1,30}[a-z0-9])?$/u;
const COLOR_PATTERN = /^#[0-9a-f]{6}$/iu;
const ID_PATTERN = /^[a-zA-Z0-9_-]{1,48}$/u;
const DATA_IMAGE_PATTERN = /^data:image\/(?:jpeg|png|webp);base64,/iu;

export class ValidationError extends Error {
  constructor(message, status = 400, code = "INVALID_INPUT") {
    super(message);
    this.name = "ValidationError";
    this.status = status;
    this.code = code;
  }
}

export function normalizeSlug(value) {
  const slug = String(value || "").trim().toLowerCase();
  if (!SLUG_PATTERN.test(slug)) {
    throw new ValidationError("URL名は3〜32文字の半角英数字・ハイフン・アンダースコアで入力してください。");
  }
  if (["api", "create", "edit", "healthz", "media", "robots", "sitemap"].includes(slug)) {
    throw new ValidationError("このURL名は使用できません。", 409, "SLUG_UNAVAILABLE");
  }
  return slug;
}

export function normalizeProfile(input, { allowDataImages = false } = {}) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new ValidationError("プロフィールを読み取れません。");
  }

  const displayName = text(input.displayName, 60);
  if (!displayName) throw new ValidationError("表示名を入力してください。");

  return {
    schemaVersion: 1,
    displayName,
    headline: text(input.headline, 100),
    bio: text(input.bio, 600),
    location: text(input.location, 80),
    avatarUrl: imageUrl(input.avatarUrl, allowDataImages),
    coverUrl: imageUrl(input.coverUrl, allowDataImages),
    accent: COLOR_PATTERN.test(String(input.accent || "")) ? String(input.accent).toLowerCase() : "#5b5cf0",
    links: normalizeLinks(input.links, allowDataImages),
    payments: normalizePayments(input.payments),
  };
}

export function publicProfile(profile) {
  const {
    editTokenHash: _editTokenHash,
    ownerSubject: _ownerSubject,
    ownerEmail: _ownerEmail,
    ownerName: _ownerName,
    ownerPicture: _ownerPicture,
    ...safeProfile
  } = profile;
  return safeProfile;
}

export function profileSummary(profile) {
  const safeProfile = publicProfile(profile);
  return {
    slug: safeProfile.slug,
    displayName: safeProfile.displayName,
    headline: safeProfile.headline || "",
    avatarUrl: safeProfile.avatarUrl || "",
  };
}

function normalizeLinks(value, allowDataImages) {
  if (!Array.isArray(value)) return [];
  if (value.length > 48) throw new ValidationError("リンクは48件まで登録できます。");
  return value.map((link, index) => {
    if (!link || typeof link !== "object") throw new ValidationError(`${index + 1}件目のリンクを読み取れません。`);
    const url = externalUrl(link.url);
    if (!url) throw new ValidationError(`${index + 1}件目のリンクURLを入力してください。`);
    return {
      id: validId(link.id, `link-${index + 1}`),
      platform: text(link.platform, 40) || "website",
      label: text(link.label, 80) || hostname(url),
      description: text(link.description, 180),
      url,
      thumbnailUrl: imageUrl(link.thumbnailUrl, allowDataImages),
    };
  });
}

function normalizePayments(value) {
  if (!Array.isArray(value)) return [];
  if (value.length > 12) throw new ValidationError("振込・送金先は12件まで登録できます。");
  return value.map((payment, index) => {
    if (!payment || typeof payment !== "object") throw new ValidationError(`${index + 1}件目の送金先を読み取れません。`);
    const destination = text(payment.destination, 300);
    if (!destination) throw new ValidationError(`${index + 1}件目の振込・送金先を入力してください。`);
    return {
      id: validId(payment.id, `payment-${index + 1}`),
      type: text(payment.type, 30) || "other",
      label: text(payment.label, 80) || "送金先",
      destination,
      note: text(payment.note, 240),
      url: optionalExternalUrl(payment.url),
    };
  });
}

function imageUrl(value, allowDataImages) {
  const candidate = String(value || "").trim();
  if (!candidate) return "";
  if (allowDataImages && DATA_IMAGE_PATTERN.test(candidate)) {
    if (candidate.length > 750_000) throw new ValidationError("画像が大きすぎます。別の画像を選択してください。");
    return candidate;
  }
  if (candidate.startsWith("/media/")) return candidate;
  return externalUrl(candidate);
}

function externalUrl(value) {
  const input = String(value || "").trim();
  if (!input) return "";
  const explicitScheme = /^[a-z][a-z0-9+.-]*:/iu.test(input);
  if (explicitScheme && !/^https?:\/\//iu.test(input)) {
    throw new ValidationError("URLはhttps://またはhttp://のみ使用できます。");
  }
  const candidate = explicitScheme ? input : `https://${input.replace(/^\/\//u, "")}`;
  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    throw new ValidationError("URLの形式を確認してください。");
  }
  if (!["https:", "http:"].includes(parsed.protocol)) {
    throw new ValidationError("URLはhttps://またはhttp://のみ使用できます。");
  }
  parsed.username = "";
  parsed.password = "";
  return parsed.toString();
}

function optionalExternalUrl(value) {
  return String(value || "").trim() ? externalUrl(value) : "";
}

function hostname(value) {
  try {
    return new URL(value).hostname.replace(/^www\./u, "");
  } catch {
    return "リンク";
  }
}

function validId(value, fallback) {
  const candidate = String(value || "").trim();
  return ID_PATTERN.test(candidate) ? candidate : fallback;
}

function text(value, maxLength) {
  return String(value || "").replace(/\r\n?/gu, "\n").trim().slice(0, maxLength);
}
