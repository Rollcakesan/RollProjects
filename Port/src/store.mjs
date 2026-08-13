import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_DATA_DIRECTORY = resolve(fileURLToPath(new URL("../.data", import.meta.url)));
const STORED_SLUG_PATTERN = /^[a-z0-9](?:[a-z0-9_-]{1,30}[a-z0-9])?$/u;

export class StoreError extends Error {
  constructor(message, status = 500, code = "STORE_ERROR") {
    super(message);
    this.name = "StoreError";
    this.status = status;
    this.code = code;
  }
}

export class ProfileStore {
  constructor({ bucket = process.env.PROFILE_BUCKET, dataDirectory = process.env.DATA_DIRECTORY } = {}) {
    this.bucket = bucket || "";
    this.dataDirectory = resolve(dataDirectory || DEFAULT_DATA_DIRECTORY);
    this.token = null;
  }

  async getProfile(slug) {
    return await this.readJson(`profiles/${slug}.json`);
  }

  async createProfile(slug, profile) {
    await this.writeJson(`profiles/${slug}.json`, profile, true);
    await this.addOwnerProfile(profile.ownerSubject, slug);
  }

  async updateProfile(slug, profile) {
    return await this.writeJson(`profiles/${slug}.json`, profile, false);
  }

  async deleteProfile(slug, ownerSubject) {
    if (!this.bucket) {
      await rm(this.localPath(`profiles/${slug}.json`), { force: true });
      await rm(this.localPath(`assets/${slug}`), { force: true, recursive: true });
    } else {
      const prefix = `assets/${slug}/`;
      const listResponse = await this.gcsFetch(
        `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o?prefix=${encodeURIComponent(prefix)}`,
      );
      if (!listResponse.ok) throw await gcsError(listResponse);
      const listing = await listResponse.json();
      await Promise.all((listing.items || []).map((item) => this.deleteObject(item.name)));
      await this.deleteObject(`profiles/${slug}.json`);
    }
    await this.removeOwnerProfile(ownerSubject, slug);
  }

  async getProfilesForOwner(ownerSubject) {
    const index = await this.getOwnerIndex(ownerSubject);
    const profiles = await Promise.all(
      index.slugs.map(async (slug) => {
        try {
          return await this.getProfile(slug);
        } catch (error) {
          if (error instanceof StoreError && error.status === 404) return null;
          throw error;
        }
      }),
    );
    return profiles.filter(Boolean);
  }

  async getBookmarks(ownerSubject) {
    try {
      const data = await this.readJson(this.bookmarkObjectName(ownerSubject));
      return Array.isArray(data.slugs)
        ? [...new Set(data.slugs.filter((slug) => typeof slug === "string" && STORED_SLUG_PATTERN.test(slug)))].slice(0, 500)
        : [];
    } catch (error) {
      if (error instanceof StoreError && error.status === 404) return [];
      throw error;
    }
  }

  async addBookmark(ownerSubject, slug) {
    const slugs = await this.getBookmarks(ownerSubject);
    if (!slugs.includes(slug)) slugs.unshift(slug);
    await this.writeJson(this.bookmarkObjectName(ownerSubject), { slugs: slugs.slice(0, 500) }, false);
    return slugs;
  }

  async removeBookmark(ownerSubject, slug) {
    const slugs = (await this.getBookmarks(ownerSubject)).filter((candidate) => candidate !== slug);
    await this.writeJson(this.bookmarkObjectName(ownerSubject), { slugs }, false);
    return slugs;
  }

  async clearBookmarks(ownerSubject) {
    await this.writeJson(this.bookmarkObjectName(ownerSubject), { slugs: [] }, false);
  }

  async getAllProfiles() {
    const slugs = await this.listProfileSlugs();
    const results = await Promise.allSettled(slugs.map(async (slug) => ({ ...await this.getProfile(slug), slug })));
    return results.flatMap((result) => result.status === "fulfilled" ? [result.value] : []);
  }

