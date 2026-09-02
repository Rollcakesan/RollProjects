import { randomBytes } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_FILE = resolve(fileURLToPath(new URL("../.data/store.json", import.meta.url)));

export class StoreError extends Error {
  constructor(message, status = 500, code = "STORE_ERROR") {
    super(message); this.name = "StoreError"; this.status = status; this.code = code;
  }
}

export async function createStore(options = {}) {
  if (options.firestore || process.env.FIRESTORE_DATABASE || process.env.K_SERVICE) {
    const { Firestore } = await import("@google-cloud/firestore");
    const databaseId = options.databaseId || process.env.FIRESTORE_DATABASE || "(default)";
    return new FirestoreStore(options.firestore || new Firestore({ databaseId }));
  }
  return new LocalStore(options.file || process.env.DATA_FILE || DEFAULT_FILE);
}

export class LocalStore {
  constructor(file = DEFAULT_FILE) { this.file = resolve(file); this.pending = Promise.resolve(); }

  async getMe(subject) { return (await this.read()).users[subject] || null; }
  async getPublicUser(userId) { return Object.values((await this.read()).users).find((user) => user.userId === userId) || null; }

  async saveProfile(subject, profile, identity) {
    return await this.mutate((data) => {
      const claimed = data.userIds[profile.userId];
      if (claimed && claimed !== subject) throw new StoreError("このユーザーIDは使用されています。", 409, "USER_ID_TAKEN");
      const current = data.users[subject];
      if (current?.userId && current.userId !== profile.userId) delete data.userIds[current.userId];
      const now = new Date().toISOString();
      const user = { ...profile, subject, email: identity.email, picture: identity.picture, createdAt: current?.createdAt || now, updatedAt: now };
      data.users[subject] = user; data.userIds[profile.userId] = subject;
      return user;
    });
  }

  async listLatest(limit = 30) {
    return Object.values((await this.read()).articles).sort(byActivity).slice(0, limit).map(articleSummary);
  }
  async listByUser(userId, limit = 50) {
    return Object.values((await this.read()).articles).filter((item) => item.userId === userId).sort(byCreated).slice(0, limit).map(articleSummary);
  }
  async searchArticles(normalized, _token, limit = 40) {
    return Object.values((await this.read()).articles).filter((item) => item.titleNormalized.includes(normalized)).sort(byActivity).slice(0, limit).map(articleSummary);
  }
  async getArticle(userId, articleId) {
    const article = (await this.read()).articles[articleId];
    if (!article || article.userId !== userId) throw notFound();
    return publicArticle(article);
  }

  async createArticle(subject, user, input) {
    return await this.mutate((data) => {
      const articleId = makeId(); const now = new Date().toISOString();
      const article = { ...input, articleId, ownerSubject: subject, userId: user.userId, authorName: user.displayName, replyCount: 0, replies: [], createdAt: now, updatedAt: now, lastActivityAt: now };
      data.articles[articleId] = article;
      return publicArticle(article);
    });
  }

  async updateArticle(subject, userId, articleId, input) {
    return await this.mutate((data) => {
      const article = data.articles[articleId];
      if (!article || article.userId !== userId) throw notFound();
      if (article.ownerSubject !== subject) throw forbidden();
      Object.assign(article, input, { updatedAt: new Date().toISOString() });
      return publicArticle(article);
    });
  }

  async addReply(subject, user, userId, articleId, input) {
    return await this.mutate((data) => {
      const article = data.articles[articleId];
      if (!article || article.userId !== userId) throw notFound();
      const now = new Date().toISOString();
      const reply = { ...input, replyId: makeId(), number: article.replies.length + 2, authorSubject: subject, authorUserId: user.userId, authorName: user.displayName, createdAt: now };
      article.replies.push(reply); article.replyCount = article.replies.length; article.lastActivityAt = now;
      return reply;
    });
  }

  async read() {
    try { return normalizeData(JSON.parse(await readFile(this.file, "utf8"))); }
    catch (error) { if (error?.code === "ENOENT") return normalizeData({}); throw error; }
  }
  async mutate(callback) {
    const operation = this.pending.then(async () => {
      const data = await this.read(); const result = callback(data);
      await mkdir(dirname(this.file), { recursive: true });
      const temp = `${this.file}.${process.pid}.tmp`;
      await writeFile(temp, JSON.stringify(data, null, 2)); await rename(temp, this.file);
      return result;
    });
    this.pending = operation.catch(() => {}); return await operation;
  }
}

