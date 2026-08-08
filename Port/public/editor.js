import {
  PAYMENT_TYPES,
  blankProfile,
  escapeHtml,
  platform,
  platformOptions,
  profileSummary,
} from "./catalog.js";
import { hydrateBrandIcons, profileMarkup } from "./profile-view.js";

export class ProfileEditor {
  constructor({ root, api, navigate, showToast, renderError, onCreated, onUpdated, onDeleted }) {
    this.root = root;
    this.api = api;
    this.navigate = navigate;
    this.showToast = showToast;
    this.renderError = renderError;
    this.onCreated = onCreated;
    this.onUpdated = onUpdated;
    this.onDeleted = onDeleted;
    this.mode = "create";
    this.slug = "";
    this.draft = blankProfile();
    this.activeSection = "profile";
    this.requestVersion = 0;
    this.previewTimer = null;
    this.sortCleanup = null;
    this.bindRootEvents();
  }

  deactivate() {
    this.requestVersion += 1;
    clearTimeout(this.previewTimer);
    this.sortCleanup?.();
    this.sortCleanup = null;
  }

  openCreate() {
    this.deactivate();
    this.mode = "create";
    this.slug = "";
    this.draft = blankProfile();
    this.activeSection = "profile";
    this.render();
  }

  async openEdit(slug, ownedProfiles) {
    this.deactivate();
    const requestVersion = this.requestVersion;
    if (!ownedProfiles.some((profile) => profile.slug === slug)) {
      this.renderError("このプロフィールを編集する権限がありません。");
      return;
    }
    this.root.innerHTML = `<div class="loading-state"><span class="spinner"></span><p>プロフィールを読み込んでいます</p></div>`;
    try {
      const payload = await this.api(`/api/profiles/${encodeURIComponent(slug)}`);
      if (requestVersion !== this.requestVersion) return;
      this.mode = "edit";
      this.slug = slug;
      this.draft = structuredClone(payload.profile);
      this.activeSection = "profile";
      this.render();
    } catch (error) {
      if (requestVersion === this.requestVersion) this.renderError(error.message);
    }
  }

