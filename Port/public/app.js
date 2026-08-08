import { bindBrandIconFallbacks, escapeHtml, initials } from "./catalog.js";
import { ProfileEditor } from "./editor.js";
import { discoveryCard, hydrateBrandIcons, profileMarkup } from "./profile-view.js";

const app = document.querySelector("#app");
const toast = document.querySelector("#toast");

const state = {
  googleClientId: "",
  user: null,
  ownedProfiles: [],
  discoveryProfiles: [],
  discoveryLoading: false,
  discoveryDone: false,
  discoveryObserver: null,
  discoveryAbort: null,
  discoverySeed: "",
  discoveryCursor: 0,
};

const editor = new ProfileEditor({
  root: app,
  api,
  navigate: navigateTo,
  showToast,
  renderError,
  onCreated: upsertOwnedProfile,
  onUpdated: upsertOwnedProfile,
  onDeleted: removeOwnedProfile,
});

bootstrap();

async function bootstrap() {
  await initializeAuth();
  bindGlobalActions();
  if (!document.querySelector("#profile-data")) bindAppNavigation();
  route();
}

async function initializeAuth() {
  const embedded = document.querySelector("#session-data");
  if (embedded) {
    try {
      const payload = JSON.parse(embedded.textContent);
      state.googleClientId = payload.googleClientId || "";
      state.user = payload.user || null;
      state.ownedProfiles = payload.profiles || [];
      return;
    } catch {
      state.googleClientId = "";
    }
  }

  try {
    const config = await api("/api/config");
    state.googleClientId = config.googleClientId || "";
    const payload = await api("/api/session", { auth: true });
    state.user = payload.user;
    await loadOwnedProfiles();
  } catch {
    clearSession();
  }
}

function route() {
  const embeddedProfile = document.querySelector("#profile-data");
  if (embeddedProfile) {
    try {
      renderPublicProfile(JSON.parse(embeddedProfile.textContent));
    } catch {
      renderError("プロフィールを読み取れませんでした。");
    }
    return;
  }

  stopDiscovery();
  if (location.pathname === "/") {
    editor.deactivate();
    setRouteMetadata("Port", "index, follow, max-image-preview:large");
    renderDiscovery();
    return;
  }

  if (location.pathname === "/dashboard") {
    editor.deactivate();
    setRouteMetadata("Profiles｜Port", "noindex, nofollow");
    if (!state.user) return renderSignIn();
    renderDashboard();
    return;
  }

  if (location.pathname === "/create") {
    setRouteMetadata("New profile｜Port", "noindex, nofollow");
    renderHeaderAccount();
    if (!state.user) return renderSignIn();
    editor.openCreate();
    return;
  }

  const editMatch = location.pathname.match(/^\/edit\/([^/]+)$/u);
  if (editMatch) {
    setRouteMetadata("Edit profile｜Port", "noindex, nofollow");
    renderHeaderAccount();
    if (!state.user) return renderSignIn();
    editor.openEdit(decodeURIComponent(editMatch[1]), state.ownedProfiles);
    return;
  }
  navigateTo("/", { replace: true });
}

function bindAppNavigation() {
  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (!link || link.target || link.hasAttribute("download")) return;
    const target = new URL(link.href, location.href);
    if (target.origin !== location.origin || !isAppRoute(target.pathname)) return;
    event.preventDefault();
    if (target.href !== location.href) navigateTo(`${target.pathname}${target.search}${target.hash}`);
  });
  window.addEventListener("popstate", route);
}

function bindGlobalActions() {
  document.addEventListener("click", (event) => {
    if (event.defaultPrevented) return;
    const target = event.target instanceof Element ? event.target : null;
    const copyButton = target?.closest("[data-copy]");
    if (copyButton) copyText(copyButton.dataset.copy);
  });
  document.querySelector("#share-profile")?.addEventListener("click", shareProfile);
}

function isAppRoute(pathname) {
  return ["/", "/create", "/dashboard"].includes(pathname) || /^\/edit\/[^/]+$/u.test(pathname);
}

function navigateTo(path, { replace = false } = {}) {
  history[replace ? "replaceState" : "pushState"](null, "", path);
  route();
  window.scrollTo({ top: 0, behavior: "auto" });
  app.focus({ preventScroll: true });
}

function setRouteMetadata(title, robots) {
  document.title = title;
  document.querySelector('meta[name="robots"]')?.setAttribute("content", robots);
}

function renderSignIn() {
  editor.deactivate();
  renderHeaderAccount();
  app.innerHTML = `<section class="sign-in-page"><div class="sign-in-mark">P</div><h1>Sign in</h1><div id="google-signin"></div><p id="auth-error" class="auth-error"></p></section>`;
  mountGoogleButton();
}

