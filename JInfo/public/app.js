const page = document.body.dataset.page;
const state = {
  weatherFeed: "extra",
  map: null,
  marker: null,
  accuracyLayer: null,
  tileLayer: null,
  weather: null,
  laws: null,
  datasets: null,
  books: null,
};
const tileLayers = {
  std: { url: "https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png", maxZoom: 18 },
  pale: { url: "https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png", maxZoom: 18 },
  seamlessphoto: { url: "https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg", maxZoom: 18 },
};

startClock();
bindSuggestions();

if (page === "weather") {
  bindWeatherControls();
  loadWeather();
}
if (page === "weather-detail") loadWeatherDetail();
if (page === "laws") {
  bindSearchForm("#law-form", searchLaws);
  bindSearchControls(["#law-type-filter", "#law-category-filter", "#law-date-filter", "#law-sort"], renderLaws);
  bindSearchInputs(["#law-result-query"], renderLaws);
  document.querySelector("#law-limit")?.addEventListener("change", () => searchLaws(document.querySelector("#law-query").value));
  searchLaws(document.querySelector("#law-query").value);
}
if (page === "datasets") {
  bindSearchForm("#dataset-form", searchDatasets);
  bindSearchControls(["#dataset-format-filter", "#dataset-organization-filter", "#dataset-date-filter", "#dataset-sort"], renderDatasets);
  bindSearchInputs(["#dataset-result-query"], renderDatasets);
  document.querySelector("#dataset-limit")?.addEventListener("change", () => searchDatasets(document.querySelector("#dataset-query").value));
  searchDatasets(document.querySelector("#dataset-query").value);
}
if (page === "books") {
  bindSearchForm("#book-form", searchBooks);
  bindSearchControls(["#book-category-filter", "#book-publisher-filter", "#book-sort"], renderBooks);
  bindSearchInputs(["#book-result-query", "#book-year-from", "#book-year-to"], renderBooks);
  document.querySelector("#book-limit")?.addEventListener("change", () => searchBooks(document.querySelector("#book-query").value));
  searchBooks(document.querySelector("#book-query").value);
}
if (page === "map") initializeMap();

function startClock() {
  const element = document.querySelector("#current-time");
  if (!element) return;
  const update = () => {
    element.textContent = `JST ${new Intl.DateTimeFormat("ja-JP", { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false, timeZone: "Asia/Tokyo" }).format(new Date())}`;
  };
  update();
  setInterval(update, 1_000);
}

function bindSuggestions() {
  document.querySelectorAll(".suggestions button").forEach((button) => {
    button.addEventListener("click", () => {
      const input = document.querySelector(`#${button.dataset.target}`);
      if (!input) return;
      input.value = button.textContent.trim();
      input.focus();
    });
  });
}

function bindSearchForm(selector, handler) {
  document.querySelector(selector)?.addEventListener("submit", (event) => {
    event.preventDefault();
    handler(new FormData(event.currentTarget).get("q"));
  });
}

function bindSearchControls(selectors, handler) {
  selectors.forEach((selector) => document.querySelector(selector)?.addEventListener("change", handler));
}

function bindSearchInputs(selectors, handler) {
  selectors.forEach((selector) => document.querySelector(selector)?.addEventListener("input", handler));
}

function bindWeatherControls() {
  document.querySelectorAll("[data-feed]").forEach((button) => {
    button.addEventListener("click", () => {
      state.weatherFeed = button.dataset.feed;
      document.querySelectorAll("[data-feed]").forEach((item) => item.classList.toggle("active", item === button));
      loadWeather();
    });
  });
  document.querySelector("#weather-refresh")?.addEventListener("click", loadWeather);
  bindSearchControls(["#weather-category-filter", "#weather-sort", "#weather-limit"], renderWeather);
  bindSearchInputs(["#weather-filter-query"], renderWeather);
}

async function loadWeather() {
  const status = document.querySelector("#weather-status");
  const results = document.querySelector("#weather-results");
  setLoading(status, "気象庁から最新情報を取得しています。");
  results.replaceChildren();
  try {
    state.weather = await apiFetch(`/api/weather?feed=${encodeURIComponent(state.weatherFeed)}`);
    renderWeather();
  } catch (error) {
    showError(status, results, error);
  }
}

