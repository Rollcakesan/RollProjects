const UPSTREAM_TIMEOUT_MS = 20_000;
const USER_AGENT = "JInfo/1.0 (+https://jinfo.rollprojects.com/)";

export class ProviderError extends Error {
  constructor(message, status = 502, code = "UPSTREAM_ERROR") {
    super(message);
    this.name = "ProviderError";
    this.status = status;
    this.code = code;
  }
}

export const WEATHER_FEEDS = Object.freeze({
  extra: {
    label: "警報・注意報",
    url: "https://www.data.jma.go.jp/developer/xml/feed/extra.xml",
  },
  eqvol: {
    label: "地震・火山",
    url: "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
  },
  regular: {
    label: "定時情報",
    url: "https://www.data.jma.go.jp/developer/xml/feed/regular.xml",
  },
  other: {
    label: "その他",
    url: "https://www.data.jma.go.jp/developer/xml/feed/other.xml",
  },
});

export function normalizeQuery(value, { maxLength = 80, name = "検索語" } = {}) {
  const query = String(value ?? "").replace(/[\u0000-\u001f\u007f]/gu, " ").replace(/\s+/gu, " ").trim();
  if (query.length < 2) {
    throw new ProviderError(`${name}を2文字以上入力してください。`, 400, "INVALID_QUERY");
  }
  if (query.length > maxLength) {
    throw new ProviderError(`${name}は${maxLength}文字以内で入力してください。`, 400, "INVALID_QUERY");
  }
  return query;
}

export function normalizeLimit(value, { defaultValue = 25, max = 100 } = {}) {
  const limit = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(limit) ? Math.min(Math.max(limit, 1), max) : defaultValue;
}

export async function searchLaws(query, limitValue = 25, fetcher = fetch) {
  const keyword = normalizeQuery(query);
  const limit = normalizeLimit(limitValue);
  const url = new URL("https://laws.e-gov.go.jp/api/2/keyword");
  url.searchParams.set("keyword", keyword);
  url.searchParams.set("limit", String(limit));

  const response = await fetchJson(url, fetcher);
  const items = Array.isArray(response.items) ? response.items : [];
  return {
    query: keyword,
    total: Number(response.total_count) || items.length,
    results: items.map((item) => ({
      id: item.law_info?.law_id || "",
      number: item.law_info?.law_num || "",
      type: translateLawType(item.law_info?.law_type),
      title: item.revision_info?.law_title || "名称不明の法令",
      category: item.revision_info?.category || "",
      promulgatedAt: item.law_info?.promulgation_date || "",
      updatedAt: item.revision_info?.updated || "",
      excerpts: (Array.isArray(item.sentences) ? item.sentences : [])
        .slice(0, 3)
        .map((sentence) => stripMarkup(sentence.text))
        .filter(Boolean),
      url: item.law_info?.law_id
        ? `https://laws.e-gov.go.jp/law/${encodeURIComponent(item.law_info.law_id)}`
        : "https://laws.e-gov.go.jp/",
    })),
    source: "e-Gov法令検索 法令API Version 2",
  };
}

export async function getWeatherFeed(feedName = "extra", fetcher = fetch) {
  const feed = WEATHER_FEEDS[feedName];
  if (!feed) throw new ProviderError("指定された情報種別は利用できません。", 400, "INVALID_FEED");

  const xml = await fetchText(feed.url, "application/atom+xml, application/xml", fetcher);
  const parsed = parseAtomFeed(xml);
  return {
    feed: feedName,
    label: feed.label,
    updatedAt: parsed.updatedAt,
    results: parsed.entries.slice(0, 100),
    source: "気象庁防災情報XML",
  };
}

export async function getWeatherDetail(sourceUrl, fetcher = fetch) {
  const url = validateJmaDetailUrl(sourceUrl);
  const xml = await fetchText(url, "application/xml", fetcher);
  return {
    ...parseWeatherDetail(xml),
    sourceUrl: url.href,
    source: "気象庁防災情報XML",
  };
}

