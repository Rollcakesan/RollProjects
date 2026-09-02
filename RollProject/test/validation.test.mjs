import test from "node:test";
import assert from "node:assert/strict";
import { makeSearchTokens, normalizeArticle, normalizeProfile, normalizeUserId, searchTokenFor, ValidationError } from "../src/validation.mjs";

test("user ids become stable URL-safe lowercase values", () => {
  assert.equal(normalizeUserId(" Ryoma_01 "), "ryoma_01");
  assert.throws(() => normalizeUserId("search"), ValidationError);
  assert.throws(() => normalizeUserId("日本語"), ValidationError);
});

test("articles preserve markdown while limiting required fields", () => {
  assert.deepEqual(normalizeArticle({ title: "  猫の記録  ", body: "# 一日目\n\n本文" }), {
    title: "猫の記録",
    body: "# 一日目\n\n本文",
    titleNormalized: "猫の記録",
    searchTokens: makeSearchTokens("猫の記録"),
  });
  assert.throws(() => normalizeArticle({ title: "", body: "本文" }), ValidationError);
});

test("title search uses normalized title tokens only", () => {
  assert.deepEqual(searchTokenFor(" 設計メモ "), { normalized: "設計メモ", token: "設計" });
  assert.ok(makeSearchTokens("小さな設計メモ").includes("設計"));
});

test("profiles reject invalid ids and cap biography", () => {
  assert.equal(normalizeProfile({ userId: "writer-01", displayName: " Writer ", bio: " text " }).bio, "text");
  assert.throws(() => normalizeProfile({ userId: "ab", displayName: "Writer" }), ValidationError);
});