function renderWeather() {
  if (!state.weather) return;
  const status = document.querySelector("#weather-status");
  const results = document.querySelector("#weather-results");
  const query = document.querySelector("#weather-filter-query").value;
  const category = document.querySelector("#weather-category-filter").value;
  const sort = document.querySelector("#weather-sort").value;
  const limit = Number(document.querySelector("#weather-limit").value);
  const matching = state.weather.results.filter((item) =>
    (category === "all" || item.category === category) &&
    matchesText([item.title, item.summary, item.publisher, item.category], query),
  ).sort((left, right) => (sort === "oldest" ? 1 : -1) * (dateValue(left.updatedAt) - dateValue(right.updatedAt)));
  const visible = matching.slice(0, limit);
  status.classList.remove("loading");
  status.textContent = `${state.weather.label}・${state.weather.results.length}件取得 ／ 条件一致 ${matching.length}件 ／ ${visible.length}件表示 ／ 更新 ${formatDateTime(state.weather.updatedAt)}`;
  if (!visible.length) return renderEmpty(results, "指定した条件に一致する防災情報はありません。");
  results.innerHTML = visible.map((item) => {
      const detailUrl = `/weather-detail?url=${encodeURIComponent(item.url)}`;
      return `
        <a class="weather-item" href="${detailUrl}">
          <div class="weather-time">${formatShortTime(item.updatedAt)}<span class="weather-category category-${escapeHtml(item.category)}">${escapeHtml(item.category)}</span></div>
          <div class="weather-content"><h3>${escapeHtml(item.title)}</h3><p>${escapeHtml(item.summary || "詳細情報を確認してください。")}</p><span class="weather-source">${escapeHtml(item.publisher || "気象庁")}　詳細を見る →</span></div>
        </a>`;
    }).join("");
}

async function loadWeatherDetail() {
  const status = document.querySelector("#weather-detail-status");
  const article = document.querySelector("#weather-detail");
  const sourceUrl = new URLSearchParams(location.search).get("url");
  if (!sourceUrl) return showDetailError(status, "表示する防災情報が指定されていません。");
  try {
    const data = await apiFetch(`/api/weather-detail?url=${encodeURIComponent(sourceUrl)}`);
    document.title = `${data.title}｜防災情報｜JInfo`;
    status.hidden = true;
    article.hidden = false;
    article.innerHTML = `
      <header class="weather-detail-header">
        <div class="detail-badges"><span>${escapeHtml(data.category)}</span>${data.infoType ? `<span>${escapeHtml(data.infoType)}</span>` : ""}</div>
        <h1>${escapeHtml(data.title)}</h1>
        <dl class="detail-meta">
          <div><dt>発表</dt><dd>${formatDateTime(data.publishedAt)}</dd></div>
          <div><dt>発表元</dt><dd>${escapeHtml(data.publisher || "気象庁")}</dd></div>
          ${data.validUntil ? `<div><dt>有効時刻</dt><dd>${formatDateTime(data.validUntil)}</dd></div>` : ""}
        </dl>
      </header>
      ${data.headline ? `<section class="detail-headline"><h2>概要</h2><p>${formatMultiline(data.headline)}</p></section>` : ""}
      ${data.informationGroups.map((group) => `
        <section class="detail-section"><h2>${escapeHtml(group.type)}</h2>
          ${group.entries.map((entry) => `<div class="area-group"><strong>${escapeHtml(entry.kind)}</strong><div>${entry.areas.map((area) => `<span>${escapeHtml(area)}</span>`).join("") || "<span>対象地域の記載なし</span>"}</div></div>`).join("")}
        </section>`).join("")}
      ${renderXmlBodySections(data.bodySections || [])}
      ${data.notes.length ? `<section class="detail-section"><h2>補足情報</h2>${data.notes.map((note) => `<p class="detail-note">${formatMultiline(note)}</p>`).join("")}</section>` : ""}
      <div class="detail-source"><span>出典：気象庁防災情報XML</span><a href="${safeUrl(data.sourceUrl)}" target="_blank" rel="noreferrer">原文XML ↗</a></div>`;
    bindXmlBodySections(article, data.bodySections || []);
  } catch (error) {
    showDetailError(status, error.message);
  }
}

