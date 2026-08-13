import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Avatar, Badge, Box, Button, Card, Container, Flex, Heading, HStack, IconButton, Link, Spinner, Stack, Text } from "@chakra-ui/react";
import { LuExternalLink, LuShare2, LuUserPlus } from "react-icons/lu";
import { api } from "./api.js";
import { NavigationDrawer } from "./navigation-drawer.jsx";
import { ProfileEditor } from "./profile-editor.jsx";
import { BookmarkButton, DiscoveryCard, ProfileView } from "./profile-components.jsx";
import { EmptyContent, LinkButton, LoadingState, MessagePage, StatusAlert, UserAvatar } from "./ui.jsx";

const APP_ROUTES = new Set(["/", "/bookmarks", "/create", "/dashboard", "/settings"]);

export function App({ bootstrap, embeddedProfile }) {
  const { pathname, navigate } = useRouter();
  const publicMatch = pathname.match(/^\/u\/([^/]+)$/u);
  const publicSlug = publicMatch ? decodeURIComponent(publicMatch[1]) : "";
  const initialPublicMatch = location.pathname.match(/^\/u\/([^/]+)$/u);
  const initialPublicSlug = initialPublicMatch ? decodeURIComponent(initialPublicMatch[1]) : "";
  const [user, setUser] = useState(bootstrap?.user || null);
  const [googleClientId, setGoogleClientId] = useState(bootstrap?.googleClientId || "");
  const [ownedProfiles, setOwnedProfiles] = useState(bootstrap?.profiles || []);
  const [bookmarks, setBookmarks] = useState(bootstrap?.bookmarks || []);
  const [ready, setReady] = useState(Boolean(bootstrap));
  const [toast, setToast] = useState({ message: "", error: false, visible: false });
  const toastTimer = useRef(null);
  const publicProfileCache = useRef(new Map(initialPublicSlug && embeddedProfile ? [[initialPublicSlug, embeddedProfile]] : []));
  const [publicRoute, setPublicRoute] = useState({ slug: initialPublicSlug, profile: embeddedProfile, loading: false, error: "" });

  const showToast = useCallback((message, error = false) => {
    setToast({ message, error, visible: true });
    clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast((current) => ({ ...current, visible: false })), 2_800);
  }, []);

  useEffect(() => () => clearTimeout(toastTimer.current), []);
  useEffect(() => {
    if (bootstrap) return;
    Promise.all([api("/api/config"), api("/api/session", { auth: true })])
      .then(async ([config, session]) => {
        setGoogleClientId(config.googleClientId || "");
        setUser(session.user);
        const [profilesPayload, bookmarksPayload] = await Promise.all([api("/api/me/profiles", { auth: true }), api("/api/me/bookmarks", { auth: true })]);
        setOwnedProfiles(profilesPayload.profiles || []);
        setBookmarks(bookmarksPayload.slugs || []);
      })
      .catch(() => setUser(null))
      .finally(() => setReady(true));
  }, []);
  useEffect(() => {
    const clear = () => {
      setUser(null);
      setOwnedProfiles([]);
      setBookmarks([]);
    };
    window.addEventListener("port:unauthorized", clear);
    return () => window.removeEventListener("port:unauthorized", clear);
  }, []);
  useEffect(() => {
    if (!publicSlug) {
      setPublicRoute({ slug: "", profile: null, loading: false, error: "" });
      return undefined;
    }
    const cached = publicProfileCache.current.get(publicSlug);
    if (cached) {
      setPublicRoute({ slug: publicSlug, profile: cached, loading: false, error: "" });
      return undefined;
    }
    const controller = new AbortController();
    setPublicRoute({ slug: publicSlug, profile: null, loading: true, error: "" });
    api(`/api/profiles/${encodeURIComponent(publicSlug)}`, { signal: controller.signal })
      .then((payload) => {
        publicProfileCache.current.set(publicSlug, payload.profile);
        setPublicRoute({ slug: publicSlug, profile: payload.profile, loading: false, error: "" });
      })
      .catch((error) => {
        if (error.name !== "AbortError") setPublicRoute({ slug: publicSlug, profile: null, loading: false, error: error.message });
      });
    return () => controller.abort();
  }, [publicSlug]);
  const publicProfile = publicRoute.slug === publicSlug ? publicRoute.profile : null;
  useEffect(() => applyMetadata(pathname, publicProfile), [pathname, publicProfile]);
  useEffect(() => {
    document.body.classList.toggle("public-profile-page", Boolean(publicSlug));
  }, [publicSlug]);

  const signOut = async () => {
    try { await api("/api/session", { method: "DELETE", auth: true }); } catch {}
    setUser(null);
    setOwnedProfiles([]);
    setBookmarks([]);
    navigate("/", { replace: true });
  };
  const signedIn = async (credential) => {
    const payload = await api("/api/session", { method: "POST", body: JSON.stringify({ credential }) });
    const [profilesPayload, bookmarksPayload] = await Promise.all([api("/api/me/profiles", { auth: true }), api("/api/me/bookmarks", { auth: true })]);
    setUser(payload.user);
    setOwnedProfiles(profilesPayload.profiles || []);
    setBookmarks(bookmarksPayload.slugs || []);
    navigate("/", { replace: true });
  };
  const toggleBookmark = async (slug) => {
    if (!user) return navigate("/create");
    const active = bookmarks.includes(slug);
    try {
      const payload = await api(`/api/me/bookmarks/${encodeURIComponent(slug)}`, { method: active ? "DELETE" : "PUT", auth: true });
      setBookmarks(payload.slugs || []);
      showToast(active ? "ブックマークから削除しました。" : "ブックマークに追加しました。");
    } catch (error) {
      showToast(error.message, true);
    }
  };
  const clearBookmarks = async () => {
    if (!bookmarks.length || !window.confirm("すべてのブックマークを削除しますか？")) return;
    try {
      await api("/api/me/bookmarks", { method: "DELETE", auth: true });
      setBookmarks([]);
      showToast("ブックマークをすべて削除しました。");
    } catch (error) { showToast(error.message, true); }
  };
  const copyText = async (value) => {
    await navigator.clipboard.writeText(value);
    showToast("コピーしました。");
  };
  const upsertOwnedProfile = (summary) => {
    publicProfileCache.current.delete(summary.slug);
    setOwnedProfiles((current) => [summary, ...current.filter((profile) => profile.slug !== summary.slug)]);
  };
  const removeOwnedProfile = (slug) => {
    publicProfileCache.current.delete(slug);
    setOwnedProfiles((current) => current.filter((profile) => profile.slug !== slug));
  };

  if (!ready) return <LoadingState />;
  const editMatch = pathname.match(/^\/edit\/([^/]+)$/u);
  const protectedRoute = pathname === "/bookmarks" || pathname === "/dashboard" || pathname === "/settings" || pathname === "/create" || editMatch;
  const page = publicSlug ? (
    publicRoute.loading ? <LoadingState label="プロフィールを読み込んでいます" /> : publicRoute.error ? <MessagePage message={publicRoute.error} /> : publicProfile ? <PublicProfile profile={publicProfile} ownedProfiles={ownedProfiles} bookmarks={bookmarks} onToggleBookmark={toggleBookmark} onCopy={copyText} /> : <NotFound />
  ) : protectedRoute && !user ? (
    <SignIn googleClientId={googleClientId} onCredential={signedIn} />
  ) : pathname === "/" ? (
    <DiscoveryPage ownedProfiles={ownedProfiles} bookmarks={bookmarks} onToggleBookmark={toggleBookmark} user={user} />
  ) : pathname === "/dashboard" ? (
    <Dashboard profiles={ownedProfiles} />
  ) : pathname === "/bookmarks" ? (
    <BookmarksPage bookmarks={bookmarks} setBookmarks={setBookmarks} ownedProfiles={ownedProfiles} onToggleBookmark={toggleBookmark} />
  ) : pathname === "/settings" ? (
    <Settings user={user} profiles={ownedProfiles} bookmarks={bookmarks} onClearBookmarks={clearBookmarks} />
  ) : pathname === "/create" ? (
    <ProfileEditor mode="create" ownedProfiles={ownedProfiles} navigate={navigate} showToast={showToast} onCreated={upsertOwnedProfile} onUpdated={upsertOwnedProfile} onDeleted={removeOwnedProfile} onCopy={copyText} />
  ) : editMatch ? (
    <ProfileEditor mode="edit" routeSlug={decodeURIComponent(editMatch[1])} ownedProfiles={ownedProfiles} navigate={navigate} showToast={showToast} onCreated={upsertOwnedProfile} onUpdated={upsertOwnedProfile} onDeleted={removeOwnedProfile} onCopy={copyText} />
  ) : <NotFound />;

  return (
    <>
      <Header pathname={pathname} user={user} publicRoute={Boolean(publicSlug)} publicProfile={publicProfile} onSignOut={signOut} onShare={() => shareProfile(publicProfile, copyText)} />
      <Box as="main" id="app" tabIndex="-1">{page}</Box>
      <StatusAlert state={toast} />
    </>
  );
}