function renderDiscovery() {
  renderHeaderAccount();
  state.discoveryProfiles = [];
  state.discoveryLoading = false;
  state.discoveryDone = false;
  state.discoverySeed = "";
  state.discoveryCursor = 0;
  state.discoveryAbort = new AbortController();
  app.innerHTML = `
    <section class="discovery-shell" aria-labelledby="discovery-title">
      <h1 id="discovery-title" class="visually-hidden">公開プロフィール</h1>
      <div id="discovery-list" class="discovery-list"></div>
      <div id="discovery-sentinel" class="discovery-sentinel"><span class="spinner"></span></div>
    </section>`;
  state.discoveryObserver = new IntersectionObserver((entries) => {
    if (entries.some((entry) => entry.isIntersecting)) loadDiscoveryProfiles();
  }, { rootMargin: "500px 0px" });
  state.discoveryObserver.observe(document.querySelector("#discovery-sentinel"));
  loadDiscoveryProfiles();
}

function stopDiscovery() {
  state.discoveryObserver?.disconnect();
  state.discoveryObserver = null;
  state.discoveryAbort?.abort();
  state.discoveryAbort = null;
  state.discoveryLoading = false;
}

async function loadDiscoveryProfiles() {
  if (state.discoveryLoading || state.discoveryDone) return;
  state.discoveryLoading = true;
  const sentinel = document.querySelector("#discovery-sentinel");
  try {
    const seed = state.discoverySeed ? `&seed=${encodeURIComponent(state.discoverySeed)}` : "";
    const payload = await api(`/api/discover?limit=8&cursor=${state.discoveryCursor}${seed}`, { signal: state.discoveryAbort?.signal });
    const incoming = (payload.profiles || []).filter((profile) => !state.discoveryProfiles.some((current) => current.slug === profile.slug));
    state.discoveryProfiles.push(...incoming);
    state.discoverySeed = payload.seed || state.discoverySeed;
    state.discoveryCursor = Number(payload.nextCursor) || state.discoveryProfiles.length;
    const list = document.querySelector("#discovery-list");
    list?.insertAdjacentHTML("beforeend", incoming.map(discoveryCard).join(""));
    hydrateBrandIcons(list);
    state.discoveryDone = !payload.hasMore || incoming.length === 0;
    if (!state.discoveryProfiles.length) renderEmptyDiscovery();
    if (state.discoveryDone) {
      state.discoveryObserver?.disconnect();
      sentinel?.remove();
    }
  } catch (error) {
    if (error.name === "AbortError") return;
    if (sentinel) sentinel.innerHTML = `<button class="feed-retry" type="button">再読み込み</button>`;
    document.querySelector(".feed-retry")?.addEventListener("click", () => {
      if (sentinel) sentinel.innerHTML = `<span class="spinner"></span>`;
      loadDiscoveryProfiles();
    }, { once: true });
  } finally {
    state.discoveryLoading = false;
  }
}

function renderEmptyDiscovery() {
  const list = document.querySelector("#discovery-list");
  if (!list) return;
  const label = state.user ? "プロフィールを作成" : "Sign in";
  list.innerHTML = `<div class="empty-discovery"><p>公開プロフィールはまだありません。</p><a class="button button-dark" href="/create">${label}</a></div>`;
}

function renderDashboard() {
  renderHeaderAccount();
  app.innerHTML = `
    <section class="dashboard-shell">
      <div class="dashboard-heading"><h1>Profiles</h1><a class="button button-dark" href="/create">New</a></div>
      <div class="profile-index">${state.ownedProfiles.map((profile) => `
        <article class="profile-index-card">
          <a href="/edit/${encodeURIComponent(profile.slug)}"><strong>${escapeHtml(profile.displayName)}</strong><span>/u/${escapeHtml(profile.slug)}</span></a>
          <a href="/u/${encodeURIComponent(profile.slug)}" target="_blank" aria-label="公開ページを開く">↗</a>
        </article>`).join("")}
      </div>
    </section>`;
}

function renderHeaderAccount() {
  const target = document.querySelector("#auth-nav");
  if (!target) return;
  if (!state.user) {
    target.innerHTML = `<a class="header-sign-in" href="/create">Sign in</a>`;
    return;
  }
  const avatar = state.user.picture ? `<img src="${escapeHtml(state.user.picture)}" alt="">` : `<span>${escapeHtml(initials(state.user.name))}</span>`;
  target.innerHTML = `<a class="account-link" href="/dashboard">${avatar}<strong>${escapeHtml(state.user.name)}</strong></a><button id="sign-out" class="sign-out-button" type="button">Sign out</button>`;
  document.querySelector("#sign-out")?.addEventListener("click", signOut);
}