export async function searchDatasets(query, limitValue = 25, fetcher = fetch) {
  const keyword = normalizeQuery(query);
  const limit = normalizeLimit(limitValue);
  const url = new URL("https://data.e-gov.go.jp/data/api/3/action/package_search");
  url.searchParams.set("q", keyword);
  url.searchParams.set("rows", String(limit));

  const response = await fetchJson(url, fetcher);
  if (!response.success || !response.result) {
    throw new ProviderError("行政データを取得できませんでした。");
  }

  const datasets = Array.isArray(response.result.results) ? response.result.results : [];
  return {
    query: keyword,
    total: Number(response.result.count) || datasets.length,
    results: datasets.map((dataset) => ({
      id: dataset.id || "",
      name: dataset.name || "",
      title: dataset.title || "名称不明のデータセット",
      organization: dataset.organization?.title || dataset.publisher || "",
      description: stripMarkup(dataset.notes || ""),
      updatedAt: dataset.metadata_modified || "",
      frequency: dataset.frequency_of_update || "",
      tags: (Array.isArray(dataset.tags) ? dataset.tags : []).slice(0, 5).map((tag) => tag.display_name || tag.name).filter(Boolean),
      formats: unique((Array.isArray(dataset.resources) ? dataset.resources : [])
        .map((resource) => String(resource.format || "").toUpperCase())
        .filter(Boolean)),
      resources: (Array.isArray(dataset.resources) ? dataset.resources : [])
        .filter((resource) => isHttpUrl(resource.url))
        .slice(0, 6)
        .map((resource) => ({
          name: resource.name || resource.description || "データを開く",
          format: resource.format || "DATA",
          url: resource.url,
        })),
      url: dataset.name
        ? `https://data.e-gov.go.jp/data/dataset/${encodeURIComponent(dataset.name)}`
        : "https://data.e-gov.go.jp/",
    })),
    source: "e-Govデータポータル",
  };
}

export async function searchBooks(query, limitValue = 25, fetcher = fetch) {
  const keyword = normalizeQuery(query);
  const limit = normalizeLimit(limitValue);
  const url = new URL("https://ndlsearch.ndl.go.jp/api/opensearch");
  url.searchParams.set("dpid", "open");
  url.searchParams.set("any", keyword);
  url.searchParams.set("cnt", String(limit));

  const xml = await fetchText(url, "application/rss+xml, application/xml", fetcher);
  const parsed = parseNdlFeed(xml);
  return {
    query: keyword,
    total: parsed.total,
    results: parsed.items,
    source: "国立国会図書館サーチAPI（オープンメタデータ）",
  };
}

export async function searchMapPlaces(query, fetcher = fetch) {
  const keyword = normalizeQuery(query, { maxLength: 100, name: "住所・地名" });
  const url = new URL("https://msearch.gsi.go.jp/address-search/AddressSearch");
  url.searchParams.set("q", keyword);

  const response = await fetchJson(url, fetcher);
  const features = Array.isArray(response) ? response : [];
  return {
    query: keyword,
    results: features.slice(0, 20).map((feature) => ({
      title: feature.properties?.title || "名称不明の地点",
      addressCode: feature.properties?.addressCode || "",
      lng: Number(feature.geometry?.coordinates?.[0]),
      lat: Number(feature.geometry?.coordinates?.[1]),
    })).filter((place) => Number.isFinite(place.lat) && Number.isFinite(place.lng)),
    source: "国土地理院 住所検索API",
  };
}

export function parseAtomFeed(xml) {
  const feed = String(xml || "");
  const entries = matchBlocks(feed, "entry").map((entry) => {
    const title = tagText(entry, "title");
    return {
      title,
      category: classifyWeather(title),
      summary: tagText(entry, "content"),
      publisher: tagText(firstBlock(entry, "author"), "name"),
      updatedAt: tagText(entry, "updated"),
      url: attributeValue(entry, "link", "href", /application\/xml/iu) || tagText(entry, "id"),
    };
  });

  return {
    updatedAt: tagText(feed.slice(0, Math.max(feed.indexOf("<entry"), 0) || 4_000), "updated"),
    entries,
  };
}