function Header({ pathname, user, publicRoute, publicProfile, onSignOut, onShare }) {
  return (
    <Flex as="header" className={publicRoute ? "profile-header" : ""} width="100%" maxWidth={publicRoute ? "900px" : "1240px"} height={{ base: "72px", md: "88px" }} marginX="auto" paddingX={{ base: "4", md: "6" }} align="center" justify="space-between">
      <HStack gap="3">
        {user ? <NavigationDrawer currentPath={pathname} onSignOut={onSignOut} /> : null}
        <Link href="/" aria-label="URLPort ホーム" fontSize="xl" fontWeight="bold" letterSpacing="tight" textDecoration="none"><Avatar.Root size="sm" variant="outline"><Avatar.Fallback>U</Avatar.Fallback></Avatar.Root><Text as="span">URLPort</Text></Link>
      </HStack>
      <HStack gap="2">
        {publicRoute ? <IconButton variant="outline" aria-label="プロフィールを共有" disabled={!publicProfile} onClick={onShare}><LuShare2 /></IconButton> : null}
        {user ? <IconButton asChild variant="ghost" aria-label="設定" padding="0"><a href="/settings"><UserAvatar name={user.name} src={user.picture} /></a></IconButton> : <LinkButton href="/create" size="sm" variant="outline">Sign in</LinkButton>}
      </HStack>
    </Flex>
  );
}

