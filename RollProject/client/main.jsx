import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { api } from "./api.js";
import { Markdown } from "./markdown.jsx";

const date = new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "short", day: "numeric" });
const time = new Intl.DateTimeFormat("ja-JP", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });

function App() {
  const [path, setPath] = useState(location.pathname + location.search);
  const [session, setSession] = useState(undefined);
  const [notice, setNotice] = useState("");
  useEffect(() => { api("/api/session").then((data) => setSession(data.user)).catch(() => setSession(null)); }, []);
  useEffect(() => { const listener = () => setPath(location.pathname + location.search); addEventListener("popstate", listener); return () => removeEventListener("popstate", listener); }, []);
  const navigate = (to) => { history.pushState({}, "", to); setPath(to); scrollTo({ top: 0, behavior: "instant" }); };
  const route = useMemo(() => parseRoute(path), [path]);
  return <>
    <Header session={session} navigate={navigate} onSession={setSession} notice={notice} setNotice={setNotice} />
    <main>
      {route.kind === "home" && <Home navigate={navigate} />}
      {route.kind === "search" && <Search query={route.query} navigate={navigate} />}
      {route.kind === "new" && <Editor session={session} navigate={navigate} setNotice={setNotice} />}
      {route.kind === "settings" && <Settings session={session} onSession={setSession} setNotice={setNotice} />}
      {route.kind === "user" && <UserPage userId={route.userId} navigate={navigate} />}
      {route.kind === "article" && <ArticlePage userId={route.userId} articleId={route.articleId} session={session} navigate={navigate} setNotice={setNotice} />}
      {route.kind === "not-found" && <Empty title="ページが見つかりません" body="URLを確認するか、トップページへ戻ってください。" />}
    </main>
    <Footer />
  </>;
}

function Header({ session, navigate, onSession, notice, setNotice }) {
  const [search, setSearch] = useState("");
  const [menu, setMenu] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  useEffect(() => { if (!notice) return; const id = setTimeout(() => setNotice(""), 3500); return () => clearTimeout(id); }, [notice, setNotice]);
  const submit = (event) => { event.preventDefault(); if (search.trim()) { navigate(`/search?q=${encodeURIComponent(search.trim())}`); setSearchOpen(false); } };
  return <>
    <header className="site-header">
      <button className="wordmark" onClick={() => navigate("/")} aria-label="トップへ"><span className="mark">R</span><span>RollProject</span></button>
      <form className={`search${searchOpen ? " open" : ""}`} onSubmit={submit}><button type="submit" aria-label="検索"><Icon name="search" /></button><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="タイトルを検索" aria-label="タイトルを検索" /></form>
      <nav>
        <button className="icon-button mobile-search" aria-label="検索を開く" onClick={() => { setSearchOpen((value) => !value); setTimeout(() => document.querySelector(".search.open input")?.focus(), 0); }}><Icon name="search" /></button>
        {session ? <>
          <button className="write-button" onClick={() => navigate("/new")}><Icon name="pen" />書く</button>
          <button className="avatar" onClick={() => setMenu(!menu)} aria-label="アカウントメニュー">{session.picture ? <img src={session.picture} alt="" /> : session.name.slice(0, 1)}</button>
          {menu && <div className="account-menu">
            <div className="account-name"><strong>{session.profile?.displayName || session.name}</strong><small>{session.profile ? `@${session.profile.userId}` : "ID未設定"}</small></div>
            <button onClick={() => { navigate("/settings"); setMenu(false); }}>プロフィール設定</button>
            {session.profile && <button onClick={() => { navigate(`/${session.profile.userId}`); setMenu(false); }}>自分の記事</button>}
            <button onClick={async () => { await api("/api/session", { method: "DELETE" }); onSession(null); setMenu(false); setNotice("ログアウトしました"); }}>ログアウト</button>
          </div>}
        </> : <LoginButton onLogin={onSession} />}
      </nav>
    </header>
    {notice && <div className="toast">{notice}</div>}
  </>;
}

