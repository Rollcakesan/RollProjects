import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { AuthError, GoogleTokenVerifier } from "../src/google-auth.mjs";

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2_048 });
const publicJwk = { ...publicKey.export({ format: "jwk" }), kid: "test-key", alg: "RS256", use: "sig" };
const now = Date.UTC(2026, 7, 8, 0, 0, 0);

test("GoogleTokenVerifier verifies a signed Google ID token", async () => {
  const verifier = verifierFor("port-client.apps.googleusercontent.com");
  const user = await verifier.verifyCredential(
    tokenFor({ aud: "port-client.apps.googleusercontent.com", exp: now / 1_000 + 3_600 }),
  );
  assert.deepEqual(user, {
    subject: "google-user-123",
    email: "owner@example.com",
    name: "Owner",
    picture: "https://example.com/avatar.jpg",
  });
});

test("GoogleTokenVerifier rejects a token for another OAuth client", async () => {
  const verifier = verifierFor("port-client.apps.googleusercontent.com");
  await assert.rejects(
    () => verifier.verifyCredential(tokenFor({ aud: "another-client", exp: now / 1_000 + 3_600 })),
    (error) => error instanceof AuthError && error.status === 401,
  );
});

test("GoogleTokenVerifier rejects an expired token", async () => {
  const verifier = verifierFor("port-client.apps.googleusercontent.com");
  await assert.rejects(
    () => verifier.verifyCredential(tokenFor({ aud: "port-client.apps.googleusercontent.com", exp: now / 1_000 - 1 })),
    AuthError,
  );
});

function verifierFor(clientId) {
  return new GoogleTokenVerifier({
    clientId,
    now: () => now,
    fetchFn: async () => new Response(JSON.stringify({ keys: [publicJwk] }), {
      status: 200,
      headers: { "cache-control": "public, max-age=300", "content-type": "application/json" },
    }),
  });
}

function tokenFor(overrides) {
  const header = encode({ alg: "RS256", kid: "test-key", typ: "JWT" });
  const payload = encode({
    iss: "https://accounts.google.com",
    aud: "port-client.apps.googleusercontent.com",
    sub: "google-user-123",
    email: "owner@example.com",
    email_verified: true,
    name: "Owner",
    picture: "https://example.com/avatar.jpg",
    iat: now / 1_000,
    exp: now / 1_000 + 3_600,
    ...overrides,
  });
  const signature = sign("RSA-SHA256", Buffer.from(`${header}.${payload}`), privateKey).toString("base64url");
  return `${header}.${payload}.${signature}`;
}

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}
