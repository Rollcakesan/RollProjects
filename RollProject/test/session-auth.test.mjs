import test from "node:test";
import assert from "node:assert/strict";
import { SessionManager } from "../src/session-auth.mjs";

const secret = "test-secret-that-is-at-least-thirty-two-characters";
const user = { subject: "google-123", email: "user@example.com", name: "User", picture: "" };

test("session cookies are HttpOnly, signed and expire", () => {
  let now = Date.UTC(2026, 7, 17);
  const sessions = new SessionManager({ secret, now: () => now, maxAgeSeconds: 60 });
  const cookie = sessions.createCookie(user);
  assert.match(cookie, /HttpOnly/u);
  assert.match(cookie, /SameSite=Lax/u);
  assert.deepEqual(sessions.verifyCookieHeader(cookie), user);
  const pair = cookie.split(";", 1)[0];
  assert.throws(() => sessions.verifyCookieHeader(`${pair}changed`));
  now += 61_000;
  assert.throws(() => sessions.verifyCookieHeader(cookie));
});