function LoginButton({ onLogin }) {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let cancelled = false;
    api("/api/config").then(({ googleClientId }) => {
      if (!googleClientId) return;
      const init = () => { if (cancelled) return; google.accounts.id.initialize({ client_id: googleClientId, callback: async ({ credential }) => { const result = await api("/api/session", { method: "POST", body: JSON.stringify({ credential }) }); onLogin(result.user); } }); setReady(true); };
      if (globalThis.google?.accounts) return init();
      const script = document.createElement("script"); script.src = "https://accounts.google.com/gsi/client"; script.async = true; script.onload = init; document.head.append(script);
    }).catch(() => {});
    return () => { cancelled = true; };
  }, [onLogin]);
  return <button className="login-button" disabled={!ready} onClick={() => google.accounts.id.prompt()}>{ready ? "Googleでログイン" : "ログイン"}</button>;
}

function Home({ navigate }) {
  const resource = useResource("/api/articles");
  return <div className="page-shell">
    <section className="home-head"><div><h1>新着</h1><p>最近動いたスレッド</p></div><button className="primary" onClick={() => navigate("/new")}><Icon name="pen" />新しい投稿</button></section>
    <button className="quick-post" onClick={() => navigate("/new")}><span className="quick-avatar">+</span><span>タイトルをつけて書き始める</span><b>投稿</b></button>
    <section className="feed home-feed">
      {resource.loading ? <Skeleton /> : resource.error ? <Empty title="読み込めませんでした" body={resource.error} /> : resource.data.articles.length ? resource.data.articles.map((item) => <ArticleRow key={item.articleId} item={item} navigate={navigate} />) : <Empty title="投稿はまだありません" body="" />}
    </section>
  </div>;
}

function ArticleRow({ item, navigate }) {
  return <button className="article-row" onClick={() => navigate(`/${item.userId}/${item.articleId}`)}>
    <div className="article-main"><div className="article-meta"><span>@{item.userId}</span><i>·</i><time>{date.format(new Date(item.createdAt))}</time></div><h3>{item.title}</h3></div>
    <div className="reply-count"><Icon name="thread" /><span>{item.replyCount}</span></div><span className="arrow">↗</span>
  </button>;
}

function Search({ query, navigate }) {
  const resource = useResource(query ? `/api/search?q=${encodeURIComponent(query)}` : null);
  return <div className="narrow-page"><h1>「{query}」の検索結果</h1><p className="subtle">タイトル検索</p><div className="feed compact">{resource.loading ? <Skeleton /> : resource.error ? <Empty title="検索できませんでした" body={resource.error} /> : resource.data.articles.length ? resource.data.articles.map((item) => <ArticleRow key={item.articleId} item={item} navigate={navigate} />) : <Empty title="見つかりませんでした" body="別の言葉で検索してみてください。" />}</div></div>;
}

function UserPage({ userId, navigate }) {
  const resource = useResource(`/api/users/${encodeURIComponent(userId)}`);
  if (resource.loading) return <div className="narrow-page"><Skeleton /></div>;
  if (resource.error) return <div className="narrow-page"><Empty title="ユーザーが見つかりません" body={resource.error} /></div>;
  const { user, articles } = resource.data;
  return <div className="narrow-page"><section className="user-profile"><div className="monogram">{user.displayName.slice(0, 1)}</div><div><p className="user-handle">@{user.userId}</p><h1>{user.displayName}</h1>{user.bio && <p>{user.bio}</p>}<small>{date.format(new Date(user.createdAt))} から参加</small></div></section><div className="section-heading"><div><h2>投稿</h2></div><small>{articles.length}件</small></div><div className="feed compact">{articles.length ? articles.map((item) => <ArticleRow key={item.articleId} item={item} navigate={navigate} />) : <Empty title="まだ記事がありません" body="" />}</div></div>;
}

