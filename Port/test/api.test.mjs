import test from "node:test";
import assert from "node:assert/strict";
import { api } from "../client/api.js";

test("api adds the URLPort request header to unauthenticated mutations", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (path, options) => {
    captured = { path, options };
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  try {
    await api("/api/session", { method: "POST", body: JSON.stringify({ credential: "token" }) });
    assert.equal(captured.path, "/api/session");
    assert.equal(captured.options.headers["X-URLPort-Request"], "1");
    assert.equal(captured.options.headers["Content-Type"], "application/json");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("api does not add the URLPort request header to reads", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (_path, options) => {
    captured = options;
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  try {
    await api("/api/config");
    assert.equal(captured.headers["X-URLPort-Request"], undefined);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
