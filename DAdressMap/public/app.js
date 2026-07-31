const HISTORY_KEY = "daddressmap.history.v2";
const DEFAULT_CENTER = { lat: 36.2048, lng: 138.2529 };
const CODE_PATTERN = /^(?:\d{3,7}|[A-Z0-9]{7})$/u;
const CODE_SAMPLES = [
  { label: "東京", value: "100-0005" },
  { label: "大阪", value: "530-0001" },
  { label: "新潟", value: "954-0055" },
];
const ADDRESS_SAMPLES = [
  { label: "丸の内", value: "東京都千代田区丸の内" },
  { label: "梅田", value: "大阪府大阪市北区梅田" },
  { label: "嶺崎", value: "新潟県見附市嶺崎" },
];

const elements = {
  form: document.querySelector("#search-form"),
  input: document.querySelector("#address-code"),
  searchButton: document.querySelector("#search-button"),
  searchBox: document.querySelector("#search-box"),
  searchLabel: document.querySelector("#search-label"),
  searchPrefix: document.querySelector("#search-prefix"),
  searchHint: document.querySelector("#search-hint"),
  sampleList: document.querySelector("#sample-list"),
  modeButtons: [...document.querySelectorAll("[data-search-mode]")],
  apiStatus: document.querySelector("#api-status"),
  notice: document.querySelector("#notice"),
  loading: document.querySelector("#loading-overlay"),
  map: document.querySelector("#map"),
  mapPlaceholder: document.querySelector("#map-placeholder"),
  mapTitle: document.querySelector("#map-title"),
  openMapButton: document.querySelector("#open-map-button"),
  resultEmpty: document.querySelector("#result-empty"),
  resultContent: document.querySelector("#result-content"),
  resultType: document.querySelector("#result-type"),
  resultCode: document.querySelector("#result-code"),
  sourceBadge: document.querySelector("#source-badge"),
  resultPostal: document.querySelector("#result-postal"),
  resultAddress: document.querySelector("#result-address"),
  resultBuilding: document.querySelector("#result-building"),
  resultPrefecture: document.querySelector("#result-prefecture"),
  resultCity: document.querySelector("#result-city"),
  resultTown: document.querySelector("#result-town"),
  kanaRow: document.querySelector("#kana-row"),
  resultKana: document.querySelector("#result-kana"),
  romanRow: document.querySelector("#roman-row"),
  resultRoman: document.querySelector("#result-roman"),
  businessPanel: document.querySelector("#business-panel"),
  resultBusiness: document.querySelector("#result-business"),
  resultBusinessKana: document.querySelector("#result-business-kana"),
  corporateRow: document.querySelector("#corporate-row"),
  resultCorporate: document.querySelector("#result-corporate"),
  telephoneRow: document.querySelector("#telephone-row"),
  resultTelephone: document.querySelector("#result-telephone"),
  websiteRow: document.querySelector("#website-row"),
  resultWebsite: document.querySelector("#result-website"),
  usageRow: document.querySelector("#usage-row"),
  resultUsage: document.querySelector("#result-usage"),
  entranceSection: document.querySelector("#entrance-section"),
  entranceList: document.querySelector("#entrance-list"),
  candidateSection: document.querySelector("#candidate-section"),
  candidateTitle: document.querySelector("#candidate-title"),
  candidateSummary: document.querySelector("#candidate-summary"),
  candidateList: document.querySelector("#candidate-list"),
  copyButton: document.querySelector("#copy-button"),
  shareButton: document.querySelector("#share-button"),
  historySection: document.querySelector("#history-section"),
  historyList: document.querySelector("#history-list"),
  clearHistory: document.querySelector("#clear-history"),
};

let config = { googleMapsKey: "", apiMode: "demo" };
let searchMode = "code";
let currentSearch = null;
let currentPayload = null;
let selectedResult = null;
let selectedIndex = 0;
let map = null;
let geocoder = null;
let markers = [];

initialize();

async function initialize() {
  bindEvents();
  setSearchMode("code", { clear: false });
  renderHistory();

  try {
    const response = await fetch("/api/config", { headers: { Accept: "application/json" } });
    if (!response.ok) throw new Error("設定の取得に失敗しました");
    config = await response.json();
    updateApiStatus();
    await initializeMap();
  } catch {
    setNotice("地図の初期化に失敗しました。住所検索とGoogle マップへの移動は利用できます。");
  }

  const code = new URL(window.location.href).searchParams.get("code");
  if (code) {
    elements.input.value = displayCode(code);
    await performSearch(code, { updateUrl: false });
  }
}

