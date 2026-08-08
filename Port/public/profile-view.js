import {
  bindBrandIconFallbacks,
  brandIconMarkup,
  escapeHtml,
  initials,
  paymentMark,
  paymentType,
  platform,
} from "./catalog.js";

export function discoveryCard(profile) {
  const accent = /^#[0-9a-f]{6}$/iu.test(profile.accent || "") ? profile.accent : "#5b5cf0";
  const avatar = profile.avatarUrl
    ? `<img src="${escapeHtml(profile.avatarUrl)}" alt="" loading="lazy">`
    : `<span>${escapeHtml(initials(profile.displayName))}</span>`;
  const cover = profile.coverUrl
    ? `<img src="${escapeHtml(profile.coverUrl)}" alt="" loading="lazy">`
    : `<span class="discovery-cover-pattern"></span>`;
  const links = (profile.links || []).filter((link) => link.url).slice(0, 3).map(discoveryLink).join("");
  return `
    <article class="discovery-card" style="--profile-accent:${accent}">
      <a class="discovery-cover" href="/u/${encodeURIComponent(profile.slug)}" aria-label="${escapeHtml(profile.displayName)}のプロフィールを見る">${cover}</a>
      <div class="discovery-body">
        <a class="discovery-person" href="/u/${encodeURIComponent(profile.slug)}">
          <span class="discovery-avatar">${avatar}</span>
          <span class="discovery-copy"><strong>${escapeHtml(profile.displayName)}</strong>${profile.headline ? `<span>${escapeHtml(profile.headline)}</span>` : ""}${profile.location ? `<small>⌖ ${escapeHtml(profile.location)}</small>` : ""}</span>
          <span class="discovery-open">→</span>
        </a>
        ${profile.bio ? `<p class="discovery-bio">${escapeHtml(profile.bio)}</p>` : ""}
        ${links ? `<div class="discovery-links">${links}</div>` : ""}
      </div>
    </article>`;
}

export function profileMarkup(profile, { variant = "public" } = {}) {
  const compact = variant === "preview";
  const avatar = profile.avatarUrl
    ? `<img src="${escapeHtml(profile.avatarUrl)}" alt="" loading="${compact ? "lazy" : "eager"}">`
    : `<span>${escapeHtml(initials(profile.displayName))}</span>`;
  const cover = profile.coverUrl ? `<img src="${escapeHtml(profile.coverUrl)}" alt="" loading="lazy">` : "";
  const links = (profile.links || []).filter((link) => link.url);
  const payments = (profile.payments || []).filter((payment) => payment.destination);
  return `
    <div class="profile-cover ${profile.coverUrl ? "has-image" : ""}">${cover}<span class="cover-noise"></span></div>
    <div class="profile-content">
      <div class="profile-identity"><div class="profile-avatar">${avatar}</div><div class="profile-actions"></div><h1>${escapeHtml(profile.displayName || "表示名")}</h1>${profile.headline ? `<p class="profile-headline">${escapeHtml(profile.headline)}</p>` : ""}${profile.location ? `<p class="profile-location">⌖ ${escapeHtml(profile.location)}</p>` : ""}${profile.bio ? `<p class="profile-bio">${escapeHtml(profile.bio)}</p>` : ""}</div>
      ${links.length ? `<section class="profile-section"><div class="profile-section-title"><h2>Links & Works</h2><span>${links.length}</span></div><div class="profile-links">${links.map(profileLink).join("")}</div></section>` : ""}
      ${payments.length ? `<section class="profile-section payment-section"><div class="profile-section-title"><h2>Payment</h2><span>${payments.length}</span></div><p class="payment-notice">振込前に名義と内容を確認してください。</p><div class="payment-list">${payments.map(paymentCard).join("")}</div></section>` : ""}
      ${!links.length && !payments.length ? `<div class="empty-preview">リンクを追加するとここに表示されます。</div>` : ""}
    </div>`;
}

export function hydrateBrandIcons(root) {
  bindBrandIconFallbacks(root);
}

function discoveryLink(link) {
  const service = platform(link.platform);
  const thumbnail = link.thumbnailUrl
    ? `<img src="${escapeHtml(link.thumbnailUrl)}" alt="" loading="lazy">`
    : brandIconMarkup(service.id, service.mark);
  return `<a class="discovery-link" href="${escapeHtml(link.url)}" target="_blank" rel="me noopener noreferrer"><span class="discovery-link-thumb">${thumbnail}</span><span class="discovery-link-copy"><small>${escapeHtml(service.label)}</small><strong>${escapeHtml(link.label || service.label)}</strong></span><b>↗</b></a>`;
}

function profileLink(link) {
  const service = platform(link.platform);
  const thumbnail = link.thumbnailUrl
    ? `<img src="${escapeHtml(link.thumbnailUrl)}" alt="" loading="lazy">`
    : `<span class="link-placeholder">${brandIconMarkup(service.id, service.mark)}</span>`;
  return `<a class="profile-link-card" href="${escapeHtml(link.url)}" target="_blank" rel="me noopener noreferrer"><span class="link-thumb">${thumbnail}</span><span class="link-copy"><small>${escapeHtml(service.label)}</small><strong>${escapeHtml(link.label || service.label)}</strong>${link.description ? `<span>${escapeHtml(link.description)}</span>` : ""}</span><span class="link-arrow">↗</span></a>`;
}

function paymentCard(payment) {
  const type = paymentType(payment.type);
  return `<details class="payment-card"><summary><span><span class="payment-type-line">${brandIconMarkup(payment.type, paymentMark(payment.type))}<small>${escapeHtml(type.label)}</small></span><strong>${escapeHtml(payment.label || type.label)}</strong></span><span class="reveal-label">表示</span></summary><div class="payment-content"><code>${escapeHtml(payment.destination)}</code>${payment.note ? `<p>${escapeHtml(payment.note)}</p>` : ""}<div class="payment-actions"><button type="button" data-copy="${escapeHtml(payment.destination)}">コピー</button>${payment.url ? `<a href="${escapeHtml(payment.url)}" target="_blank" rel="noopener noreferrer">送金ページ ↗</a>` : ""}</div></div></details>`;
}