function ArticlePage({ userId, articleId, session, navigate, setNotice }) {
  const [version, setVersion] = useState(0); const resource = useResource(`/api/articles/${encodeURIComponent(userId)}/${encodeURIComponent(articleId)}?v=${version}`);
  const [reply, setReply] = useState(""); const [editing, setEditing] = useState(false); const [saving, setSaving] = useState(false);
  if (resource.loading) return <div className="article-page"><Skeleton /></div>;
  if (resource.error) return <div className="article-page"><Empty title="記事が見つかりません" body={resource.error} /></div>;
  const article = resource.data.article; const own = session?.profile?.userId === article.userId;
  const sendReply = async (event) => { event.preventDefault(); if (!session) return setNotice("返信するにはGoogleログインが必要です"); if (!session.profile) return navigate("/settings"); setSaving(true); try { await api(`/api/articles/${article.userId}/${article.articleId}/replies`, { method: "POST", body: JSON.stringify({ body: reply }) }); setReply(""); setVersion((value) => value + 1); setNotice("返信を投稿しました"); } catch (error) { setNotice(error.message); } finally { setSaving(false); } };
  return <article className="article-page">
    <div className="article-top"><button className="author-link" onClick={() => navigate(`/${article.userId}`)}>@{article.userId}</button><span> / </span><span>{date.format(new Date(article.createdAt))}</span>{article.updatedAt !== article.createdAt && <span>（更新 {time.format(new Date(article.updatedAt))}）</span>}</div>
    <h1>{article.title}</h1><div className="thread-label"><span>THREAD</span><i /><b>{article.replyCount + 1}</b></div>
    <ThreadPost number={1} name={article.authorName} userId={article.userId} createdAt={article.createdAt} owner><Markdown>{article.body}</Markdown></ThreadPost>
    {(article.replies || []).map((item) => <ThreadPost key={item.replyId} number={item.number} name={item.authorName} userId={item.authorUserId} createdAt={item.createdAt}><Markdown>{item.body}</Markdown></ThreadPost>)}
    {editing ? <ArticleEdit article={article} onCancel={() => setEditing(false)} onSaved={() => { setEditing(false); setVersion((value) => value + 1); setNotice("記事を更新しました"); }} /> : own && <button className="text-button edit-link" onClick={() => setEditing(true)}><Icon name="pen" />本文とタイトルを編集</button>}
    <form className="reply-form" onSubmit={sendReply}><div><h2>返信を追加</h2></div><textarea value={reply} onChange={(event) => setReply(event.target.value)} placeholder={session ? "返信を書く" : "返信するにはログインしてください"} disabled={!session || saving} maxLength={12000} required /><div className="form-foot"><small>{reply.length.toLocaleString("ja-JP")} / 12,000</small><button disabled={!session || saving || !reply.trim()}>{saving ? "送信中…" : "返信する"}</button></div></form>
  </article>;
}

function ThreadPost({ number, name, userId, createdAt, owner, children }) {
  return <section className="thread-post"><div className="post-number">{String(number).padStart(2, "0")}</div><div className="post-content"><div className="post-meta"><strong>{name}</strong><span>@{userId}</span>{owner && <em>AUTHOR</em>}<time>{time.format(new Date(createdAt))}</time></div>{children}</div></section>;
}

function Editor({ session, navigate, setNotice }) {
  const [title, setTitle] = useState(""); const [body, setBody] = useState(""); const [preview, setPreview] = useState(false); const [saving, setSaving] = useState(false);
  if (session === undefined) return <div className="editor-page"><Skeleton /></div>;
  if (!session) return <div className="editor-page"><Empty title="書くにはログインが必要です" body="ヘッダーのGoogleログインから始めてください。" /></div>;
  if (!session.profile) return <div className="editor-page"><Empty title="先にユーザーIDを設定してください" body="記事のURLに使うIDを設定します。" action={() => navigate("/settings")} actionLabel="設定へ" /></div>;
  const submit = async () => { setSaving(true); try { const { article } = await api("/api/articles", { method: "POST", body: JSON.stringify({ title, body }) }); navigate(`/${article.userId}/${article.articleId}`); setNotice("スレッドを公開しました"); } catch (error) { setNotice(error.message); } finally { setSaving(false); } };
  return <div className="editor-page"><div className="editor-head"><div><h1>新しい投稿</h1></div><div className="editor-actions"><button className="text-button" onClick={() => setPreview(!preview)}>{preview ? "編集に戻る" : "プレビュー"}</button><button className="primary" disabled={saving || !title.trim() || !body.trim()} onClick={submit}>{saving ? "公開中…" : "公開する"}</button></div></div>
    <div className="paper">{preview ? <><h1 className="preview-title">{title || "無題のスレッド"}</h1><Markdown>{body || "ここにプレビューが表示されます。"}</Markdown></> : <><input className="title-input" value={title} onChange={(event) => setTitle(event.target.value)} placeholder="タイトル" maxLength={120} autoFocus /><textarea className="body-input" value={body} onChange={(event) => setBody(event.target.value)} placeholder="本文を書く" maxLength={50000} /></>}</div><div className="editor-foot"><span>{body.length.toLocaleString("ja-JP")} / 50,000</span></div>
  </div>;
}

