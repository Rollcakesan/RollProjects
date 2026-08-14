import test from "node:test";
import assert from "node:assert/strict";
import { normalizeUrlInput } from "../client/catalog.js";

test("normalizeUrlInput adds https when the scheme is omitted", () => {
  assert.equal(normalizeUrlInput(" example.com/path "), "https://example.com/path");
  assert.equal(normalizeUrlInput("//example.com/path"), "https://example.com/path");
});

test("normalizeUrlInput preserves explicit and unsupported schemes for server validation", () => {
  assert.equal(normalizeUrlInput("http://example.com"), "http://example.com");
  assert.equal(normalizeUrlInput("javascript:alert(1)"), "javascript:alert(1)");
});
