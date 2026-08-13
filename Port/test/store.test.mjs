import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ProfileStore, StoreError } from "../src/store.mjs";

test("local profile store creates, reads, updates and deletes profile data", async () => {
  const dataDirectory = await mkdtemp(join(tmpdir(), "port-store-"));
  const store = new ProfileStore({ bucket: "", dataDirectory });
  try {
    await store.createProfile("tester", { displayName: "Test", ownerSubject: "google-user-123" });
    await store.createProfile("another", { displayName: "Another", ownerSubject: "google-user-456" });
    assert.equal((await store.getProfile("tester")).displayName, "Test");
    assert.equal((await store.getProfilesForOwner("google-user-123")).length, 1);
    assert.deepEqual((await store.getAllProfiles()).map((profile) => profile.displayName).sort(), ["Another", "Test"]);

    await store.addBookmark("google-user-123", "tester");
    await store.addBookmark("google-user-123", "another");
    await store.addBookmark("google-user-123", "tester");
    assert.deepEqual(await store.getBookmarks("google-user-123"), ["another", "tester"]);
    await store.removeBookmark("google-user-123", "another");
    assert.deepEqual(await store.getBookmarks("google-user-123"), ["tester"]);
    await store.clearBookmarks("google-user-123");
    assert.deepEqual(await store.getBookmarks("google-user-123"), []);

    await store.updateProfile("tester", { displayName: "Updated", ownerSubject: "google-user-123" });
    assert.equal((await store.getProfile("tester")).displayName, "Updated");

    const mediaPath = await store.putImage("tester", "avatar", Buffer.from("webp"));
    await store.putImage("tester", "unused", Buffer.from("old"));
    assert.equal(mediaPath, "/media/tester/avatar.webp");
    assert.equal((await store.getImage("tester", "avatar.webp")).toString(), "webp");
    await store.deleteAssetsExcept("tester", ["avatar.webp"]);
    assert.equal((await store.getImage("tester", "avatar.webp")).toString(), "webp");
    await assert.rejects(() => store.getImage("tester", "unused.webp"), (error) => error instanceof StoreError && error.status === 404);

    await store.deleteProfile("tester", "google-user-123");
    assert.equal((await store.getProfilesForOwner("google-user-123")).length, 0);
    await assert.rejects(() => store.getProfile("tester"), (error) => error instanceof StoreError && error.status === 404);
    await assert.rejects(() => store.getImage("tester", "avatar.webp"), (error) => error instanceof StoreError && error.status === 404);
    await store.deleteProfile("another", "google-user-456");
  } finally {
    await rm(dataDirectory, { force: true, recursive: true });
  }
});