  render() {
    const isEdit = this.mode === "edit";
    this.root.innerHTML = `
      <section class="editor-shell" data-active-section="${this.activeSection}">
        <div class="editor-topbar">
          <h1>${isEdit ? "Edit profile" : "New profile"}</h1>
          ${isEdit ? `<div class="editor-top-actions"><button id="delete-profile" class="danger-button" type="button">プロフィールを削除</button><a class="button button-small" href="/u/${encodeURIComponent(this.slug)}" target="_blank">公開ページ ↗</a></div>` : ""}
        </div>
        ${this.sectionTabs()}
        <div class="editor-layout">
          <form id="profile-form" class="editor-form">
            <section class="form-section" data-editor-panel="profile">
              <div class="form-section-heading"><h2>Profile</h2></div>
              ${isEdit ? "" : `<label class="field field-wide"><span>公開URL名 <b>必須</b></span><div class="slug-input"><small>port.rollprojects.com/u/</small><input name="slug" value="${escapeHtml(this.slug)}" required minlength="3" maxlength="32" pattern="[a-zA-Z0-9_-]+" placeholder="your-name"></div></label>`}
              <div id="image-fields" class="image-fields">${this.imageFieldsMarkup()}</div>
              <div class="field-grid">
                <label class="field"><span>表示名 <b>必須</b></span><input name="displayName" maxlength="60" required value="${escapeHtml(this.draft.displayName)}" placeholder="山田 太郎"></label>
                <label class="field"><span>肩書き・ひとこと</span><input name="headline" maxlength="100" value="${escapeHtml(this.draft.headline)}" placeholder="Designer / Developer"></label>
                <label class="field field-wide"><span>自己紹介</span><textarea name="bio" maxlength="600" rows="5" placeholder="活動内容や得意なことを書いてください。">${escapeHtml(this.draft.bio)}</textarea></label>
                <label class="field"><span>場所</span><input name="location" maxlength="80" value="${escapeHtml(this.draft.location)}" placeholder="Niigata, Japan"></label>
                <label class="field"><span>アクセントカラー</span><div class="color-input"><input name="accent" type="color" value="${escapeHtml(this.draft.accent)}"><output>${escapeHtml(this.draft.accent)}</output></div></label>
              </div>
            </section>

            <section class="form-section" data-editor-panel="links">
              <div class="form-section-heading"><h2>Links</h2><span id="links-count">${this.draft.links.length}</span></div>
              <div id="links-editor" class="item-editor-list">${this.draft.links.map((link, index) => this.linkEditor(link, index, index === 0)).join("")}</div>
              <button id="add-link" class="add-button" type="button"><span>＋</span>リンクを追加</button>
            </section>

            <section class="form-section" data-editor-panel="payments">
              <div class="form-section-heading"><h2>Payment</h2><span id="payments-count">${this.draft.payments.length}</span></div>
              <div class="security-note"><strong>入力しないもの</strong><span>暗証番号、パスワード、秘密鍵、カード番号、本人確認情報</span></div>
              <div id="payments-editor" class="item-editor-list">${this.draft.payments.map((payment, index) => this.paymentEditor(payment, index, index === 0)).join("")}</div>
              <button id="add-payment" class="add-button" type="button"><span>＋</span>振込・送金先を追加</button>
            </section>

            <div class="save-bar">
              <button class="button button-dark button-large" type="submit">${isEdit ? "保存" : "公開"}</button>
            </div>
          </form>
          <aside class="preview-column"><div class="preview-label"><span>LIVE PREVIEW</span><button id="refresh-preview" type="button">更新</button></div><div id="editor-preview" class="device-preview"></div></aside>
        </div>
      </section>`;
    this.applySectionVisibility();
    this.updatePreview();
  }

  bindRootEvents() {
    this.root.addEventListener("click", (event) => this.handleClick(event));
    this.root.addEventListener("input", (event) => this.handleInput(event));
    this.root.addEventListener("change", (event) => this.handleChange(event));
    this.root.addEventListener("submit", (event) => this.saveProfile(event));
    this.root.addEventListener("invalid", (event) => this.handleInvalid(event), true);
    this.root.addEventListener("pointerdown", (event) => this.handlePointerDown(event));
    this.root.addEventListener("keydown", (event) => this.handleKeyDown(event));
  }

  handleClick(event) {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const handle = target.closest("[data-sortable-handle]");
    if (handle) {
      event.preventDefault();
      return;
    }
    const sectionButton = target.closest("[data-editor-section]");
    if (sectionButton) {
      event.preventDefault();
      this.syncDraftFromForm();
      this.activeSection = sectionButton.dataset.editorSection;
      this.applySectionVisibility();
      return;
    }
    if (target.closest("#add-link")) return this.addLink();
    if (target.closest("#add-payment")) return this.addPayment();
    const removeLink = target.closest("[data-remove-link]");
    if (removeLink) return this.removeItem("links", removeLink.dataset.removeLink);
    const removePayment = target.closest("[data-remove-payment]");
    if (removePayment) return this.removeItem("payments", removePayment.dataset.removePayment);
    const clearImage = target.closest("[data-clear-image]");
    if (clearImage) return this.clearImage(clearImage.dataset.clearImage);
    if (target.closest("#refresh-preview")) {
      this.syncDraftFromForm();
      this.updatePreview();
      return;
    }
    if (target.closest("#delete-profile")) return this.deleteProfile();
    const copyButton = target.closest("[data-copy]");
    if (copyButton) {
      event.stopPropagation();
      navigator.clipboard.writeText(copyButton.dataset.copy).then(() => this.showToast("コピーしました。"));
    }
  }