function renderXmlBodySections(sections) {
  if (!sections.length) return "";
  return `<section class="detail-section xml-body-section"><h2>XML本文データ</h2>
    <div class="filter-toolbar xml-filter-toolbar">
      <label class="filter-search">本文内検索<input id="xml-filter-query" type="search" placeholder="地域・警報名・数値" autocomplete="off" /></label>
      <label>項目<select id="xml-section-filter"><option value="all">すべて</option>${sections.map((section, index) => `<option value="${index}">${escapeHtml(section.title)}</option>`).join("")}</select></label>
    </div>
    <p class="xml-filter-status" id="xml-filter-status">${sections.reduce((sum, section) => sum + section.entries.length, 0)}件の本文データ</p>
    <div class="xml-sections" id="xml-sections">${renderXmlSectionList(sections, false)}</div></section>`;
}

function renderXmlSectionList(sections, expandMatches) {
  if (!sections.length) return `<div class="empty-state">条件に一致する本文データがありません。</div>`;
  return sections.map((section, sectionIndex) => `
    <details class="xml-section" data-xml-section="${sectionIndex}" ${sectionIndex === 0 || expandMatches ? "open" : ""}>
      <summary><span>${escapeHtml(section.title)}</span><small>${section.entries.length}件</small></summary>
      ${sectionIndex === 0 || expandMatches ? renderXmlEntryList(section.entries) : ""}
    </details>`).join("");
}

function renderXmlEntryList(entries) {
  return `<div class="xml-entry-list">${entries.map((entry) => `
    <article class="xml-entry"><h3>${escapeHtml(entry.heading)}</h3><dl>${entry.facts.map((item) => `<div><dt>${escapeHtml(item.label)}</dt><dd>${formatMultiline(item.value)}</dd></div>`).join("")}</dl></article>`).join("")}</div>`;
}

function bindXmlBodySections(article, sections) {
  const queryInput = article.querySelector("#xml-filter-query");
  const sectionSelect = article.querySelector("#xml-section-filter");
  const container = article.querySelector("#xml-sections");
  const status = article.querySelector("#xml-filter-status");
  const bindSectionToggles = (visibleSections) => {
    container.querySelectorAll("[data-xml-section]").forEach((details) => details.addEventListener("toggle", () => {
      if (!details.open || details.querySelector(".xml-entry-list")) return;
      const section = visibleSections[Number(details.dataset.xmlSection)];
      if (section) details.insertAdjacentHTML("beforeend", renderXmlEntryList(section.entries));
    }));
  };
  const applyFilters = () => {
    const query = queryInput.value;
    const selectedIndex = sectionSelect.value;
    const visibleSections = sections.map((section, index) => ({
      ...section,
      entries: section.entries.filter((entry) => matchesText([
        entry.heading,
        ...entry.facts.flatMap((item) => [item.label, item.value]),
      ], query)),
      sourceIndex: index,
    })).filter((section) =>
      section.entries.length && (selectedIndex === "all" || section.sourceIndex === Number(selectedIndex)),
    );
    const visibleCount = visibleSections.reduce((sum, section) => sum + section.entries.length, 0);
    status.textContent = `${visibleCount}件一致 ／ 全${sections.reduce((sum, section) => sum + section.entries.length, 0)}件`;
    container.innerHTML = renderXmlSectionList(visibleSections, Boolean(query));
    bindSectionToggles(visibleSections);
  };
  bindSectionToggles(sections);
  queryInput?.addEventListener("input", applyFilters);
  sectionSelect?.addEventListener("change", applyFilters);
}