function bindEvents() {
  elements.form.addEventListener("submit", (event) => {
    event.preventDefault();
    performSearch(elements.input.value);
  });

  elements.input.addEventListener("input", () => {
    if (searchMode === "code") elements.input.value = elements.input.value.toUpperCase();
    hideNotice();
  });

  elements.modeButtons.forEach((button) => {
    button.addEventListener("click", () => setSearchMode(button.dataset.searchMode));
  });

  elements.copyButton.addEventListener("click", copyAddress);
  elements.shareButton.addEventListener("click", shareResult);
  elements.openMapButton.addEventListener("click", openInGoogleMaps);
  elements.clearHistory.addEventListener("click", () => {
    localStorage.removeItem(HISTORY_KEY);
    renderHistory();
  });
}

function setSearchMode(mode, { clear = true } = {}) {
  searchMode = mode === "address" ? "address" : "code";
  const isAddressMode = searchMode === "address";

  elements.modeButtons.forEach((button) => {
    const isSelected = button.dataset.searchMode === searchMode;
    button.setAttribute("aria-selected", String(isSelected));
    button.classList.toggle("is-active", isSelected);
  });

  elements.searchBox.classList.toggle("is-address-mode", isAddressMode);
  elements.input.classList.toggle("is-address-query", isAddressMode);
  elements.searchPrefix.textContent = isAddressMode ? "〒" : "@";
  elements.searchLabel.textContent = isAddressMode ? "住所・地名" : "デジタルアドレス・郵便番号";
  elements.searchHint.textContent = isAddressMode
    ? "都道府県・市区町村・町域の一部から郵便番号候補を検索します"
    : "郵便番号は3桁から、デジタルアドレスは7桁で検索できます";
  elements.input.placeholder = isAddressMode ? "例：新潟県見附市嶺崎" : "例：100-0005 / A7E-2FK2";
  elements.input.autocapitalize = isAddressMode ? "off" : "characters";
  elements.input.maxLength = isAddressMode ? 120 : 10;
  if (clear) elements.input.value = "";
  renderSamples();
  updateSearchButtonLabel();
  hideNotice();
}

function renderSamples() {
  const samples = searchMode === "address" ? ADDRESS_SAMPLES : CODE_SAMPLES;
  const label = document.createElement("span");
  label.textContent = "Sample";
  elements.sampleList.replaceChildren(label);

  samples.forEach((sample) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = sample.label;
    button.addEventListener("click", () => {
      elements.input.value = searchMode === "code" ? displayCode(sample.value) : sample.value;
      performSearch(sample.value);
    });
    elements.sampleList.append(button);
  });
}

async function performSearch(rawValue, { updateUrl = true } = {}) {
  const isCodeSearch = searchMode === "code";
  const value = isCodeSearch ? normalizeCode(rawValue) : normalizeAddressInput(rawValue);

  if (isCodeSearch && !CODE_PATTERN.test(value)) {
    setNotice("3〜7桁の郵便番号、または7桁のデジタルアドレスを入力してください。");
    elements.input.focus();
    return;
  }

  if (!isCodeSearch && (value.length < 2 || value.length > 120)) {
    setNotice("住所は2文字以上120文字以内で入力してください。");
    elements.input.focus();
    return;
  }

  setLoading(true);
  hideNotice();

  try {
    const response = await fetch(isCodeSearch ? "/api/lookup" : "/api/address-search", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(isCodeSearch ? { code: value } : { address: value }),
    });
    const payload = await response.json();

    if (!response.ok) throw new Error(payload.message || "住所を検索できませんでした。");
    if (!Array.isArray(payload.addresses) || payload.addresses.length === 0) {
      throw new Error("該当する住所が見つかりませんでした。");
    }

    currentSearch = { mode: searchMode, value };
    currentPayload = payload;
    elements.input.value = isCodeSearch ? displayCode(value) : value;
    renderCandidates(payload);
    await selectAddress(0);
    saveHistory(currentSearch, selectedResult);
    renderHistory();

    if (updateUrl) {
      const url = new URL(window.location.href);
      if (isCodeSearch) url.searchParams.set("code", value);
      else url.searchParams.delete("code");
      window.history.replaceState({}, "", url);
    }
  } catch (error) {
    setNotice(error.message || "住所を検索できませんでした。");
  } finally {
    setLoading(false);
  }
}

async function selectAddress(index) {
  const address = currentPayload?.addresses?.[index];
  if (!address) return;

  selectedIndex = index;
  selectedResult = address;
  renderResult(currentPayload, address);
  updateCandidateSelection();
  await showOnMap(address);
}

