import test from "node:test";
import assert from "node:assert/strict";
import { AuthError } from "../src/google-auth.mjs";
import { SessionManager } from "../src/session-auth.mjs";

const secret = "test-session-secret-that-is-longer-than-32-characters";
const now = Date.UTC(2026, 7, 8, 0, 0, 0);
const user = {
  subject: "google-user-123",
  email: "owner@example.com",
  name: "Owner",
  picture: "https://example.com/avatar.jpg",
};

test("SessionManager creates and verifies an HttpOnly session cookie", () => {
  const sessions = new SessionManager({ secret, now: () => now });
  const cookie = sessions.createCookie(user);
  assert.match(cookie, /^port_session=/u);
  assert.match(cookie, /HttpOnly/u);
  assert.match(cookie, /SameSite=Lax/u);
  assert.match(cookie, /Secure/u);
  assert.deepEqual(sessions.verifyCookieHeader(cookie), user);
});

test("SessionManager shares a valid session through an ordinary Cookie header", () => {
  const sessions = new SessionManager({ secret, now: () => now });
  const sessionPair = sessions.createCookie(user).split(";", 1)[0];
  assert.deepEqual(sessions.verifyCookieHeader(`theme=dark; ${sessionPair}; other=value`), user);
});

test("SessionManager rejects a modified session", () => {
  const sessions = new SessionManager({ secret, now: () => now });
  const sessionPair = sessions.createCookie(user).split(";", 1)[0];
  assert.throws(() => sessions.verifyCookieHeader(`${sessionPair}changed`), AuthError);
});

test("SessionManager rejects an expired session", () => {
  let currentTime = now;
  const sessions = new SessionManager({ secret, now: () => currentTime, maxAgeSeconds: 60 });
  const sessionPair = sessions.createCookie(user).split(";", 1)[0];
  currentTime += 61_000;
  assert.throws(() => sessions.verifyCookieHeader(sessionPair), AuthError);
});

test("SessionManager clears the session cookie", () => {
  const sessions = new SessionManager({ secret, now: () => now });
  assert.match(sessions.clearCookie(), /port_session=;.*Max-Age=0.*Secure/u);
});