async function searchLaws(query) {
  const status = document.querySelector("#law-status");
  const results = document.querySelector("#law-results");
  setLoading(status, "e-Gov法令APIを検索しています。");
  results.replaceChildren();
  try {
    const limit = document.querySelector("#law-limit").value;
    state.laws = await apiFetch(`/api/laws?q=${encodeURIComponent(query)}&limit=${encodeURIComponent(limit)}`);
    syncSelectOptions("#law-category-filter", state.laws.results.map((law) => law.category));
    renderLaws();
  } catch (error) { showError(status, results, error); }
}

function renderLaws() {
  if (!state.laws) return;
  const status = document.querySelector("#law-status");
  const results = document.querySelector("#law-results");
  const resultQuery = document.querySelector("#law-result-query").value;
  const type = document.querySelector("#law-type-filter").value;
  const category = document.querySelector("#law-category-filter").value;
  const dateRange = document.querySelector("#law-date-filter").value;
  const sort = document.querySelector("#law-sort").value;
  const primaryLawTypes = ["法律", "政令", "府省令", "規則"];
  const laws = sortItems(state.laws.results.filter((law) =>
    (type === "all" || (type === "other" ? !primaryLawTypes.includes(law.type) : law.type === type)) &&
    (category === "all" || law.category === category) &&
    (dateRange === "all" || isWithinYears(law.updatedAt, Number(dateRange))) &&
    matchesText([law.title, law.number, law.type, law.category, ...law.excerpts], resultQuery),
  ), sort, {
    "updated-desc": (law) => dateValue(law.updatedAt),
    "promulgated-desc": (law) => dateValue(law.promulgatedAt),
    title: (law) => law.title,
  });
  status.classList.remove("loading");
  status.textContent = resultSummary(state.laws, laws.length);
  if (!laws.length) return renderEmpty(results, "指定した条件に該当する法令が見つかりませんでした。");
  results.innerHTML = laws.map((law) => `
      <a class="law-item" href="${safeUrl(law.url)}" target="_blank" rel="noreferrer">
        <div class="law-meta"><strong>${escapeHtml(law.type)}</strong>${formatDate(law.promulgatedAt)}</div>
        <div class="law-body"><h3>${escapeHtml(law.title)}</h3><small>${escapeHtml(law.number)}${law.category ? ` ／ ${escapeHtml(law.category)}` : ""}</small>${law.excerpts[0] ? `<p>${escapeHtml(law.excerpts.join(" … "))}</p>` : ""}</div><span class="result-arrow">↗</span>
      </a>`).join("");
}

async function searchDatasets(query) {
  const status = document.querySelector("#dataset-status");
  const results = document.querySelector("#dataset-results");
  setLoading(status, "行政オープンデータを検索しています。");
  results.replaceChildren();
  try {
    const limit = document.querySelector("#dataset-limit").value;
    state.datasets = await apiFetch(`/api/datasets?q=${encodeURIComponent(query)}&limit=${encodeURIComponent(limit)}`);
    syncSelectOptions("#dataset-organization-filter", state.datasets.results.map((dataset) => dataset.organization));
    renderDatasets();
  } catch (error) { showError(status, results, error); }
}