export function parseNdlFeed(xml) {
  const feed = String(xml || "");
  const items = matchBlocks(feed, "item").map((item) => {
    const identifiers = matchTagValues(item, "dc:identifier");
    return {
      title: tagText(item, "title"),
      url: tagText(item, "link"),
      creator: tagText(item, "dc:creator") || tagText(item, "author"),
      publisher: tagText(item, "dc:publisher"),
      year: tagText(item, "dcterms:issued") || tagText(item, "dc:date"),
      description: summarizeNdlDescription(tagRaw(item, "description")),
      categories: matchTagValues(item, "category").slice(0, 4),
      isbn: identifiers.find((value) => /(?:97[89][\d-]{10,}|\d[\d-]{8,})/u.test(value)) || "",
    };
  });

  return {
    total: Number(tagText(feed, "openSearch:totalResults")) || items.length,
    items,
  };
}

export function parseWeatherDetail(xml) {
  const report = String(xml || "");
  const control = firstBlock(report, "Control");
  const head = firstBlock(report, "Head");
  const headline = firstBlock(head, "Headline");
  const body = firstBlock(report, "Body");
  const title = tagText(head, "Title") || tagText(control, "Title") || "防災情報";
  const informationGroups = matchBlocksWithAttributes(headline, "Information").map(({ attributes, content }) => {
    const type = attributeValueFromOpeningTag(attributes, "type") || "対象情報";
    const entries = matchBlocks(content, "Item").map((item) => {
      const kind = tagText(firstBlock(item, "Kind"), "Name") || "情報";
      const areasBlock = firstBlock(item, "Areas") || firstBlock(item, "Area");
      const areas = unique(matchTagValues(areasBlock, "Name"));
      return { kind, areas };
    }).filter((entry) => entry.kind !== "なし" || entry.areas.length);
    return { type, entries };
  }).filter((group) => group.entries.length);

  const allTexts = unique([
    ...matchTagValues(report, "Text"),
    ...matchTagValues(body, "Notice"),
    ...matchTagValues(body, "OtherObservation"),
    ...matchTagValues(body, "Remark"),
  ])
    .filter((text) => text && text !== tagText(headline, "Text"))
    .filter((text) => !/^https?:\/\//u.test(text))
    .slice(0, 30);

  return {
    title,
    controlTitle: tagText(control, "Title"),
    category: classifyWeather(`${title} ${tagText(control, "Title")}`),
    publisher: tagText(control, "PublishingOffice") || tagText(control, "EditorialOffice"),
    editorialOffice: tagText(control, "EditorialOffice"),
    publishedAt: tagText(head, "ReportDateTime") || tagText(control, "DateTime"),
    targetAt: tagText(head, "TargetDateTime"),
    validUntil: tagText(head, "ValidDateTime"),
    infoType: tagText(head, "InfoType"),
    infoKind: tagText(head, "InfoKind"),
    headline: tagText(headline, "Text"),
    informationGroups,
    bodySections: parseWeatherBody(body),
    notes: allTexts,
  };
}

export function parseWeatherBody(bodyXml) {
  const body = String(bodyXml || "");
  if (!body) return [];
  return [
    ...parseWarningSections(body),
    ...parseMeteorologicalSections(body),
    ...parseIntensitySections(body),
    ...parseGenericBodySections(body),
  ].filter((section) => section.entries.length);
}

function parseWarningSections(body) {
  return matchBlocksWithAttributes(body, "Warning").map(({ attributes, content }) => ({
    title: attributeValueFromOpeningTag(attributes, "type") || "警報・注意報",
    entries: matchBlocks(content, "Item").map((item, index) => {
      const areaNames = areaNamesFrom(item);
      const kindSummaries = matchBlocks(item, "Kind").map(parseKindSummary).filter(Boolean);
      const facts = [
        fact("発表内容", kindSummaries.join(" ／ ")),
        fact("変化", tagText(item, "ChangeStatus")),
        fact("状態", tagText(item, "FullStatus")),
      ].filter(Boolean);
      return { heading: areaNames.join("、") || `対象 ${index + 1}`, facts };
    }).filter((entry) => entry.facts.length),
  }));
}

function parseMeteorologicalSections(body) {
  return matchBlocksWithAttributes(body, "MeteorologicalInfos").flatMap(({ attributes, content }) => {
    const sectionType = attributeValueFromOpeningTag(attributes, "type") || "気象情報";
    return matchBlocks(content, "MeteorologicalInfo").map((meteorologicalInfo, infoIndex) => {
      const dateTime = tagText(meteorologicalInfo, "DateTime");
      const dateTimeBlock = tagRaw(meteorologicalInfo, "DateTime");
      const dateType = attributeValueFromOpeningTag(
        meteorologicalInfo.match(/<DateTime\b([^>]*)>/iu)?.[1] || "",
        "type",
      );
      const entries = matchBlocks(meteorologicalInfo, "Item").map((item, itemIndex) => {
        const areaNames = areaNamesFrom(item);
        const kindSummaries = matchBlocks(item, "Kind").map(parseKindSummary).filter(Boolean);
        const facts = [
          fact(dateType || "対象時刻", dateTime || stripMarkup(dateTimeBlock)),
          fact("内容", kindSummaries.join(" ／ ")),
          ...semanticLeafFacts(item, { excludedNames: ["Name", "Code", "Type", "DateTime"] }),
        ].filter(Boolean);
        return {
          heading: areaNames.join("、") || kindSummaries[0]?.split("：")[0] || `項目 ${itemIndex + 1}`,
          facts: uniqueFacts(facts),
        };
      }).filter((entry) => entry.facts.length);
      return { title: dateType ? `${sectionType}・${dateType}` : `${sectionType} ${infoIndex + 1}`, entries };
    });
  });
}

function parseIntensitySections(body) {
  return matchBlocks(body, "Intensity").flatMap((intensity) => {
    const entries = matchBlocks(intensity, "City").flatMap((city) => {
      const cityName = tagText(city, "Name");
      return matchBlocks(city, "IntensityStation").map((station) => ({
        heading: [cityName, tagText(station, "Name")].filter(Boolean).join("・") || "観測地点",
        facts: [fact("震度", tagText(station, "Int"))].filter(Boolean),
      }));
    });
    if (!entries.length) return [];
    return [{ title: "観測地点別震度", entries }];
  });
}

function parseGenericBodySections(body) {
  const definitions = [
    ["VolcanoInfo", "火山情報"],
    ["VolcanoObservation", "火山観測"],
    ["Earthquake", "地震情報"],
    ["Tsunami", "津波情報"],
    ["AshInfos", "降灰情報"],
    ["TyphoonInfo", "台風情報"],
    ["MarineWarning", "海上警報"],
    ["WeatherForecast", "天気予報"],
  ];
  return definitions.flatMap(([tagName, defaultTitle]) =>
    matchBlocksWithAttributes(body, tagName).map(({ attributes, content }) => {
      const title = attributeValueFromOpeningTag(attributes, "type") || defaultTitle;
      const itemBlocks = matchBlocks(content, "Item");
      const sourceEntries = itemBlocks.length ? itemBlocks : [content];
      const entries = sourceEntries.map((item, index) => parseGenericBodyEntry(item, title, index));
      return { title, entries: entries.filter((entry) => entry.facts.length) };
    }),
  );
}

function parseGenericBodyEntry(item, fallbackHeading, index) {
  const areaNames = areaNamesFrom(item);
  const craterName = tagText(item, "CraterName");
  const firstName = tagText(item, "Name");
  const heading = areaNames.join("、") || craterName || firstName || (index ? `${fallbackHeading} ${index + 1}` : fallbackHeading);
  return {
    heading,
    facts: uniqueFacts(semanticLeafFacts(item, { excludedNames: ["Name", "Code", "Title"] })),
  };
}

function parseKindSummary(kind) {
  const name = tagText(kind, "Name") || tagText(kind, "Type");
  const status = tagText(kind, "Status");
  const notes = unique([
    ...matchTagValues(kind, "Note"),
    ...matchTagValues(kind, "Addition"),
    ...matchBlocks(kind, "Property").flatMap((property) => {
      const propertyType = tagText(property, "Type");
      const values = semanticLeafFacts(property, { excludedNames: ["Type", "Code"] })
        .map((entry) => `${entry.label} ${entry.value}`);
      return [propertyType, ...values].filter(Boolean);
    }),
  ]).filter((value) => value !== name && value !== status);
  if (!name && !status && !notes.length) return "";
  const main = [name, status ? `（${status}）` : ""].join("");
  return notes.length ? `${main || "詳細"}：${notes.join("、")}` : main;
}

function semanticLeafFacts(xml, { excludedNames = [] } = {}) {
  const excluded = new Set(["Code", "Line", "Base", "Axis", "Serial", ...excludedNames]);
  const facts = [];
  for (const match of String(xml || "").matchAll(/<([A-Za-z][A-Za-z0-9_.:-]*)\b([^>]*)>([^<>]*)<\/\1>/gu)) {
    const localName = match[1].split(":").at(-1);
    if (excluded.has(localName)) continue;
    const rawValue = stripMarkup(match[3]);
    if (!rawValue || rawValue.length > 500) continue;
    const description = attributeValueFromOpeningTag(match[2], "description");
    const type = attributeValueFromOpeningTag(match[2], "type");
    const unit = attributeValueFromOpeningTag(match[2], "unit");
    if (/Coordinate|Line|Polygon/u.test(localName) && !description) continue;
    const label = type || weatherFieldLabel(localName);
    const value = description || (unit && !rawValue.includes(unit) ? `${rawValue} ${unit}` : rawValue);
    if (!label || !value || label === value) continue;
    facts.push({ label, value });
  }
  return facts;
}

function weatherFieldLabel(name) {
  return ({
    EventDateTime: "発生時刻",
    EventDateTimeUTC: "発生時刻（UTC）",
    OriginTime: "発生時刻",
    ArrivalTime: "検知時刻",
    TargetDateTime: "対象時刻",
    DateTime: "日時",
    Date: "日付",
    Term: "時間帯",
    Sentence: "内容",
    TimeModifier: "時刻条件",
    Status: "状態",
    ChangeStatus: "変化",
    FullStatus: "対象範囲",
    CraterName: "火口",
    Magnitude: "マグニチュード",
    Int: "震度",
    MaxInt: "最大震度",
    Pressure: "気圧",
    Direction: "方向",
    Speed: "速度",
    WindSpeed: "風速",
    Visibility: "視程",
    Weather: "天気",
    ProbabilityOfPrecipitation: "降水確率",
    PlumeHeightAboveCrater: "火口上噴煙高度",
    PlumeHeightAboveSeaLevel: "海抜噴煙高度",
    PlumeDirection: "噴煙の流向",
    OtherObservation: "観測事項",
    Notice: "お知らせ",
    Text: "本文",
  })[name] || name.replace(/([a-z])([A-Z])/gu, "$1 $2");
}

function areaNamesFrom(xml) {
  return unique(matchBlocks(xml, "Area").flatMap((area) => matchTagValues(area, "Name")));
}

function fact(label, value) {
  return value ? { label, value } : null;
}

function uniqueFacts(facts) {
  const seen = new Set();
  return facts.filter((entry) => {
    if (!entry?.label || !entry.value) return false;
    const key = `${entry.label}\u0000${entry.value}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function classifyWeather(title) {
  if (/地震|震源|震度/u.test(title)) return "地震";
  if (/津波/u.test(title)) return "津波";
  if (/火山|噴火/u.test(title)) return "火山";
  if (/台風/u.test(title)) return "台風";
  if (/警報|注意報|土砂|竜巻/u.test(title)) return "警報";
  if (/天気|気象/u.test(title)) return "気象";
  return "防災";
}

function translateLawType(type) {
  return ({ Constitution: "憲法", Act: "法律", CabinetOrder: "政令", ImperialOrder: "勅令", MinisterialOrdinance: "府省令", Rule: "規則", Misc: "その他" })[type] || type || "法令";
}

async function fetchJson(url, fetcher) {
  const text = await fetchText(url, "application/json", fetcher);
  try {
    return JSON.parse(text);
  } catch {
    throw new ProviderError("提供元から不正なデータが返されました。", 502, "INVALID_UPSTREAM_RESPONSE");
  }
}

async function fetchText(url, accept, fetcher) {
  let response;
  try {
    response = await fetcher(url, {
      headers: { Accept: accept, "User-Agent": USER_AGENT },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (error) {
    if (error?.name === "TimeoutError") {
      throw new ProviderError("提供元の応答に時間がかかっています。", 504, "UPSTREAM_TIMEOUT");
    }
    throw new ProviderError("提供元へ接続できませんでした。", 502, "UPSTREAM_UNAVAILABLE");
  }
  if (!response.ok) {
    throw new ProviderError(`提供元からエラーが返されました（${response.status}）。`, 502, "UPSTREAM_ERROR");
  }
  return response.text();
}

function matchBlocks(xml, name) {
  const escaped = escapeRegExp(name);
  return [...xml.matchAll(new RegExp(`<${escaped}\\b[^>]*>([\\s\\S]*?)<\\/${escaped}>`, "giu"))].map((match) => match[1]);
}

function matchBlocksWithAttributes(xml, name) {
  const escaped = escapeRegExp(name);
  return [...xml.matchAll(new RegExp(`<${escaped}\\b([^>]*)>([\\s\\S]*?)<\\/${escaped}>`, "giu"))]
    .map((match) => ({ attributes: match[1], content: match[2] }));
}

function firstBlock(xml, name) {
  return matchBlocks(xml, name)[0] || "";
}

function tagRaw(xml, name) {
  const escaped = escapeRegExp(name);
  return xml.match(new RegExp(`<${escaped}\\b[^>]*>([\\s\\S]*?)<\\/${escaped}>`, "iu"))?.[1] || "";
}

function tagText(xml, name) {
  return stripMarkup(tagRaw(xml, name));
}

function matchTagValues(xml, name) {
  const escaped = escapeRegExp(name);
  return [...xml.matchAll(new RegExp(`<${escaped}\\b[^>]*>([\\s\\S]*?)<\\/${escaped}>`, "giu"))]
    .map((match) => stripMarkup(match[1]))
    .filter(Boolean);
}

function attributeValue(xml, tagName, attributeName, tagFilter) {
  const escapedTag = escapeRegExp(tagName);
  const escapedAttribute = escapeRegExp(attributeName);
  for (const match of xml.matchAll(new RegExp(`<${escapedTag}\\b([^>]*)\\/?\s*>`, "giu"))) {
    if (tagFilter && !tagFilter.test(match[1])) continue;
    const value = match[1].match(new RegExp(`${escapedAttribute}=["']([^"']+)["']`, "iu"))?.[1];
    if (value) return decodeXml(value);
  }
  return "";
}

function attributeValueFromOpeningTag(xml, attributeName) {
  return decodeXml(String(xml || "").match(new RegExp(`${escapeRegExp(attributeName)}=["']([^"']+)["']`, "iu"))?.[1] || "");
}

function summarizeNdlDescription(raw) {
  const decoded = decodeXml(raw);
  const listItems = [...decoded.matchAll(/<li>([\s\S]*?)<\/li>/giu)]
    .map((match) => stripMarkup(match[1]))
    .filter(Boolean);
  return listItems.slice(0, 3).join(" ／ ") || stripMarkup(decoded).slice(0, 260);
}

function stripMarkup(value) {
  return decodeXml(String(value || "").replace(/<!\[CDATA\[|\]\]>/gu, "").replace(/<[^>]*>/gu, " "))
    .replace(/\s+/gu, " ")
    .trim();
}

function decodeXml(value) {
  return String(value || "")
    .replace(/&#x([0-9a-f]+);/giu, (_, code) => String.fromCodePoint(Number.parseInt(code, 16)))
    .replace(/&#(\d+);/gu, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&lt;/gu, "<")
    .replace(/&gt;/gu, ">")
    .replace(/&quot;/gu, '"')
    .replace(/&apos;/gu, "'")
    .replace(/&amp;/gu, "&");
}

function isHttpUrl(value) {
  try {
    return ["http:", "https:"].includes(new URL(value).protocol);
  } catch {
    return false;
  }
}

function validateJmaDetailUrl(value) {
  let url;
  try {
    url = new URL(String(value || ""));
  } catch {
    throw new ProviderError("防災情報のURLが正しくありません。", 400, "INVALID_DETAIL_URL");
  }
  if (
    url.protocol !== "https:" ||
    url.hostname !== "www.data.jma.go.jp" ||
    !/^\/developer\/xml\/data\/[A-Za-z0-9_.-]+\.xml$/u.test(url.pathname) ||
    url.search ||
    url.hash
  ) {
    throw new ProviderError("指定された防災情報は表示できません。", 400, "INVALID_DETAIL_URL");
  }
  return url;
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