function DiscoveryPage({ ownedProfiles, bookmarks, onToggleBookmark, user }) {
  const [profiles, setProfiles] = useState([]);
  const [loading, setLoading] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState("");
  const state = useRef({ seed: "", cursor: 0, loading: false, done: false });
  const sentinel = useRef(null);
  const owned = useMemo(() => new Set(ownedProfiles.map((profile) => profile.slug)), [ownedProfiles]);
  const loadMore = useCallback(async () => {
    if (state.current.loading || state.current.done) return;
    state.current.loading = true;
    setLoading(true);
    setError("");
    try {
      const seed = state.current.seed ? `&seed=${encodeURIComponent(state.current.seed)}` : "";
      const payload = await api(`/api/discover?limit=8&cursor=${state.current.cursor}${seed}`);
      setProfiles((current) => [...current, ...(payload.profiles || []).filter((profile) => !current.some((item) => item.slug === profile.slug))]);
      state.current.seed = payload.seed || state.current.seed;
      state.current.cursor = Number(payload.nextCursor) || state.current.cursor;
      state.current.done = !payload.hasMore || !(payload.profiles || []).length;
      setDone(state.current.done);
    } catch (requestError) { setError(requestError.message); }
    finally { state.current.loading = false; setLoading(false); }
  }, []);
  useEffect(() => {
    const observer = new IntersectionObserver((entries) => { if (entries.some((entry) => entry.isIntersecting)) loadMore(); }, { rootMargin: "500px 0px" });
    if (sentinel.current) observer.observe(sentinel.current);
    return () => observer.disconnect();
  }, [loadMore]);
  return <Container as="section" maxWidth="3xl" paddingX={{ base: "3", md: "4" }} paddingBottom="10" aria-labelledby="discovery-title"><Heading id="discovery-title" className="visually-hidden">公開プロフィール</Heading><Stack gap={{ base: "4", md: "6" }}>{profiles.map((profile) => <DiscoveryCard key={profile.slug} profile={profile} bookmarked={bookmarks.includes(profile.slug)} owned={owned.has(profile.slug)} onToggleBookmark={onToggleBookmark} />)}{!profiles.length && done ? <EmptyContent title="公開プロフィールはまだありません" action={<LinkButton href="/create">{user ? "プロフィールを作成" : "Sign in"}</LinkButton>} /> : null}</Stack>{!done ? <Flex ref={sentinel} minHeight="24" align="center" justify="center">{error ? <Button variant="outline" onClick={loadMore}>再読み込み</Button> : loading ? <Spinner /> : null}</Flex> : null}</Container>;
}