function ArticleEdit({ article, onCancel, onSaved }) {
  const [title, setTitle] = useState(article.title); const [body, setBody] = useState(article.body); const [saving, setSaving] = useState(false);
  return <form className="inline-editor" onSubmit={async (event) => { event.preventDefault(); setSaving(true); try { await api(`/api/articles/${article.userId}/${article.articleId}`, { method: "PUT", body: JSON.stringify({ title, body }) }); onSaved(); } finally { setSaving(false); } }}><input value={title} onChange={(event) => setTitle(event.target.value)} maxLength={120} required /><textarea value={body} onChange={(event) => setBody(event.target.value)} maxLength={50000} required /><div><button type="button" className="text-button" onClick={onCancel}>キャンセル</button><button className="primary" disabled={saving}>{saving ? "保存中…" : "変更を保存"}</button></div></form>;
}

function Settings({ session, onSession, setNotice }) {
  const [userId, setUserId] = useState(session?.profile?.userId || ""); const [displayName, setDisplayName] = useState(session?.profile?.displayName || session?.name || ""); const [bio, setBio] = useState(session?.profile?.bio || ""); const [saving, setSaving] = useState(false);
  if (session === undefined) return <div className="form-page"><Skeleton /></div>; if (!session) return <div className="form-page"><Empty title="ログインが必要です" body="" /></div>;
  return <div className="form-page"><h1>プロフィール設定</h1><p className="subtle">ユーザーIDは記事URLに使われます。</p><form onSubmit={async (event) => { event.preventDefault(); setSaving(true); try { const result = await api("/api/me/profile", { method: "PUT", body: JSON.stringify({ userId, displayName, bio }) }); onSession(result.user); setNotice("プロフィールを保存しました"); } catch (error) { setNotice(error.message); } finally { setSaving(false); } }}><label>ユーザーID<div className="slug-input"><span>rollprojects.com/</span><input value={userId} onChange={(event) => setUserId(event.target.value.toLowerCase())} placeholder="your-id" minLength={3} maxLength={30} pattern="[a-z0-9][a-z0-9_-]{1,28}[a-z0-9]" required /></div><small>半角英数字・ハイフン・アンダースコア、3〜30文字</small></label><label>表示名<input value={displayName} onChange={(event) => setDisplayName(event.target.value)} maxLength={60} required /></label><label>自己紹介<textarea value={bio} onChange={(event) => setBio(event.target.value)} maxLength={240} rows={4} /></label><button className="primary" disabled={saving}>{saving ? "保存中…" : "保存する"}</button></form></div>;
}

function useResource(path) {
  const [state, setState] = useState({ loading: Boolean(path), data: null, error: "" });
  useEffect(() => { let active = true; if (!path) return setState({ loading: false, data: { articles: [] }, error: "" }); setState({ loading: true, data: null, error: "" }); api(path).then((data) => active && setState({ loading: false, data, error: "" })).catch((error) => active && setState({ loading: false, data: null, error: error.message })); return () => { active = false; }; }, [path]);
  return state;
}

function Empty({ title, body, action, actionLabel }) { return <div className="empty"><span>◇</span><h2>{title}</h2>{body && <p>{body}</p>}{action && <button onClick={action}>{actionLabel}</button>}</div>; }
function Skeleton() { return <div className="skeleton"><i /><i /><i /></div>; }
function Footer() { return <footer><span>RollProject</span><small>© {new Date().getFullYear()} RollProjects</small></footer>; }
function parseRoute(value) { const url = new URL(value, location.origin); const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent); if (!parts.length) return { kind: "home" }; if (parts[0] === "search") return { kind: "search", query: url.searchParams.get("q") || "" }; if (parts[0] === "new" && parts.length === 1) return { kind: "new" }; if (parts[0] === "settings" && parts.length === 1) return { kind: "settings" }; if (parts.length === 1) return { kind: "user", userId: parts[0] }; if (parts.length === 2) return { kind: "article", userId: parts[0], articleId: parts[1] }; return { kind: "not-found" }; }
function Icon({ name }) { const paths = { search: <><circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/></>, pen: <><path d="m4 20 4.5-1 10-10-3.5-3.5-10 10z"/><path d="m13.5 6.5 3.5 3.5"/></>, thread: <><path d="M5 7h14M5 12h10M5 17h7"/></> }; return <svg viewBox="0 0 24 24" aria-hidden="true">{paths[name]}</svg>; }

createRoot(document.getElementById("root")).render(<App />);