  async listProfileSlugs() {
    if (!this.bucket) {
      try {
        const entries = await readdir(this.localPath("profiles"), { withFileTypes: true });
        return entries
          .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
          .map((entry) => entry.name.slice(0, -5));
      } catch (error) {
        if (error?.code === "ENOENT") return [];
        throw error;
      }
    }

    const objectNames = [];
    let pageToken = "";
    do {
      const query = new URLSearchParams({ prefix: "profiles/", fields: "items(name),nextPageToken" });
      if (pageToken) query.set("pageToken", pageToken);
      const response = await this.gcsFetch(
        `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o?${query}`,
      );
      if (!response.ok) throw await gcsError(response);
      const listing = await response.json();
      objectNames.push(...(listing.items || []).map((item) => item.name));
      pageToken = listing.nextPageToken || "";
    } while (pageToken);

    return objectNames
      .filter((name) => /^profiles\/[^/]+\.json$/u.test(name))
      .map((name) => name.slice("profiles/".length, -".json".length));
  }

  async addOwnerProfile(ownerSubject, slug) {
    const index = await this.getOwnerIndex(ownerSubject);
    if (!index.slugs.includes(slug)) index.slugs.push(slug);
    await this.writeJson(this.ownerObjectName(ownerSubject), index, false);
  }

  async removeOwnerProfile(ownerSubject, slug) {
    const index = await this.getOwnerIndex(ownerSubject);
    index.slugs = index.slugs.filter((candidate) => candidate !== slug);
    await this.writeJson(this.ownerObjectName(ownerSubject), index, false);
  }

  async getOwnerIndex(ownerSubject) {
    try {
      const index = await this.readJson(this.ownerObjectName(ownerSubject));
      return { slugs: Array.isArray(index.slugs) ? index.slugs.filter((slug) => typeof slug === "string") : [] };
    } catch (error) {
      if (error instanceof StoreError && error.status === 404) return { slugs: [] };
      throw error;
    }
  }

  ownerObjectName(ownerSubject) {
    const subject = String(ownerSubject || "");
    if (!/^[a-zA-Z0-9_-]{3,128}$/u.test(subject)) throw new StoreError("所有者情報が不正です。", 400, "INVALID_OWNER");
    return `owners/${subject}.json`;
  }

  bookmarkObjectName(ownerSubject) {
    const ownerObjectName = this.ownerObjectName(ownerSubject);
    return `bookmarks/${ownerObjectName.slice("owners/".length)}`;
  }

  async putImage(slug, imageId, bytes) {
    const objectName = `assets/${slug}/${imageId}.webp`;
    await this.writeObject(objectName, bytes, "image/webp", false);
    return `/media/${encodeURIComponent(slug)}/${encodeURIComponent(imageId)}.webp`;
  }

  async getImage(slug, filename) {
    if (!/^[a-zA-Z0-9_-]+\.webp$/u.test(filename)) throw new StoreError("画像が見つかりません。", 404, "NOT_FOUND");
    return await this.readObject(`assets/${slug}/${filename}`);
  }