function Dashboard({ profiles }) {
  return <Container maxWidth="4xl" paddingY={{ base: "6", md: "10" }}><Flex align="center" justify="space-between" marginBottom="8"><Heading size="3xl">Profiles</Heading><LinkButton href="/create">New</LinkButton></Flex><Stack gap="3">{profiles.map((profile) => <Card.Root key={profile.slug} variant="outline"><Card.Body><Flex align="center" justify="space-between" gap="4"><Link href={`/edit/${encodeURIComponent(profile.slug)}`} flex="1" textDecoration="none"><Heading size="md">{profile.displayName}</Heading><Text color="fg.muted" textStyle="sm">/u/{profile.slug}</Text></Link><IconButton asChild variant="ghost" aria-label="公開ページを開く"><a href={`/u/${encodeURIComponent(profile.slug)}`} target="_blank"><LuExternalLink /></a></IconButton></Flex></Card.Body></Card.Root>)}</Stack>{!profiles.length ? <EmptyContent title="プロフィールはまだありません" action={<LinkButton href="/create"><LuUserPlus />作成する</LinkButton>} /> : null}</Container>;
}

function BookmarksPage({ bookmarks, setBookmarks, ownedProfiles, onToggleBookmark }) {
  const [profiles, setProfiles] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  useEffect(() => {
    api("/api/me/bookmarks", { auth: true }).then((payload) => { setBookmarks(payload.slugs || []); setProfiles(payload.profiles || []); }).catch((requestError) => setError(requestError.message)).finally(() => setLoading(false));
  }, []);
  if (loading) return <LoadingState label="ブックマークを読み込んでいます" />;
  if (error) return <MessagePage message={error} />;
  const visible = profiles.filter((profile) => bookmarks.includes(profile.slug));
  const owned = new Set(ownedProfiles.map((profile) => profile.slug));
  return <Container maxWidth="3xl" paddingX={{ base: "0", md: "4" }} paddingY={{ base: "6", md: "10" }}><HStack paddingX={{ base: "4", md: "0" }} marginBottom="8" justify="space-between"><Heading size="3xl">Bookmarks</Heading><Badge variant="subtle" size="lg">{visible.length}</Badge></HStack><Stack gap={{ base: "3", md: "8" }}>{visible.map((profile) => <DiscoveryCard key={profile.slug} profile={profile} bookmarked owned={owned.has(profile.slug)} onToggleBookmark={onToggleBookmark} />)}</Stack>{!visible.length ? <EmptyContent title="ブックマークはまだありません" action={<LinkButton href="/" variant="outline">プロフィールを見る</LinkButton>} /> : null}</Container>;
}

function Settings({ user, profiles, bookmarks, onClearBookmarks }) {
  return <Container maxWidth="3xl" paddingY={{ base: "6", md: "10" }}><Heading size="3xl" marginBottom="8">Settings</Heading><Stack gap="4"><Card.Root variant="outline"><Card.Header><Card.Title>Account</Card.Title></Card.Header><Card.Body><HStack gap="4"><UserAvatar name={user.name} src={user.picture} size="lg" /><Box minWidth="0"><Text fontWeight="semibold" truncate>{user.name}</Text><Text color="fg.muted" textStyle="sm" truncate>{user.email}</Text></Box></HStack></Card.Body></Card.Root><Card.Root variant="outline"><Card.Body><Flex align="center" justify="space-between" gap="4"><Box><Heading size="sm">Profiles</Heading><Text color="fg.muted" textStyle="sm">{profiles.length}件のプロフィールがあります。</Text></Box><LinkButton href="/dashboard" variant="outline" size="sm">管理</LinkButton></Flex></Card.Body></Card.Root><Card.Root variant="outline"><Card.Body><Flex align="center" justify="space-between" gap="4"><Box><Heading size="sm">Bookmarks</Heading><Text color="fg.muted" textStyle="sm">{bookmarks.length}件保存されています。</Text></Box><Button colorPalette="red" variant="outline" size="sm" disabled={!bookmarks.length} onClick={onClearBookmarks}>すべて削除</Button></Flex></Card.Body></Card.Root></Stack></Container>;
}

