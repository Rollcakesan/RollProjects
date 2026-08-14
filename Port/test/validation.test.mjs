import test from "node:test";
import assert from "node:assert/strict";
import { normalizeProfile, normalizeSlug, profileSummary, publicProfile, ValidationError } from "../src/validation.mjs";

test("normalizeSlug accepts a public profile slug", () => {
  assert.equal(normalizeSlug(" RYOMA-01 "), "ryoma-01");
});

test("normalizeSlug rejects reserved routes", () => {
  assert.throws(() => normalizeSlug("create"), ValidationError);
});

test("normalizeProfile strips credentials from URLs and caps fields", () => {
  const profile = normalizeProfile({
    displayName: " Ryoma ",
    accent: "#ABCDEF",
    links: [{ id: "github", platform: "github", label: "GitHub", url: "https://user:pass@example.com/path" }],
    payments: [{ type: "bank", label: "Bank", destination: "Sample account" }],
  });
  assert.equal(profile.displayName, "Ryoma");
  assert.equal(profile.accent, "#abcdef");
  assert.equal(profile.links[0].url, "https://example.com/path");
});

test("normalizeProfile adds https to links and payment URLs without a scheme", () => {
  const profile = normalizeProfile({
    displayName: "Test",
    links: [{ url: "example.com/path" }],
    payments: [{ destination: "Account", url: "pay.example.com/send" }],
  });
  assert.equal(profile.links[0].url, "https://example.com/path");
  assert.equal(profile.payments[0].url, "https://pay.example.com/send");
});

test("normalizeProfile rejects unsafe URL schemes", () => {
  assert.throws(() => normalizeProfile({ displayName: "Test", links: [{ url: "javascript:alert(1)" }] }), ValidationError);
});

test("publicProfile removes the edit token hash", () => {
  assert.deepEqual(
    publicProfile({
      slug: "test",
      editTokenHash: "secret",
      ownerSubject: "123",
      ownerEmail: "owner@example.com",
      ownerName: "Owner",
      ownerPicture: "https://example.com/avatar.jpg",
    }),
    { slug: "test" },
  );
});

test("profileSummary keeps only dashboard fields", () => {
  assert.deepEqual(profileSummary({
    slug: "test",
    displayName: "Test",
    headline: "Designer",
    avatarUrl: "/media/test/avatar.webp",
    bio: "Long biography",
    links: [{ url: "https://example.com" }],
    ownerSubject: "secret-owner",
  }), {
    slug: "test",
    displayName: "Test",
    headline: "Designer",
    avatarUrl: "/media/test/avatar.webp",
  });
});