  handleInput(event) {
    if (!event.target.closest("#profile-form")) return;
    if (event.target.name === "accent") {
      const output = this.root.querySelector(".color-input output");
      if (output) output.textContent = event.target.value;
    }
    clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => {
      this.syncDraftFromForm();
      this.updatePreview();
    }, 100);
  }

  async handleChange(event) {
    const imageInput = event.target.closest("[data-image-input]");
    if (imageInput) return await this.handleImageUpload(imageInput);
    const platformSelect = event.target.closest("select[data-platform]");
    if (!platformSelect) return;
    const item = platformSelect.closest(".editor-item");
    const labelInput = item.querySelector('[data-field="label"]');
    if (!labelInput.value) labelInput.value = platform(platformSelect.value).label;
    this.syncDraftFromForm();
    this.updatePreview();
    this.refreshItemSummary(item);
  }

  handlePointerDown(event) {
    const handle = event.target instanceof Element ? event.target.closest("[data-sortable-handle]") : null;
    if (handle) this.startPointerSort(event, handle);
  }

  handleInvalid(event) {
    const panel = event.target.closest("[data-editor-panel]");
    if (!panel || panel.dataset.editorPanel === this.activeSection) return;
    this.activeSection = panel.dataset.editorPanel;
    this.applySectionVisibility();
  }

  handleKeyDown(event) {
    const handle = event.target instanceof Element ? event.target.closest("[data-sortable-handle]") : null;
    if (!handle) return;
    if (["Enter", " "].includes(event.key)) event.preventDefault();
    this.sortWithKeyboard(event, handle);
  }

  sectionTabs() {
    const tabs = [
      ["profile", "Profile", ""],
      ["links", "Links", this.draft.links.length],
      ["payments", "Payment", this.draft.payments.length],
      ["preview", "Preview", ""],
    ];
    return `<nav class="editor-tabs" aria-label="編集セクション">${tabs.map(([id, label, count]) => `<button type="button" data-editor-section="${id}" aria-selected="${id === this.activeSection}">${label}${count !== "" ? `<span>${count}</span>` : ""}</button>`).join("")}</nav>`;
  }

  applySectionVisibility() {
    const shell = this.root.querySelector(".editor-shell");
    if (!shell) return;
    shell.dataset.activeSection = this.activeSection;
    this.root.querySelectorAll("[data-editor-panel]").forEach((panel) => {
      panel.hidden = panel.dataset.editorPanel !== this.activeSection;
    });
    this.root.querySelectorAll("[data-editor-section]").forEach((button) => {
      button.setAttribute("aria-selected", String(button.dataset.editorSection === this.activeSection));
    });
  }

  addLink() {
    this.syncDraftFromForm();
    if (this.draft.links.length >= 48) return this.showToast("リンクは48件までです。", true);
    const link = { id: crypto.randomUUID(), platform: "website", label: "", description: "", url: "", thumbnailUrl: "" };
    this.draft.links.push(link);
    this.renderLinkList(link.id);
    this.updateCounts();
    this.updatePreview();
  }

  addPayment() {
    this.syncDraftFromForm();
    if (this.draft.payments.length >= 12) return this.showToast("振込・送金先は12件までです。", true);
    const payment = { id: crypto.randomUUID(), type: "bank", label: "", destination: "", note: "", url: "" };
    this.draft.payments.push(payment);
    this.renderPaymentList(payment.id);
    this.updateCounts();
    this.updatePreview();
  }

  removeItem(collection, id) {
    this.syncDraftFromForm();
    this.draft[collection] = this.draft[collection].filter((item) => item.id !== id);
    if (collection === "links") this.renderLinkList();
    else this.renderPaymentList();
    this.updateCounts();
    this.updatePreview();
  }

  renderLinkList(openId = "") {
    const list = this.root.querySelector("#links-editor");
    if (!list) return;
    const openIds = new Set([...list.querySelectorAll("details[open]")].map((item) => item.dataset.linkId));
    if (openId) openIds.add(openId);
    list.innerHTML = this.draft.links.map((link, index) => this.linkEditor(link, index, openIds.has(link.id))).join("");
  }

  renderPaymentList(openId = "") {
    const list = this.root.querySelector("#payments-editor");
    if (!list) return;
    const openIds = new Set([...list.querySelectorAll("details[open]")].map((item) => item.dataset.paymentId));
    if (openId) openIds.add(openId);
    list.innerHTML = this.draft.payments.map((payment, index) => this.paymentEditor(payment, index, openIds.has(payment.id))).join("");
  }

  updateCounts() {
    const linksCount = this.root.querySelector("#links-count");
    const paymentsCount = this.root.querySelector("#payments-count");
    if (linksCount) linksCount.textContent = this.draft.links.length;
    if (paymentsCount) paymentsCount.textContent = this.draft.payments.length;
    this.root.querySelector('[data-editor-section="links"] span')?.replaceChildren(String(this.draft.links.length));
    this.root.querySelector('[data-editor-section="payments"] span')?.replaceChildren(String(this.draft.payments.length));
  }

  syncDraftFromForm() {
    const form = this.root.querySelector("#profile-form");
    if (!form) return;
    const data = new FormData(form);
    if (this.mode === "create") this.slug = String(data.get("slug") || "").trim().toLowerCase();
    this.draft = {
      ...this.draft,
      displayName: String(data.get("displayName") || ""),
      headline: String(data.get("headline") || ""),
      bio: String(data.get("bio") || ""),
      location: String(data.get("location") || ""),
      accent: String(data.get("accent") || "#5b5cf0"),
      links: [...form.querySelectorAll("[data-link-id]")].map((item) => ({
        id: item.dataset.linkId,
        platform: item.querySelector('[data-field="platform"]').value,
        label: item.querySelector('[data-field="label"]').value,
        url: item.querySelector('[data-field="url"]').value,
        description: item.querySelector('[data-field="description"]').value,
        thumbnailUrl: item.dataset.thumbnailUrl || "",
      })),
      payments: [...form.querySelectorAll("[data-payment-id]")].map((item) => ({
        id: item.dataset.paymentId,
        type: item.querySelector('[data-field="type"]').value,
        label: item.querySelector('[data-field="label"]').value,
        destination: item.querySelector('[data-field="destination"]').value,
        note: item.querySelector('[data-field="note"]').value,
        url: item.querySelector('[data-field="url"]').value,
      })),
    };
  }

  updatePreview() {
    const preview = this.root.querySelector("#editor-preview");
    if (!preview) return;
    preview.style.setProperty("--accent", this.draft.accent);
    preview.innerHTML = profileMarkup(this.draft, { variant: "preview" });
    hydrateBrandIcons(preview);
  }

  async saveProfile(event) {
    if (event.target.id !== "profile-form") return;
    event.preventDefault();
    clearTimeout(this.previewTimer);
    this.syncDraftFromForm();
    const submit = event.submitter || event.target.querySelector('button[type="submit"]');
    submit.disabled = true;
    submit.textContent = this.mode === "edit" ? "保存中…" : "作成中…";
    try {
      const path = this.mode === "edit" ? `/api/profiles/${encodeURIComponent(this.slug)}` : "/api/profiles";
      const payload = await this.api(path, {
        method: this.mode === "edit" ? "PUT" : "POST",
        auth: true,
        body: JSON.stringify({ slug: this.slug, profile: this.draft }),
      });
      this.draft = payload.profile;
      if (this.mode === "create") {
        this.onCreated(profileSummary(payload.profile));
        this.showCreatedDialog();
      } else {
        this.onUpdated(profileSummary(payload.profile));
        this.showToast("保存しました。");
        submit.disabled = false;
        submit.textContent = "保存";
      }
    } catch (error) {
      this.showToast(error.message, true);
      submit.disabled = false;
      submit.textContent = this.mode === "edit" ? "保存" : "公開";
    }
  }

  async deleteProfile() {
    if (!window.confirm("このプロフィールとアップロード画像を完全に削除します。元に戻せません。削除しますか？")) return;
    const button = this.root.querySelector("#delete-profile");
    button.disabled = true;
    button.textContent = "削除中…";
    try {
      await this.api(`/api/profiles/${encodeURIComponent(this.slug)}`, { method: "DELETE", auth: true });
      this.onDeleted(this.slug);
      this.navigate("/", { replace: true });
    } catch (error) {
      this.showToast(error.message, true);
      button.disabled = false;
      button.textContent = "プロフィールを削除";
    }
  }

  showCreatedDialog() {
    const publicUrl = `${location.origin}/u/${encodeURIComponent(this.slug)}`;
    this.root.innerHTML = `
      <section class="created-page">
        <span class="success-mark">✓</span><p class="eyebrow">PUBLISHED</p><h1>プロフィールを公開しました</h1>
        <div class="created-card"><span>公開URL</span><strong>${escapeHtml(publicUrl)}</strong><button class="button" data-copy="${escapeHtml(publicUrl)}">コピー</button></div>
        <div class="created-actions"><a class="button button-dark button-large" href="${escapeHtml(publicUrl)}">公開ページを見る</a><a class="text-link" href="/edit/${encodeURIComponent(this.slug)}">編集を続ける</a></div>
      </section>`;
  }

  imageFieldsMarkup() {
    return `${this.imageField("avatar", "プロフィール画像", this.draft.avatarUrl, "square")}${this.imageField("cover", "カバー画像", this.draft.coverUrl, "wide")}`;
  }

  imageField(kind, label, value, shape) {
    return `<div class="image-field"><span>${label}</span><div class="image-preview ${shape}">${value ? `<img src="${escapeHtml(value)}" alt="">` : `<span>${shape === "square" ? "P" : "COVER"}</span>`}</div><div><label class="button button-small"><input type="file" accept="image/jpeg,image/png,image/webp" data-image-input="${kind}">画像を選択</label>${value ? `<button type="button" class="subtle-button" data-clear-image="${kind}">削除</button>` : ""}</div></div>`;
  }

  linkEditor(link, index, open) {
    const summary = link.label || link.url || "未設定";
    return `<details class="editor-item" data-link-id="${escapeHtml(link.id)}" data-thumbnail-url="${escapeHtml(link.thumbnailUrl || "")}" ${open ? "open" : ""}>
      ${this.itemSummary("リンク", index, summary)}
      <div class="editor-item-body"><div class="field-grid compact-grid">
        <label class="field"><span>サービス</span><select data-field="platform" data-platform>${platformOptions(link.platform)}</select></label>
        <label class="field"><span>表示名</span><input data-field="label" maxlength="80" value="${escapeHtml(link.label)}" placeholder="GitHub"></label>
        <label class="field field-wide"><span>URL <b>必須</b></span><input data-field="url" type="url" value="${escapeHtml(link.url)}" placeholder="https://..."></label>
        <label class="field field-wide"><span>説明</span><input data-field="description" maxlength="180" value="${escapeHtml(link.description)}" placeholder="プロジェクトやリンクの説明"></label>
        <div class="field field-wide"><span>サムネイル</span><div class="thumbnail-control">${link.thumbnailUrl ? `<img src="${escapeHtml(link.thumbnailUrl)}" alt="">` : `<span>画像なし</span>`}<label class="button button-small"><input type="file" accept="image/jpeg,image/png,image/webp" data-image-input="link:${escapeHtml(link.id)}">画像を選択</label>${link.thumbnailUrl ? `<button type="button" data-clear-image="link:${escapeHtml(link.id)}">削除</button>` : ""}</div></div>
      </div><div class="editor-item-actions"><button type="button" data-remove-link="${escapeHtml(link.id)}">このリンクを削除</button></div></div>
    </details>`;
  }

  paymentEditor(payment, index, open) {
    const summary = payment.label || payment.destination || "未設定";
    return `<details class="editor-item" data-payment-id="${escapeHtml(payment.id)}" ${open ? "open" : ""}>
      ${this.itemSummary("振込・送金先", index, summary)}
      <div class="editor-item-body"><div class="field-grid compact-grid">
        <label class="field"><span>種類</span><select data-field="type">${PAYMENT_TYPES.map((item) => `<option value="${item.id}" ${item.id === payment.type ? "selected" : ""}>${item.label}</option>`).join("")}</select></label>
        <label class="field"><span>表示名</span><input data-field="label" maxlength="80" value="${escapeHtml(payment.label)}" placeholder="作品代金のお振込先"></label>
        <label class="field field-wide"><span>振込・送金先 <b>必須</b></span><textarea data-field="destination" maxlength="300" rows="3" placeholder="銀行名・支店名・口座番号・名義、または送金ID">${escapeHtml(payment.destination)}</textarea></label>
        <label class="field field-wide"><span>補足</span><input data-field="note" maxlength="240" value="${escapeHtml(payment.note)}" placeholder="振込名義をメッセージでお知らせください"></label>
        <label class="field field-wide"><span>送金ページURL</span><input data-field="url" type="url" value="${escapeHtml(payment.url)}" placeholder="https://..."></label>
      </div><div class="editor-item-actions"><button type="button" data-remove-payment="${escapeHtml(payment.id)}">この振込・送金先を削除</button></div></div>
    </details>`;
  }

  itemSummary(label, index, summary) {
    const numberedLabel = `${label} ${index + 1}`;
    return `<summary class="editor-item-summary"><span class="drag-handle" role="button" tabindex="0" data-sortable-handle aria-label="${numberedLabel}を並べ替え" title="ドラッグして並べ替え"><span aria-hidden="true">⠿</span></span><span class="editor-item-summary-copy"><strong>${numberedLabel}</strong><small>${escapeHtml(summary)}</small></span><span class="editor-item-chevron" aria-hidden="true">⌄</span></summary>`;
  }

  refreshItemSummary(item) {
    const label = item.querySelector('[data-field="label"]')?.value;
    const fallback = item.querySelector('[data-field="url"]')?.value || item.querySelector('[data-field="destination"]')?.value;
    const summary = item.querySelector(".editor-item-summary-copy small");
    if (summary) summary.textContent = label || fallback || "未設定";
  }

  async handleImageUpload(input) {
    const file = input.files?.[0];
    if (!file) return;
    try {
      this.showToast("画像を処理しています…");
      const target = input.dataset.imageInput;
      const dataUrl = await this.compressImage(file, target === "avatar" ? 512 : 1_200, target === "avatar" ? 512 : 700);
      this.syncDraftFromForm();
      if (target === "avatar") this.draft.avatarUrl = dataUrl;
      else if (target === "cover") this.draft.coverUrl = dataUrl;
      else {
        const id = target.slice(5);
        const link = this.draft.links.find((item) => item.id === id);
        if (link) link.thumbnailUrl = dataUrl;
      }
      if (["avatar", "cover"].includes(target)) this.root.querySelector("#image-fields").innerHTML = this.imageFieldsMarkup();
      else this.renderLinkList(target.slice(5));
      this.updatePreview();
    } catch (error) {
      this.showToast(error.message, true);
    }
  }

  clearImage(target) {
    this.syncDraftFromForm();
    if (target === "avatar") this.draft.avatarUrl = "";
    else if (target === "cover") this.draft.coverUrl = "";
    else {
      const link = this.draft.links.find((item) => item.id === target.slice(5));
      if (link) link.thumbnailUrl = "";
    }
    if (["avatar", "cover"].includes(target)) this.root.querySelector("#image-fields").innerHTML = this.imageFieldsMarkup();
    else this.renderLinkList(target.slice(5));
    this.updatePreview();
  }

  async compressImage(file, maxWidth, maxHeight) {
    if (file.size > 12_000_000) throw new Error("12MB以下の画像を選択してください。");
    const bitmap = await createImageBitmap(file);
    let scale = Math.min(1, maxWidth / bitmap.width, maxHeight / bitmap.height);
    const canvas = document.createElement("canvas");
    let blob;
    for (let attempt = 0; attempt < 4; attempt += 1) {
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/webp", Math.max(0.58, 0.84 - attempt * 0.08)));
      if (blob && blob.size <= 500_000) break;
      scale *= 0.78;
    }
    bitmap.close();
    if (!blob) throw new Error("画像を変換できませんでした。");
    if (blob.size > 500_000) throw new Error("画像を十分に圧縮できませんでした。別の画像を選択してください。");
    return await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(new Error("画像を読み取れませんでした。"));
      reader.readAsDataURL(blob);
    });
  }

  startPointerSort(event, handle) {
    if (event.button !== 0) return;
    const item = handle.closest(".editor-item");
    const list = item?.parentElement;
    if (!item || !list || list.children.length < 2) return;
    event.preventDefault();
    const pointerId = event.pointerId;
    const startY = event.clientY;
    let moved = false;
    item.classList.add("is-sorting");
    list.classList.add("is-sorting");

    const move = (moveEvent) => {
      if (moveEvent.pointerId !== pointerId) return;
      if (!moved && Math.abs(moveEvent.clientY - startY) < 4) return;
      moved = true;
      moveEvent.preventDefault();
      const siblings = [...list.children].filter((candidate) => candidate !== item);
      const target = siblings.find((candidate) => {
        const bounds = candidate.getBoundingClientRect();
        return moveEvent.clientY < bounds.top + bounds.height / 2;
      });
      if (target) list.insertBefore(item, target);
      else list.append(item);
      this.autoScrollForSort(moveEvent.clientY);
    };
    const finish = (finishEvent) => {
      if (finishEvent.pointerId !== pointerId) return;
      cleanup();
      if (moved) this.commitSortableOrder(list);
    };
    const cleanup = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", finish);
      window.removeEventListener("pointercancel", finish);
      item.classList.remove("is-sorting");
      list.classList.remove("is-sorting");
      this.sortCleanup = null;
    };
    this.sortCleanup?.();
    this.sortCleanup = cleanup;
    window.addEventListener("pointermove", move, { passive: false });
    window.addEventListener("pointerup", finish);
    window.addEventListener("pointercancel", finish);
  }

  sortWithKeyboard(event, handle) {
    if (!["ArrowUp", "ArrowDown"].includes(event.key)) return;
    const item = handle.closest(".editor-item");
    const list = item?.parentElement;
    if (!item || !list) return;
    const sibling = event.key === "ArrowUp" ? item.previousElementSibling : item.nextElementSibling;
    if (!sibling) return;
    event.preventDefault();
    if (event.key === "ArrowUp") list.insertBefore(item, sibling);
    else list.insertBefore(sibling, item);
    this.commitSortableOrder(list);
    handle.focus();
  }

  commitSortableOrder(list) {
    this.syncDraftFromForm();
    const label = list.id === "payments-editor" ? "振込・送金先" : "リンク";
    list.querySelectorAll(".editor-item").forEach((item, index) => {
      const numberedLabel = `${label} ${index + 1}`;
      item.querySelector(".editor-item-summary-copy strong").textContent = numberedLabel;
      item.querySelector("[data-sortable-handle]").setAttribute("aria-label", `${numberedLabel}を並べ替え`);
    });
    this.updatePreview();
  }

  autoScrollForSort(pointerY) {
    const edge = 80;
    if (pointerY < edge) window.scrollBy({ top: -18, behavior: "auto" });
    else if (pointerY > window.innerHeight - edge) window.scrollBy({ top: 18, behavior: "auto" });
  }
}