function renderDatasets() {
  if (!state.datasets) return;
  const status = document.querySelector("#dataset-status");
  const results = document.querySelector("#dataset-results");
  const resultQuery = document.querySelector("#dataset-result-query").value;
  const format = document.querySelector("#dataset-format-filter").value;
  const organization = document.querySelector("#dataset-organization-filter").value;
  const dateRange = document.querySelector("#dataset-date-filter").value;
  const sort = document.querySelector("#dataset-sort").value;
  const datasets = sortItems(state.datasets.results.filter((dataset) => {
    const matchesFormat = format === "all" || dataset.formats.some((resourceFormat) => {
      return format === "XLSX" ? resourceFormat.startsWith("XLS") : resourceFormat.includes(format);
    });
    return matchesFormat &&
      (organization === "all" || dataset.organization === organization) &&
      (dateRange === "all" || isWithinYears(dataset.updatedAt, Number(dateRange))) &&
      matchesText([dataset.title, dataset.description, dataset.organization, ...dataset.tags, ...dataset.formats], resultQuery);
  }), sort, {
    "updated-desc": (dataset) => dateValue(dataset.updatedAt),
    "updated-asc": (dataset) => dateValue(dataset.updatedAt),
    title: (dataset) => dataset.title,
  });
  status.classList.remove("loading");
  status.textContent = resultSummary(state.datasets, datasets.length);
  if (!datasets.length) return renderEmpty(results, "指定した条件に該当するデータセットが見つかりませんでした。");
  results.innerHTML = datasets.map((dataset) => `
      <article class="dataset-card"><div class="dataset-source"><span>${escapeHtml(dataset.organization || "行政機関")}</span><time>${formatDate(dataset.updatedAt)}</time></div><h3>${escapeHtml(dataset.title)}</h3><p>${escapeHtml(dataset.description || "説明は提供元でご確認ください。")}</p><div class="tag-row">${dataset.tags.map((tag) => `<span>${escapeHtml(tag)}</span>`).join("")}</div><div class="resource-links">${dataset.resources.map((resource) => `<a href="${safeUrl(resource.url)}" target="_blank" rel="noreferrer" title="${escapeHtml(resource.name)}">${escapeHtml(resource.format)}</a>`).join("")}</div><a class="dataset-detail" href="${safeUrl(dataset.url)}" target="_blank" rel="noreferrer">データセット詳細 ↗</a></article>`).join("");
}

async function searchBooks(query) {
  const status = document.querySelector("#book-status");
  const results = document.querySelector("#book-results");
  setLoading(status, "国立国会図書館を検索しています。");
  results.replaceChildren();
  try {
    const limit = document.querySelector("#book-limit").value;
    state.books = await apiFetch(`/api/books?q=${encodeURIComponent(query)}&limit=${encodeURIComponent(limit)}`);
    syncSelectOptions("#book-publisher-filter", state.books.results.map((book) => book.publisher));
    renderBooks();
  } catch (error) { showError(status, results, error); }
}

function renderBooks() {
  if (!state.books) return;
  const status = document.querySelector("#book-status");
  const results = document.querySelector("#book-results");
  const resultQuery = document.querySelector("#book-result-query").value;
  const category = document.querySelector("#book-category-filter").value;
  const publisher = document.querySelector("#book-publisher-filter").value;
  const yearFrom = Number(document.querySelector("#book-year-from").value) || 0;
  const yearTo = Number(document.querySelector("#book-year-to").value) || Number.POSITIVE_INFINITY;
  const sort = document.querySelector("#book-sort").value;
  const books = sortItems(state.books.results.filter((book) => {
    const year = yearValue(book.year);
    return matchesBookCategory(book, category) &&
      (publisher === "all" || book.publisher === publisher) &&
      ((!yearFrom && !Number.isFinite(yearTo)) || (year && year >= yearFrom && year <= yearTo)) &&
      matchesText([book.title, book.creator, book.publisher, book.year, book.description, book.isbn, ...book.categories], resultQuery);
  }), sort, {
    "year-desc": (book) => yearValue(book.year),
    "year-asc": (book) => yearValue(book.year),
    title: (book) => book.title,
  });
  status.classList.remove("loading");
  status.textContent = resultSummary(state.books, books.length);
  if (!books.length) return renderEmpty(results, "指定した条件に該当する資料が見つかりませんでした。");
  results.innerHTML = books.map((book) => `
    <article class="book-item"><div class="book-main"><h3>${escapeHtml(book.title)}</h3><div class="book-meta"><span>${escapeHtml(book.creator || "著者不明")}</span><span>${escapeHtml(book.publisher || "出版社不明")}</span><span>${escapeHtml(book.year || "刊行年不明")}</span>${book.categories.map((item) => `<span>${escapeHtml(item)}</span>`).join("")}${book.isbn ? `<span>ISBN ${escapeHtml(book.isbn)}</span>` : ""}</div>${book.description ? `<p>${escapeHtml(book.description)}</p>` : ""}</div><a href="${safeUrl(book.url)}" target="_blank" rel="noreferrer">NDLで見る ↗</a></article>`).join("");
}