async function mountGoogleButton() {
  const target = document.querySelector("#google-signin");
  if (!target) return;
  if (!state.googleClientId) {
    document.querySelector("#auth-error").textContent = "Googleログインは設定中です。";
    return;
  }
  try {
    await waitForGoogleIdentity();
    google.accounts.id.initialize({ client_id: state.googleClientId, callback: handleGoogleCredential });
    google.accounts.id.renderButton(target, { type: "standard", theme: "outline", size: "large", shape: "pill", text: "signin_with", width: 240 });
  } catch {
    document.querySelector("#auth-error").textContent = "Googleログインを読み込めませんでした。";
  }
}

async function handleGoogleCredential(response) {
  try {
    const payload = await api("/api/session", {
      method: "POST",
      auth: true,
      body: JSON.stringify({ credential: String(response.credential || "") }),
    });
    state.user = payload.user;
    await loadOwnedProfiles();
    navigateTo("/", { replace: true });
  } catch (error) {
    clearSession();
    showToast(error.message, true);
  }
}

async function loadOwnedProfiles() {
  const payload = await api("/api/me/profiles", { auth: true });
  state.ownedProfiles = payload.profiles || [];
}

async function signOut() {
  try {
    await api("/api/session", { method: "DELETE", auth: true });
  } finally {
    clearSession();
    window.google?.accounts?.id?.disableAutoSelect();
    navigateTo("/", { replace: true });
  }
}

function clearSession() {
  state.user = null;
  state.ownedProfiles = [];
}

function upsertOwnedProfile(summary) {
  const index = state.ownedProfiles.findIndex((profile) => profile.slug === summary.slug);
  if (index >= 0) state.ownedProfiles[index] = summary;
  else state.ownedProfiles.push(summary);
}

function removeOwnedProfile(slug) {
  state.ownedProfiles = state.ownedProfiles.filter((profile) => profile.slug !== slug);
}

async function waitForGoogleIdentity() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (window.google?.accounts?.id) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Google Identity Services unavailable");
}

function renderPublicProfile(profile) {
  document.querySelector(".profile-fallback")?.remove();
  document.documentElement.style.setProperty("--accent", profile.accent || "#5b5cf0");
  app.innerHTML = `<section class="public-profile">${profileMarkup(profile, { variant: "public" })}</section>`;
  bindBrandIconFallbacks(app);
  const authLink = document.querySelector("#profile-auth-link");
  if (authLink && state.user) {
    authLink.href = "/dashboard";
    authLink.textContent = "Profiles";
  }
  if (state.ownedProfiles.some((owned) => owned.slug === profile.slug)) {
    app.querySelector(".profile-actions")?.insertAdjacentHTML("afterbegin", `<a class="button button-small" href="/edit/${encodeURIComponent(profile.slug)}">編集</a>`);
  }
}

async function shareProfile() {
  const profile = JSON.parse(document.querySelector("#profile-data")?.textContent || "null");
  if (!profile) return;
  const data = { title: `${profile.displayName}｜Port`, text: profile.headline || profile.bio || "", url: location.href };
  if (navigator.share) {
    try { await navigator.share(data); } catch { return; }
  } else {
    await copyText(location.href);
  }
}

async function copyText(value) {
  await navigator.clipboard.writeText(value);
  showToast("コピーしました。");
}

async function api(path, options = {}) {
  const headers = { ...options.headers };
  if (options.body) headers["Content-Type"] = "application/json";
  if (options.auth && !["GET", "HEAD"].includes(options.method || "GET")) headers["X-Port-Request"] = "1";
  const { auth: _auth, ...fetchOptions } = options;
  const response = await fetch(path, { credentials: "same-origin", ...fetchOptions, headers });
  if (response.status === 204) return {};
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && options.auth) {
      clearSession();
      if (!document.querySelector("#profile-data")) queueMicrotask(route);
    }
    const error = new Error(payload.message || "通信に失敗しました。");
    error.code = payload.error || "REQUEST_FAILED";
    throw error;
  }
  return payload;
}

function renderError(message) {
  editor.deactivate();
  app.innerHTML = `<section class="message-page"><span class="message-icon">!</span><h1>ページを表示できません</h1><p>${escapeHtml(message)}</p><a class="button button-dark" href="/">ホームへ戻る</a></section>`;
}

function showToast(message, isError = false) {
  toast.textContent = message;
  toast.classList.toggle("is-error", isError);
  toast.classList.add("is-visible");
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove("is-visible"), 2_800);
}
