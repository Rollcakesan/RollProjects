import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { LocalStore, StoreError } from "../src/store.mjs";

test("local store supports profiles, threads, replies and title-only search", async () => {
  const directory = await mkdtemp(join(tmpdir(), "rollproject-store-"));
  const store = new LocalStore(join(directory, "store.json"));
  const identity = { email: "writer@example.com", picture: "https://example.com/me.jpg" };
  try {
    const writer = await store.saveProfile("google-writer", { userId: "writer", displayName: "書き手", bio: "" }, identity);
    const reader = await store.saveProfile("google-reader", { userId: "reader", displayName: "読み手", bio: "" }, identity);
    await assert.rejects(() => store.saveProfile("another", { userId: "writer", displayName: "別人", bio: "" }, identity), (error) => error instanceof StoreError && error.code === "USER_ID_TAKEN");

    const article = await store.createArticle("google-writer", writer, { title: "設計についてのメモ", body: "本文の秘密語", titleNormalized: "設計についてのメモ", searchTokens: ["設計"] });
    await store.addReply("google-reader", reader, "writer", article.articleId, { body: "返信" });
    const loaded = await store.getArticle("writer", article.articleId);
    assert.equal(loaded.replyCount, 1);
    assert.equal(loaded.replies[0].number, 2);
    assert.equal(loaded.ownerSubject, undefined);
    assert.equal(loaded.replies[0].authorSubject, undefined);
    assert.equal((await store.searchArticles("設計", "設計")).length, 1);
    assert.equal((await store.searchArticles("秘密語", "秘密")).length, 0);
    await assert.rejects(() => store.updateArticle("google-reader", "writer", article.articleId, { title: "改ざん" }), (error) => error.status === 403);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