function initializeMap() {
  const mapElement = document.querySelector("#map");
  if (!window.L || !mapElement) {
    if (mapElement) mapElement.textContent = "地図を読み込めませんでした。";
    return;
  }
  state.map = window.L.map(mapElement, {
    zoomControl: true,
    minZoom: 3,
    maxZoom: 18,
    zoomAnimation: false,
    fadeAnimation: false,
    markerZoomAnimation: false,
    trackResize: true,
    scrollWheelZoom: true,
    wheelDebounceTime: 100,
    wheelPxPerZoomLevel: 160,
    zoomDelta: 1,
    zoomSnap: 1,
  }).setView([36.2048, 138.2529], 5);
  setMapLayer("std");
  window.L.control.scale({ imperial: false }).addTo(state.map);
  state.map.on("click", (event) => setMapPoint(event.latlng.lat, event.latlng.lng));
  document.querySelectorAll("[data-layer]").forEach((button) => button.addEventListener("click", () => {
    setMapLayer(button.dataset.layer);
    document.querySelectorAll("[data-layer]").forEach((item) => item.classList.toggle("active", item === button));
  }));
  document.querySelectorAll("[data-map-place]").forEach((button) => button.addEventListener("click", () => {
    const [lat, lng, zoom] = button.dataset.mapPlace.split(",").map(Number);
    state.map.setView([lat, lng], zoom); setMapPoint(lat, lng, button.textContent.trim());
  }));
  document.querySelector("#map-search-form")?.addEventListener("submit", searchMap);
  document.querySelector("#locate-button")?.addEventListener("click", locateUser);
  updateLocationPermissionState();
  window.addEventListener("pageshow", updateLocationPermissionState);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") updateLocationPermissionState();
  });
  requestAnimationFrame(() => state.map.invalidateSize({ pan: false, animate: false }));
  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => state.map.invalidateSize({ pan: false, animate: false }), 150);
  });
}

function setMapLayer(name) {
  const definition = tileLayers[name];
  if (!definition || !state.map) return;
  if (state.tileLayer) state.tileLayer.remove();
  state.tileLayer = window.L.tileLayer(definition.url, {
    minZoom: 3,
    maxZoom: definition.maxZoom,
    tileSize: 256,
    zoomOffset: 0,
    detectRetina: false,
    updateWhenIdle: true,
    updateWhenZooming: false,
    keepBuffer: 4,
    attribution: '<a href="https://maps.gsi.go.jp/development/" target="_blank" rel="noreferrer">国土地理院</a>',
  }).addTo(state.map);
}

function setMapPoint(lat, lng, label = "") {
  document.querySelector("#map-lat").textContent = lat.toFixed(5);
  document.querySelector("#map-lng").textContent = lng.toFixed(5);
  if (state.marker) state.marker.remove();
  state.marker = window.L.circleMarker([lat, lng], { radius: 8, color: "#fff", weight: 3, fillColor: "#e84d35", fillOpacity: 1 }).addTo(state.map);
  if (label) state.marker.bindPopup(escapeHtml(label)).openPopup();
}

async function searchMap(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const query = new FormData(form).get("q");
  const status = document.querySelector("#map-search-status");
  const results = document.querySelector("#map-search-results");
  status.classList.add("loading");
  status.textContent = "住所を検索しています。";
  results.replaceChildren();
  try {
    const data = await apiFetch(`/api/map-search?q=${encodeURIComponent(query)}`);
    status.classList.remove("loading");
    status.textContent = data.results.length ? `${data.results.length}件の候補` : "候補が見つかりませんでした。";
    if (!data.results.length) return;
    results.innerHTML = data.results.map((place, index) => `
      <button type="button" data-place-index="${index}"><strong>${escapeHtml(place.title)}</strong><small>${place.lat.toFixed(5)}, ${place.lng.toFixed(5)}</small></button>`).join("");
    results.querySelectorAll("[data-place-index]").forEach((button) => button.addEventListener("click", () => {
      const place = data.results[Number(button.dataset.placeIndex)];
      state.map.setView([place.lat, place.lng], 16);
      setMapPoint(place.lat, place.lng, place.title);
    }));
    if (data.results.length === 1) results.querySelector("button")?.click();
  } catch (error) {
    status.classList.remove("loading");
    status.textContent = error.message;
  }
}