function renderResult(payload, address) {
  const typeLabels = {
    "digital-address": "Digital Address",
    "postal-code": "Postal Code",
    "postal-prefix": "Postal Code Prefix",
    address: "Address → Postal Code",
  };
  const isAddressSearch = currentSearch?.mode === "address";

  elements.resultEmpty.hidden = true;
  elements.resultContent.hidden = false;
  elements.resultType.textContent = typeLabels[payload.type] || "Address";
  elements.resultCode.textContent = isAddressSearch
    ? address.postalCode
      ? `〒${address.postalCode}`
      : "住所検索"
    : displayCode(payload.code);
  elements.sourceBadge.textContent = payload.source === "demo" ? "公式サンプル" : "日本郵便API";
  elements.sourceBadge.classList.toggle("is-demo", payload.source === "demo");
  elements.resultPostal.textContent = address.postalCode ? `〒${address.postalCode}` : "郵便番号なし";
  elements.resultAddress.textContent = address.fullAddress;
  elements.resultBuilding.textContent = address.building;
  elements.resultBuilding.hidden = !address.building;
  elements.resultPrefecture.textContent = address.prefecture || "—";
  elements.resultCity.textContent = address.city || "—";
  elements.resultTown.textContent = `${address.town || ""}${address.block || ""}` || "—";
  elements.resultKana.textContent = address.kana || "";
  elements.kanaRow.hidden = !address.kana;
  elements.resultRoman.textContent = address.roman || "";
  elements.romanRow.hidden = !address.roman;
  elements.mapTitle.textContent = address.businessName || address.fullAddress;
  elements.openMapButton.disabled = false;
  renderBusiness(address);
}

function renderBusiness(address) {
  const businessLabels = [address.businessNameKana, address.businessNameRoman].filter(Boolean);
  const hasBusinessInfo = Boolean(
    address.businessName ||
      address.corporateNumber ||
      address.telephone ||
      address.website ||
      address.usage ||
      address.locations?.length,
  );

  elements.businessPanel.hidden = !hasBusinessInfo;
  if (!hasBusinessInfo) return;

  elements.resultBusiness.textContent = address.businessName || "登録拠点";
  elements.resultBusinessKana.textContent = businessLabels.join(" / ");
  elements.resultBusinessKana.hidden = businessLabels.length === 0;
  setTextRow(elements.corporateRow, elements.resultCorporate, address.corporateNumber);
  setTextRow(elements.usageRow, elements.resultUsage, address.usage);

  elements.telephoneRow.hidden = !address.telephone;
  elements.resultTelephone.textContent = address.telephone || "";
  elements.resultTelephone.href = address.telephone ? `tel:${address.telephone.replace(/[^\d+]/gu, "")}` : "";

  const website = safeWebsiteUrl(address.website);
  elements.websiteRow.hidden = !website;
  elements.resultWebsite.href = website || "";

  const locations = Array.isArray(address.locations) ? address.locations : [];
  elements.entranceSection.hidden = locations.length === 0;
  elements.entranceList.replaceChildren();
  locations.forEach((location, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.innerHTML = "<span></span><small></small>";
    button.querySelector("span").textContent = location.name || `入口 ${index + 1}`;
    button.querySelector("small").textContent = `${location.latitude.toFixed(6)}, ${location.longitude.toFixed(6)}`;
    button.addEventListener("click", () => focusLocation(location, index));
    elements.entranceList.append(button);
  });
}

function setTextRow(row, target, value) {
  const text = typeof value === "string" || typeof value === "number" ? String(value) : "";
  row.hidden = !text;
  target.textContent = text;
}

function renderCandidates(payload) {
  const addresses = payload.addresses || [];
  const isAddressSearch = searchMode === "address";
  elements.candidateSection.hidden = addresses.length <= 1 && !isAddressSearch;
  elements.candidateTitle.textContent = isAddressSearch ? "郵便番号候補" : "住所候補";

  const total = Number(payload.count) || addresses.length;
  const level = matchLevelLabel(payload.matchLevel);
  elements.candidateSummary.textContent = [
    `${total}件中 ${addresses.length}件を表示`,
    level ? `${level}で一致` : "",
  ]
    .filter(Boolean)
    .join(" · ");
  elements.candidateList.replaceChildren();

  addresses.forEach((address, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "candidate-item";
    button.dataset.index = String(index);
    button.innerHTML =
      "<span class=\"candidate-index\"></span><div><strong></strong><small class=\"candidate-postal\"></small><small class=\"candidate-locale\"></small></div>";
    button.querySelector(".candidate-index").textContent = String(index + 1).padStart(2, "0");
    button.querySelector("strong").textContent = address.businessName || address.fullAddress;
    button.querySelector(".candidate-postal").textContent = [
      address.postalCode ? `〒${address.postalCode}` : "",
      address.businessName ? address.fullAddress : "",
    ]
      .filter(Boolean)
      .join(" · ");
    button.querySelector(".candidate-locale").textContent = address.kana || address.roman || "";
    button.querySelector(".candidate-locale").hidden = !address.kana && !address.roman;
    button.addEventListener("click", async () => {
      await selectAddress(index);
      document.querySelector("#result-card").scrollIntoView({ behavior: "smooth", block: "center" });
    });
    elements.candidateList.append(button);
  });
}