function PublicProfile({ profile, ownedProfiles, bookmarks, onToggleBookmark, onCopy }) {
  const owned = ownedProfiles.some((item) => item.slug === profile.slug);
  const actions = <>{owned ? <LinkButton href={`/edit/${encodeURIComponent(profile.slug)}`} size="sm" variant="outline">編集</LinkButton> : null}<BookmarkButton slug={profile.slug} active={bookmarks.includes(profile.slug)} hidden={owned} onToggle={onToggleBookmark} /></>;
  return <Card.Root as="section" className="public-profile" style={{ "--accent": profile.accent || "#5b5cf0" }} variant="elevated"><ProfileView profile={profile} actions={actions} onCopy={onCopy} /></Card.Root>;
}

function SignIn({ googleClientId, onCredential }) {
  const target = useRef(null);
  const [error, setError] = useState("");
  useEffect(() => {
    if (!googleClientId) return undefined;
    let cancelled = false;
    waitForGoogleIdentity().then(() => {
      if (cancelled || !target.current) return;
      google.accounts.id.initialize({
        client_id: googleClientId,
        callback: (response) => onCredential(String(response.credential || "")).catch((requestError) => setError(requestError.message)),
      });
      google.accounts.id.renderButton(target.current, { type: "standard", theme: "outline", size: "large", shape: "pill", text: "signin_with", width: 240 });
    }).catch(() => setError("Googleログインを読み込めませんでした。"));
    return () => { cancelled = true; target.current?.replaceChildren(); };
  }, [googleClientId]);
  return <Stack as="section" minHeight="calc(100vh - 184px)" align="center" justify="center" gap="5" textAlign="center"><Avatar.Root size="2xl" variant="outline"><Avatar.Fallback>U</Avatar.Fallback></Avatar.Root><Heading size="3xl">Sign in</Heading><Box ref={target} />{error ? <Text color="fg.error" textStyle="sm">{error}</Text> : !googleClientId ? <Text color="fg.muted" textStyle="sm">Googleログインは設定中です。</Text> : null}</Stack>;
}

function NotFound() { return <MessagePage message="ページが見つかりません。" />; }

function useRouter() {
  const [pathname, setPathname] = useState(location.pathname);
  const navigate = useCallback((path, { replace = false } = {}) => {
    history[replace ? "replaceState" : "pushState"](null, "", path);
    setPathname(location.pathname);
    window.scrollTo({ top: 0, behavior: "auto" });
    queueMicrotask(() => document.querySelector("#app")?.focus({ preventScroll: true }));
  }, []);
  useEffect(() => {
    const popstate = () => setPathname(location.pathname);
    const click = (event) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
      if (!link || link.target || link.hasAttribute("download")) return;
      const target = new URL(link.href, location.href);
      if (target.origin !== location.origin || !(APP_ROUTES.has(target.pathname) || /^\/(?:edit|u)\/[^/]+$/u.test(target.pathname))) return;
      event.preventDefault();
      if (target.href !== location.href) navigate(`${target.pathname}${target.search}${target.hash}`);
    };
    window.addEventListener("popstate", popstate);
    document.addEventListener("click", click);
    return () => { window.removeEventListener("popstate", popstate); document.removeEventListener("click", click); };
  }, [navigate]);
  return { pathname, navigate };
}

function applyMetadata(pathname, profile) {
  const metadata = pathname === "/" ? ["URLPort", "index, follow, max-image-preview:large"] : pathname === "/bookmarks" ? ["Bookmarks｜URLPort", "noindex, nofollow"] : pathname === "/dashboard" ? ["Profiles｜URLPort", "noindex, nofollow"] : pathname === "/settings" ? ["Settings｜URLPort", "noindex, nofollow"] : pathname === "/create" ? ["New profile｜URLPort", "noindex, nofollow"] : pathname.startsWith("/edit/") ? ["Edit profile｜URLPort", "noindex, nofollow"] : profile ? [`${profile.displayName}｜URLPort`, "index, follow, max-image-preview:large"] : ["URLPort", "noindex, nofollow"];
  document.title = metadata[0];
  document.querySelector('meta[name="robots"]')?.setAttribute("content", metadata[1]);
}

async function shareProfile(profile, copyText) {
  if (!profile) return;
  const data = { title: `${profile.displayName}｜URLPort`, text: profile.headline || profile.bio || "", url: location.href };
  if (navigator.share) { try { await navigator.share(data); } catch {} }
  else await copyText(location.href);
}

async function waitForGoogleIdentity() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (window.google?.accounts?.id) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Google Identity Services unavailable");
}