async function updateLocationPermissionState() {
  const status = document.querySelector("#location-status");
  const button = document.querySelector("#locate-button");
  if (!status || !button) return;
  if (!window.isSecureContext) {
    status.textContent = "現在地はHTTPS接続でのみ利用できます。";
    button.disabled = true;
    return;
  }
  if (!navigator.geolocation) {
    status.textContent = "このブラウザーは位置情報に対応していません。";
    button.disabled = true;
    return;
  }
  const policy = document.permissionsPolicy || document.featurePolicy;
  if (policy?.allowsFeature && !policy.allowsFeature("geolocation")) {
    status.textContent = "この画面では位置情報の利用が制限されています。通常のブラウザーで開いてください。";
    button.disabled = true;
    return;
  }
  button.disabled = false;
  if (!navigator.permissions?.query) return;
  try {
    const permission = await navigator.permissions.query({ name: "geolocation" });
    applyPermissionState(permission.state);
    permission.addEventListener?.("change", () => applyPermissionState(permission.state));
  } catch {
    status.textContent = "現在地ボタンを押すと、ブラウザーが位置情報を確認します。";
  }
}

function applyPermissionState(permissionState) {
  const status = document.querySelector("#location-status");
  const button = document.querySelector("#locate-button");
  if (!status || !button) return;
  button.disabled = false;
  if (permissionState === "granted") status.textContent = "位置情報は許可されています。現在地ボタンで取得できます。";
  else if (permissionState === "denied") status.textContent = "位置情報は拒否されています。アドレスバーのサイト設定で位置情報を許可してください。";
  else status.textContent = "現在地ボタンを押すと、ブラウザーが許可を確認します。";
}

async function locateUser() {
  const button = document.querySelector("#locate-button");
  const status = document.querySelector("#location-status");
  if (!window.isSecureContext) {
    status.textContent = "現在地はHTTPS接続でのみ利用できます。";
    return;
  }
  if (!navigator.geolocation || !state.map) {
    status.textContent = "このブラウザーは位置情報に対応していません。";
    return;
  }
  button.disabled = true;
  button.textContent = "位置を確認中…";
  try {
    status.textContent = "高精度の現在地を確認しています。許可画面が出た場合は「許可」を選んでください。";
    let position;
    try {
      position = await requestPosition({ enableHighAccuracy: true, timeout: 12_000, maximumAge: 0 });
    } catch (error) {
      if (error.code === 1) throw error;
      status.textContent = "通常精度に切り替えて現在地を確認しています。";
      position = await requestPosition({ enableHighAccuracy: false, timeout: 20_000, maximumAge: 300_000 });
    }
    const { coords } = position;
    state.map.setView([coords.latitude, coords.longitude], 14);
    setMapPoint(coords.latitude, coords.longitude, "現在地");
    if (state.accuracyLayer) state.accuracyLayer.remove();
    state.accuracyLayer = window.L.circle([coords.latitude, coords.longitude], {
      radius: Math.max(coords.accuracy, 10),
      color: "#167d60",
      weight: 1,
      fillColor: "#3fb68c",
      fillOpacity: .12,
      interactive: false,
    }).addTo(state.map);
    status.textContent = `現在地を表示しました（精度 約${Math.round(coords.accuracy)}m）。`;
  } catch (error) {
    const messages = {
      1: "位置情報が拒否されています。アドレスバーのサイト設定と端末側の位置情報を許可してから再度お試しください。",
      2: "端末から現在地が返りませんでした。端末の位置情報とWi-Fiを有効にして再度お試しください。",
      3: "位置情報の取得がタイムアウトしました。屋外または通信しやすい場所で再度お試しください。",
    };
    status.textContent = messages[error.code] || "位置情報を取得できませんでした。";
  } finally {
    button.disabled = false;
    button.textContent = "◎ 現在地";
  }
}

function requestPosition(options) {
  return new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(resolve, reject, options));
}

function resultSummary(data, visibleCount) {
  const filtered = visibleCount !== data.results.length ? `、条件一致 ${visibleCount}件` : "";
  return `「${data.query}」の検索結果 ${number(data.total)}件（${data.results.length}件取得${filtered}）`;
}