function updateCandidateSelection() {
  elements.candidateList.querySelectorAll(".candidate-item").forEach((button) => {
    const isSelected = Number(button.dataset.index) === selectedIndex;
    button.classList.toggle("is-selected", isSelected);
    button.setAttribute("aria-pressed", String(isSelected));
  });
}

async function initializeMap() {
  if (!config.googleMapsKey) {
    elements.mapPlaceholder.querySelector("strong").textContent = "Google Mapsの設定待ち";
    elements.mapPlaceholder.querySelector("span").textContent = "住所検索後はGoogle マップで開けます";
    return;
  }

  await loadGoogleMaps(config.googleMapsKey);
  map = new google.maps.Map(elements.map, {
    center: DEFAULT_CENTER,
    zoom: 5,
    clickableIcons: false,
    fullscreenControl: false,
    mapTypeControl: false,
    streetViewControl: false,
    styles: [
      { featureType: "poi", elementType: "labels", stylers: [{ visibility: "off" }] },
      { featureType: "transit", elementType: "labels.icon", stylers: [{ visibility: "off" }] },
    ],
  });
  geocoder = new google.maps.Geocoder();
}

async function showOnMap(address) {
  if (!map || !geocoder) return;
  clearMarkers();

  if (Array.isArray(address.locations) && address.locations.length > 0) {
    const bounds = new google.maps.LatLngBounds();
    markers = address.locations.map((location) => {
      const position = { lat: location.latitude, lng: location.longitude };
      bounds.extend(position);
      return new google.maps.Marker({ position, map, title: location.name || address.fullAddress });
    });
    if (markers.length === 1) {
      map.setCenter(markers[0].getPosition());
      map.setZoom(19);
    } else {
      map.fitBounds(bounds, 70);
    }
    elements.mapPlaceholder.classList.add("is-hidden");
    return;
  }

  let position =
    Number.isFinite(address.latitude) && Number.isFinite(address.longitude)
      ? { lat: address.latitude, lng: address.longitude }
      : null;

  if (!position) {
    const response = await geocoder.geocode({ address: address.fullAddress, region: "JP" });
    position = response.results?.[0]?.geometry?.location;
  }

  if (!position) {
    setNotice("住所は取得できましたが、地図上の位置を特定できませんでした。");
    return;
  }

  markers = [
    new google.maps.Marker({
      position,
      map,
      animation: google.maps.Animation.DROP,
      title: address.fullAddress,
    }),
  ];
  map.setCenter(position);
  map.setZoom(address.block || address.building ? 17 : 15);
  elements.mapPlaceholder.classList.add("is-hidden");
}

function focusLocation(location, index) {
  if (!map) return;
  const position = { lat: location.latitude, lng: location.longitude };
  map.panTo(position);
  map.setZoom(20);
  markers[index]?.setAnimation(google.maps.Animation.BOUNCE);
  setTimeout(() => markers[index]?.setAnimation(null), 1_400);
}

function clearMarkers() {
  markers.forEach((marker) => marker.setMap(null));
  markers = [];
}