class FirestoreStore {
  constructor(db) { this.db = db; }
  async getMe(subject) { const snap = await this.db.collection("users").doc(subject).get(); return snap.exists ? snap.data() : null; }
  async getPublicUser(userId) { const snap = await this.db.collection("userIds").doc(userId).get(); if (!snap.exists) return null; return await this.getMe(snap.data().subject); }
  async saveProfile(subject, profile, identity) {
    const db = this.db; const userRef = db.collection("users").doc(subject); const claimRef = db.collection("userIds").doc(profile.userId);
    return await db.runTransaction(async (tx) => {
      const [currentSnap, claimSnap] = await Promise.all([tx.get(userRef), tx.get(claimRef)]);
      if (claimSnap.exists && claimSnap.data().subject !== subject) throw new StoreError("このユーザーIDは使用されています。", 409, "USER_ID_TAKEN");
      const current = currentSnap.exists ? currentSnap.data() : null; const now = new Date().toISOString();
      const user = { ...profile, subject, email: identity.email, picture: identity.picture, createdAt: current?.createdAt || now, updatedAt: now };
      if (current?.userId && current.userId !== profile.userId) tx.delete(db.collection("userIds").doc(current.userId));
      tx.set(claimRef, { subject }); tx.set(userRef, user); return user;
    });
  }
  async listLatest(limit = 30) { const snap = await this.db.collection("articles").orderBy("lastActivityAt", "desc").limit(limit).get(); return snap.docs.map((doc) => articleSummary(doc.data())); }
  async listByUser(userId, limit = 50) { const snap = await this.db.collection("articles").where("userId", "==", userId).orderBy("createdAt", "desc").limit(limit).get(); return snap.docs.map((doc) => articleSummary(doc.data())); }
  async searchArticles(normalized, token, limit = 40) {
    const snap = await this.db.collection("articles").where("searchTokens", "array-contains", token).limit(100).get();
    return snap.docs.map((doc) => doc.data()).filter((item) => item.titleNormalized.includes(normalized)).sort(byActivity).slice(0, limit).map(articleSummary);
  }
  async getArticle(userId, articleId) {
    const ref = this.db.collection("articles").doc(articleId); const [snap, replies] = await Promise.all([ref.get(), ref.collection("replies").orderBy("number").get()]);
    if (!snap.exists || snap.data().userId !== userId) throw notFound();
    return publicArticle({ ...snap.data(), replies: replies.docs.map((doc) => doc.data()) });
  }
  async createArticle(subject, user, input) {
    const ref = this.db.collection("articles").doc(); const now = new Date().toISOString();
    const article = { ...input, articleId: ref.id, ownerSubject: subject, userId: user.userId, authorName: user.displayName, replyCount: 0, createdAt: now, updatedAt: now, lastActivityAt: now };
    await ref.set(article); return publicArticle({ ...article, replies: [] });
  }
  async updateArticle(subject, userId, articleId, input) {
    const ref = this.db.collection("articles").doc(articleId); const snap = await ref.get();
    if (!snap.exists || snap.data().userId !== userId) throw notFound(); if (snap.data().ownerSubject !== subject) throw forbidden();
    await ref.update({ ...input, updatedAt: new Date().toISOString() }); return await this.getArticle(userId, articleId);
  }
  async addReply(subject, user, userId, articleId, input) {
    const db = this.db; const ref = db.collection("articles").doc(articleId); const replyRef = ref.collection("replies").doc();
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref); if (!snap.exists || snap.data().userId !== userId) throw notFound();
      const now = new Date().toISOString(); const number = Number(snap.data().replyCount || 0) + 2;
      const reply = { ...input, replyId: replyRef.id, number, authorSubject: subject, authorUserId: user.userId, authorName: user.displayName, createdAt: now };
      tx.set(replyRef, reply); tx.update(ref, { replyCount: number - 1, lastActivityAt: now }); return reply;
    });
  }
}

function normalizeData(data) { return { users: data.users || {}, userIds: data.userIds || {}, articles: data.articles || {} }; }
function makeId() { return randomBytes(8).toString("base64url"); }
function byActivity(a, b) { return String(b.lastActivityAt).localeCompare(String(a.lastActivityAt)); }
function byCreated(a, b) { return String(b.createdAt).localeCompare(String(a.createdAt)); }
function articleSummary(item) { return { articleId: item.articleId, userId: item.userId, title: item.title, authorName: item.authorName, replyCount: item.replyCount || 0, createdAt: item.createdAt, updatedAt: item.updatedAt, lastActivityAt: item.lastActivityAt }; }
function publicArticle(item) {
  const { ownerSubject: _owner, titleNormalized: _normalized, searchTokens: _tokens, ...publicItem } = item;
  publicItem.replies = (publicItem.replies || []).map(({ authorSubject: _subject, ...reply }) => reply);
  return publicItem;
}
function notFound() { return new StoreError("記事が見つかりません。", 404, "NOT_FOUND"); }
function forbidden() { return new StoreError("この記事を編集する権限がありません。", 403, "FORBIDDEN"); }
