const BRAND_ICON_SLUGS = Object.freeze({
  github: "github", gitlab: "gitlab", x: "x", instagram: "instagram", threads: "threads",
  bluesky: "bluesky", mastodon: "mastodon", facebook: "facebook", youtube: "youtube",
  tiktok: "tiktok", twitch: "twitch", discord: "discord", spotify: "spotify",
  applemusic: "applemusic", soundcloud: "soundcloud", bandcamp: "bandcamp",
  musicbrainz: "musicbrainz", qiita: "qiita", zenn: "zenn", note: "note", medium: "medium",
  substack: "substack", wantedly: "wantedly", behance: "behance", dribbble: "dribbble",
  figma: "figma", pixiv: "pixiv", gumroad: "gumroad", kofi: "kofi",
  buymeacoffee: "buymeacoffee", patreon: "patreon", steam: "steam", itchio: "itchdotio",
  appstore: "appstore", googleplay: "googleplay", speakerdeck: "speakerdeck",
  slideshare: "slideshare", paypal: "paypal", wise: "wise", revolut: "revolut", stripe: "stripe",
});

const PAYMENT_MARKS = Object.freeze({ paypal: "PP", wise: "WI", revolut: "RE", stripe: "ST" });

export const PLATFORMS = [
  ["website", "Webサイト", "WEB"], ["github", "GitHub", "GH"], ["gitlab", "GitLab", "GL"],
  ["x", "X", "X"], ["instagram", "Instagram", "IG"], ["threads", "Threads", "TH"],
  ["bluesky", "Bluesky", "BS"], ["mastodon", "Mastodon", "MA"], ["facebook", "Facebook", "FB"],
  ["linkedin", "LinkedIn", "IN"], ["youtube", "YouTube", "YT"], ["tiktok", "TikTok", "TT"],
  ["twitch", "Twitch", "TW"], ["discord", "Discord", "DC"], ["spotify", "Spotify", "SP"],
  ["applemusic", "Apple Music", "AM"], ["soundcloud", "SoundCloud", "SC"], ["bandcamp", "Bandcamp", "BC"],
  ["musicbrainz", "MusicBrainz", "MB"], ["qiita", "Qiita", "QI"], ["zenn", "Zenn", "ZE"],
  ["note", "note", "NO"], ["medium", "Medium", "ME"], ["substack", "Substack", "SU"],
  ["wantedly", "Wantedly", "WA"], ["behance", "Behance", "BE"], ["dribbble", "Dribbble", "DR"],
  ["figma", "Figma", "FI"], ["pixiv", "pixiv", "PX"], ["booth", "BOOTH", "BO"],
  ["suzuri", "SUZURI", "SZ"], ["gumroad", "Gumroad", "GU"], ["kofi", "Ko-fi", "KF"],
  ["buymeacoffee", "Buy Me a Coffee", "BC"], ["patreon", "Patreon", "PA"], ["amazon", "Amazon", "AZ"],
  ["steam", "Steam", "ST"], ["itchio", "itch.io", "IT"], ["appstore", "App Store", "AS"],
  ["googleplay", "Google Play", "GP"], ["speakerdeck", "Speaker Deck", "SD"], ["slideshare", "SlideShare", "SS"],
  ["other", "その他", "↗"],
].map(([id, label, mark]) => ({ id, label, mark }));

export const PAYMENT_TYPES = [
  ["bank", "銀行振込"], ["paypay", "PayPay"], ["paypal", "PayPal"], ["wise", "Wise"],
  ["kyash", "Kyash"], ["revolut", "Revolut"], ["stripe", "Stripe Payment Link"],
  ["crypto", "暗号資産ウォレット"], ["other", "その他"],
].map(([id, label]) => ({ id, label }));

export function platform(id) {
  return PLATFORMS.find((item) => item.id === id) || PLATFORMS.at(-1);
}

export function paymentType(id) {
  return PAYMENT_TYPES.find((item) => item.id === id) || { id: "other", label: "送金先" };
}

export function paymentMark(id) {
  return PAYMENT_MARKS[id] || paymentType(id).label.slice(0, 2);
}

export function platformOptions(selected) {
  return PLATFORMS.map((item) => `<option value="${item.id}" ${item.id === selected ? "selected" : ""}>${item.label}</option>`).join("");
}

export function brandIconMarkup(id, mark) {
  const slug = BRAND_ICON_SLUGS[id];
  return `<span class="brand-icon"><span>${escapeHtml(mark)}</span>${slug ? `<img data-brand-icon src="https://cdn.simpleicons.org/${encodeURIComponent(slug)}" alt="" loading="lazy">` : ""}</span>`;
}

export function bindBrandIconFallbacks(root = document) {
  root?.querySelectorAll("img[data-brand-icon]").forEach((image) => {
    if (image.dataset.fallbackBound) return;
    image.dataset.fallbackBound = "true";
    image.addEventListener("error", () => image.remove(), { once: true });
    if (image.complete && image.naturalWidth === 0) image.remove();
  });
}

export function blankProfile() {
  return { displayName: "", headline: "", bio: "", location: "", avatarUrl: "", coverUrl: "", accent: "#5b5cf0", links: [], payments: [] };
}

export function profileSummary(profile) {
  return {
    slug: profile.slug,
    displayName: profile.displayName,
    headline: profile.headline || "",
    avatarUrl: profile.avatarUrl || "",
  };
}

export function initials(value) {
  return String(value || "P").trim().split(/\s+/u).slice(0, 2).map((part) => part[0]).join("").toUpperCase();
}

export function escapeHtml(value) {
  return String(value).replace(/[&<>"']/gu, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}