function syncSelectOptions(selector, values) {
  const select = document.querySelector(selector);
  if (!select) return;
  const selectedValue = select.value;
  const labels = [...new Set(values.map((value) => String(value || "").trim()).filter(Boolean))]
    .sort((left, right) => left.localeCompare(right, "ja"));
  select.replaceChildren(new Option("すべて", "all"), ...labels.map((label) => new Option(label, label)));
  select.value = labels.includes(selectedValue) ? selectedValue : "all";
}

function matchesText(values, query) {
  const normalizedQuery = normalizeSearchText(query);
  if (!normalizedQuery) return true;
  return normalizeSearchText(values.filter(Boolean).join(" ")).includes(normalizedQuery);
}

function normalizeSearchText(value) {
  return String(value || "").normalize("NFKC").toLocaleLowerCase("ja").replace(/\s+/gu, " ").trim();
}

function isWithinYears(value, years) {
  const timestamp = dateValue(value);
  if (!timestamp || !years) return false;
  const threshold = new Date();
  threshold.setFullYear(threshold.getFullYear() - years);
  return timestamp >= threshold.getTime();
}

function sortItems(items, sort, selectors) {
  const selector = selectors[sort];
  if (!selector) return [...items];
  const ascending = sort.endsWith("-asc") || sort === "title";
  return [...items].sort((left, right) => {
    const leftValue = selector(left);
    const rightValue = selector(right);
    if (!leftValue && rightValue) return 1;
    if (leftValue && !rightValue) return -1;
    const comparison = typeof leftValue === "number"
      ? leftValue - rightValue
      : String(leftValue).localeCompare(String(rightValue), "ja");
    return ascending ? comparison : -comparison;
  });
}

function matchesBookCategory(book, category) {
  if (category === "all") return true;
  const categories = book.categories.join(" ");
  if (category === "book") return /図書|本/u.test(categories);
  if (category === "article") return /雑誌|記事|論文|逐次刊行/u.test(categories);
  if (category === "digital") return /デジタル|電子|オンライン|インターネット/u.test(categories);
  return true;
}

function dateValue(value) {
  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function yearValue(value) {
  return Number(String(value || "").match(/(?:1|2)\d{3}/u)?.[0]) || 0;
}

async function apiFetch(url) {
  const response = await fetch(url, { headers: { Accept: "application/json" } });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.message || "情報を取得できませんでした。");
  return payload;
}

function setLoading(element, message) { element.classList.add("loading"); element.textContent = message; }
function showError(status, results, error) { status.classList.remove("loading"); status.textContent = error.message; renderEmpty(results, "時間を置いて、もう一度お試しください。"); }
function showDetailError(status, message) { status.classList.remove("loading"); status.textContent = message; }
function renderEmpty(container, message) { container.innerHTML = `<div class="empty-state">${escapeHtml(message)}</div>`; }
function formatDate(value) { if (!value) return "日付不明"; const date = new Date(value); return Number.isNaN(date.getTime()) ? escapeHtml(value) : new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "2-digit", day: "2-digit", timeZone: "Asia/Tokyo" }).format(date); }
function formatDateTime(value) { if (!value) return "時刻不明"; const date = new Date(value); return Number.isNaN(date.getTime()) ? escapeHtml(value) : new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Tokyo" }).format(date); }
function formatShortTime(value) { if (!value) return "--/-- --:--"; const date = new Date(value); return Number.isNaN(date.getTime()) ? escapeHtml(value) : new Intl.DateTimeFormat("ja-JP", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Tokyo" }).format(date); }
function formatMultiline(value) { return escapeHtml(value).replace(/\n/gu, "<br>"); }
function number(value) { return new Intl.NumberFormat("ja-JP").format(value || 0); }
function safeUrl(value) { try { const url = new URL(value); return ["https:", "http:"].includes(url.protocol) ? escapeHtml(url.href) : "#"; } catch { return "#"; } }
function escapeHtml(value) { return String(value ?? "").replace(/[&<>'"]/gu, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]); }