function loadGoogleMaps(key) {
  if (globalThis.google?.maps) return Promise.resolve();

  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(key)}&v=weekly&language=ja&region=JP`;
    script.async = true;
    script.onload = resolve;
    script.onerror = () => reject(new Error("Google Mapsを読み込めませんでした"));
    document.head.append(script);
  });
}

async function copyAddress() {
  if (!selectedResult) return;

  try {
    await navigator.clipboard.writeText(formatAddressForClipboard(selectedResult));
    setNotice("住所情報をクリップボードへコピーしました。", true);
  } catch {
    setNotice("住所をコピーできませんでした。");
  }
}

async function shareResult() {
  if (!selectedResult || !currentSearch) return;
  const url = new URL(window.location.origin);
  if (currentSearch.mode === "code") url.searchParams.set("code", currentSearch.value);
  const heading = currentSearch.mode === "code" ? displayCode(currentSearch.value) : selectedResult.postalCode;
  const shareData = {
    title: "デジタルアドレスマップ",
    text: `${heading ? `${heading} — ` : ""}${selectedResult.fullAddress}`,
    url: url.toString(),
  };

  try {
    if (navigator.share) {
      await navigator.share(shareData);
    } else if (currentSearch.mode === "code") {
      await navigator.clipboard.writeText(shareData.url);
      setNotice("共有URLをコピーしました。", true);
    } else {
      await navigator.clipboard.writeText(formatAddressForClipboard(selectedResult));
      setNotice("住所情報をコピーしました。", true);
    }
  } catch (error) {
    if (error?.name !== "AbortError") setNotice("共有できませんでした。");
  }
}

function openInGoogleMaps() {
  if (!selectedResult) return;
  const location = selectedResult.locations?.[0];
  const query = location
    ? `${location.latitude},${location.longitude}`
    : Number.isFinite(selectedResult.latitude) && Number.isFinite(selectedResult.longitude)
      ? `${selectedResult.latitude},${selectedResult.longitude}`
      : selectedResult.fullAddress;
  const url = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}`;
  window.open(url, "_blank", "noopener,noreferrer");
}

function saveHistory(search, address) {
  const history = readHistory().filter(
    (item) => !(item.mode === search.mode && item.value === search.value),
  );
  history.unshift({
    mode: search.mode,
    value: search.value,
    address: address.fullAddress,
    postalCode: address.postalCode,
    savedAt: Date.now(),
  });
  localStorage.setItem(HISTORY_KEY, JSON.stringify(history.slice(0, 6)));
}

function readHistory() {
  try {
    const history = JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
    return Array.isArray(history) ? history : [];
  } catch {
    return [];
  }
}

function renderHistory() {
  const history = readHistory();
  elements.historySection.hidden = history.length === 0;
  elements.historyList.replaceChildren();

  history.forEach((item, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "history-item";
    button.innerHTML = "<span></span><div><strong></strong><small></small></div>";
    button.querySelector(":scope > span").textContent = String(index + 1).padStart(2, "0");
    button.querySelector("strong").textContent =
      item.mode === "address" ? item.value : displayCode(item.value);
    button.querySelector("small").textContent = item.address;
    button.addEventListener("click", () => {
      setSearchMode(item.mode, { clear: false });
      elements.input.value = item.mode === "address" ? item.value : displayCode(item.value);
      performSearch(item.value);
      window.scrollTo({ top: elements.form.offsetTop - 80, behavior: "smooth" });
    });
    elements.historyList.append(button);
  });
}

function updateApiStatus() {
  const isProduction = config.apiMode === "production";
  elements.apiStatus.classList.toggle("is-live", isProduction);
  elements.apiStatus.classList.toggle("is-demo", !isProduction);
  elements.apiStatus.querySelector("span:last-child").textContent = isProduction
    ? "API稼働中"
    : "サンプルモード";
}

function setLoading(isLoading) {
  elements.loading.hidden = !isLoading;
  elements.loading.setAttribute("aria-hidden", String(!isLoading));
  elements.searchButton.disabled = isLoading;
  if (isLoading) elements.searchButton.querySelector("span").textContent = "検索中…";
  else updateSearchButtonLabel();
}

function updateSearchButtonLabel() {
  elements.searchButton.querySelector("span").textContent =
    searchMode === "address" ? "郵便番号を探す" : "住所を地図で見る";
}

function setNotice(message, success = false) {
  elements.notice.textContent = message;
  elements.notice.classList.toggle("is-success", success);
  elements.notice.hidden = false;
}

function hideNotice() {
  elements.notice.hidden = true;
  elements.notice.classList.remove("is-success");
}

function normalizeCode(value) {
  return String(value ?? "")
    .normalize("NFKC")
    .trim()
    .replace(/^@/u, "")
    .replace(/[-‐‑‒–—―ー\s]/gu, "")
    .toUpperCase();
}

function normalizeAddressInput(value) {
  return String(value ?? "").normalize("NFKC").trim().replace(/\s+/gu, " ");
}

function displayCode(value) {
  const code = normalizeCode(value);
  return code.length === 7 ? `${code.slice(0, 3)}-${code.slice(3)}` : code;
}

function formatAddressForClipboard(address) {
  return [
    address.businessName,
    address.postalCode ? `〒${address.postalCode}` : "",
    address.fullAddress,
    address.building,
    address.telephone,
    safeWebsiteUrl(address.website),
  ]
    .filter(Boolean)
    .join("\n");
}

function safeWebsiteUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : "";
  } catch {
    return "";
  }
}

function matchLevelLabel(value) {
  return { 1: "都道府県", 2: "市区町村", 3: "町域" }[Number(value)] || "";
}
