const RESERVED_IDS = new Set(["api", "assets", "healthz", "new", "search", "settings", "login", "about"]);

export class ValidationError extends Error {
  constructor(message, status = 400, code = "INVALID_INPUT") {
    super(message);
    this.name = "ValidationError";
    this.status = status;
    this.code = code;
  }
}

export function normalizeUserId(value) {
  const userId = String(value || "").trim().toLowerCase();
  if (!/^[a-z0-9](?:[a-z0-9_-]{1,28}[a-z0-9])?$/u.test(userId) || RESERVED_IDS.has(userId)) {
    throw new ValidationError("ユーザーIDは3〜30文字の半角英数字・ハイフン・アンダースコアで入力してください。", 400, "INVALID_USER_ID");
  }
  return userId;
}

export function normalizeArticle(value) {
  const article = value && typeof value === "object" ? value : {};
  const title = cleanText(article.title, 1, 120, "タイトル");
  const body = cleanText(article.body, 1, 50_000, "本文", true);
  return { title, body, titleNormalized: normalizeSearchText(title), searchTokens: makeSearchTokens(title) };
}

export function normalizeReply(value) {
  const reply = value && typeof value === "object" ? value : {};
  return { body: cleanText(reply.body, 1, 12_000, "返信", true) };
}

export function normalizeProfile(value) {
  const profile = value && typeof value === "object" ? value : {};
  return {
    userId: normalizeUserId(profile.userId),
    displayName: cleanText(profile.displayName, 1, 60, "表示名"),
    bio: cleanText(profile.bio || "", 0, 240, "自己紹介", true),
  };
}

export function normalizeSearchText(value) {
  return String(value || "").normalize("NFKC").toLocaleLowerCase("ja").replace(/\s+/gu, " ").trim().slice(0, 120);
}

export function makeSearchTokens(value) {
  const normalized = normalizeSearchText(value);
  const compact = normalized.replace(/\s+/gu, "");
  const words = normalized.split(" ").filter(Boolean);
  const tokens = new Set(words);
  for (let index = 0; index < compact.length - 1; index += 1) tokens.add(compact.slice(index, index + 2));
  return [...tokens].filter((token) => token.length <= 40).slice(0, 400);
}

export function searchTokenFor(query) {
  const normalized = normalizeSearchText(query);
  if (!normalized) throw new ValidationError("検索語を入力してください。", 400, "EMPTY_QUERY");
  const compact = normalized.replace(/\s+/gu, "");
  return { normalized, token: compact.length >= 2 ? compact.slice(0, 2) : compact };
}

export function publicUser(user) {
  if (!user) return null;
  return { userId: user.userId, displayName: user.displayName, bio: user.bio || "", createdAt: user.createdAt };
}

function cleanText(value, min, max, label, preserveWhitespace = false) {
  let text = String(value ?? "").replace(/\r\n?/gu, "\n").trim();
  if (!preserveWhitespace) text = text.replace(/\s+/gu, " ");
  if (text.length < min) throw new ValidationError(`${label}を入力してください。`);
  if (text.length > max) throw new ValidationError(`${label}は${max.toLocaleString("ja-JP")}文字以内で入力してください。`);
  return text;
}