  async deleteAssetsExcept(slug, filenames) {
    const keep = new Set(filenames);
    if (!this.bucket) {
      try {
        const directory = this.localPath(`assets/${slug}`);
        const entries = await readdir(directory, { withFileTypes: true });
        await Promise.all(entries
          .filter((entry) => entry.isFile() && !keep.has(entry.name))
          .map((entry) => rm(resolve(directory, entry.name), { force: true })));
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      return;
    }

    const prefix = `assets/${slug}/`;
    const response = await this.gcsFetch(
      `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o?prefix=${encodeURIComponent(prefix)}&fields=items(name)`,
    );
    if (!response.ok) throw await gcsError(response);
    const listing = await response.json();
    await Promise.all((listing.items || [])
      .filter((item) => !keep.has(item.name.slice(prefix.length)))
      .map((item) => this.deleteObject(item.name)));
  }

  async readJson(objectName) {
    const bytes = await this.readObject(objectName);
    try {
      return JSON.parse(bytes.toString("utf8"));
    } catch {
      throw new StoreError("保存データを読み取れません。", 500, "INVALID_STORED_DATA");
    }
  }

  async writeJson(objectName, value, createOnly) {
    const body = Buffer.from(JSON.stringify(value), "utf8");
    await this.writeObject(objectName, body, "application/json; charset=utf-8", createOnly);
  }

  async readObject(objectName) {
    if (!this.bucket) return await this.readLocal(objectName);
    const response = await this.gcsFetch(
      `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o/${encodeURIComponent(objectName)}?alt=media`,
    );
    if (response.status === 404) throw new StoreError("プロフィールが見つかりません。", 404, "NOT_FOUND");
    if (!response.ok) throw await gcsError(response);
    return Buffer.from(await response.arrayBuffer());
  }

  async writeObject(objectName, body, contentType, createOnly) {
    if (!this.bucket) return await this.writeLocal(objectName, body, createOnly);
    const precondition = createOnly ? "&ifGenerationMatch=0" : "";
    const response = await this.gcsFetch(
      `https://storage.googleapis.com/upload/storage/v1/b/${encodeURIComponent(this.bucket)}/o?uploadType=media&name=${encodeURIComponent(objectName)}${precondition}`,
      { method: "POST", headers: { "Content-Type": contentType }, body },
    );
    if (response.status === 412) throw new StoreError("このURL名はすでに使用されています。", 409, "SLUG_UNAVAILABLE");
    if (!response.ok) throw await gcsError(response);
  }

  async deleteObject(objectName) {
    const response = await this.gcsFetch(
      `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o/${encodeURIComponent(objectName)}`,
      { method: "DELETE" },
    );
    if (response.status !== 404 && !response.ok) throw await gcsError(response);
  }

  async readLocal(objectName) {
    try {
      return await readFile(this.localPath(objectName));
    } catch (error) {
      if (error?.code === "ENOENT") throw new StoreError("プロフィールが見つかりません。", 404, "NOT_FOUND");
      throw error;
    }
  }

  async writeLocal(objectName, body, createOnly) {
    const filePath = this.localPath(objectName);
    await mkdir(dirname(filePath), { recursive: true });
    if (createOnly) {
      try {
        await writeFile(filePath, body, { flag: "wx" });
      } catch (error) {
        if (error?.code === "EEXIST") throw new StoreError("このURL名はすでに使用されています。", 409, "SLUG_UNAVAILABLE");
        throw error;
      }
      return;
    }
    const temporaryPath = `${filePath}.${crypto.randomUUID()}.tmp`;
    await writeFile(temporaryPath, body);
    await rename(temporaryPath, filePath);
  }

  localPath(objectName) {
    const filePath = resolve(this.dataDirectory, objectName);
    if (!filePath.startsWith(`${this.dataDirectory}/`)) throw new StoreError("保存先が不正です。", 400, "INVALID_PATH");
    return filePath;
  }

  async gcsFetch(url, options = {}) {
    const token = await this.accessToken();
    let response = await fetch(url, { ...options, headers: { ...options.headers, Authorization: `Bearer ${token}` } });
    if (response.status === 401) {
      this.token = null;
      const refreshedToken = await this.accessToken();
      response = await fetch(url, {
        ...options,
        headers: { ...options.headers, Authorization: `Bearer ${refreshedToken}` },
      });
    }
    return response;
  }

  async accessToken() {
    if (this.token && this.token.expiresAt > Date.now() + 60_000) return this.token.value;
    const response = await fetch(
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
      { headers: { "Metadata-Flavor": "Google" } },
    );
    if (!response.ok) throw new StoreError("ストレージ認証に失敗しました。");
    const payload = await response.json();
    this.token = { value: payload.access_token, expiresAt: Date.now() + Number(payload.expires_in || 300) * 1_000 };
    return this.token.value;
  }
}

async function gcsError(response) {
  const message = await response.text();
  console.error("Cloud Storage error", response.status, message.slice(0, 1_000));
  return new StoreError("プロフィールの保存に失敗しました。");
}
