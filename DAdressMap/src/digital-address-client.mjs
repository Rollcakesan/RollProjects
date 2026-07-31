const DASH_PATTERN = /[-‐‑‒–—―ー\s]/gu;
const VALID_CODE_PATTERN = /^[A-Z0-9]{7}$/u;
const POSTAL_PREFIX_PATTERN = /^\d{3,7}$/u;

export class DigitalAddressError extends Error {
  constructor(message, status = 502, code = "UPSTREAM_ERROR") {
    super(message);
    this.name = "DigitalAddressError";
    this.status = status;
    this.code = code;
  }
}

export function normalizeCode(value) {
  return String(value ?? "")
    .normalize("NFKC")
    .trim()
    .replace(/^@/u, "")
    .replace(DASH_PATTERN, "")
    .toUpperCase();
}

export function classifyCode(value) {
  const code = normalizeCode(value);

  if (!VALID_CODE_PATTERN.test(code) && !POSTAL_PREFIX_PATTERN.test(code)) {
    throw new DigitalAddressError(
      "3〜7桁の郵便番号、または7桁のデジタルアドレスを入力してください。",
      400,
      "INVALID_CODE",
    );
  }

  return {
    code,
    type: /^\d{7}$/u.test(code)
      ? "postal-code"
      : POSTAL_PREFIX_PATTERN.test(code)
        ? "postal-prefix"
        : "digital-address",
  };
}

export function normalizeAddressQuery(value) {
  const query = String(value ?? "").normalize("NFKC").trim().replace(/\s+/gu, " ");

  if (query.length < 2 || query.length > 120) {
    throw new DigitalAddressError(
      "住所は2文字以上120文字以内で入力してください。",
      400,
      "INVALID_ADDRESS_QUERY",
    );
  }

  return query;
}

export function formatPostalCode(value) {
  const digits = String(value ?? "").replace(/\D/gu, "");
  return digits.length === 7 ? `${digits.slice(0, 3)}-${digits.slice(3)}` : String(value ?? "");
}

export function normalizeAddress(rawAddress) {
  const address = rawAddress && typeof rawAddress === "object" ? rawAddress : {};
  const locations = normalizeLocations(address.locations);
  const latitude = toFiniteNumber(address.latitude) ?? locations[0]?.latitude ?? null;
  const longitude = toFiniteNumber(address.longitude) ?? locations[0]?.longitude ?? null;
  const fullAddress =
    address.address ||
    [
      address.pref_name,
      address.city_name,
      address.town_name,
      address.block_name,
      address.other_name,
    ]
      .filter(Boolean)
      .join("");

  return {
    digitalAddress: address.dgacode || null,
    postalCode: formatPostalCode(address.zip_code),
    prefecture: address.pref_name || "",
    city: address.city_name || "",
    town: address.town_name || "",
    block: address.block_name || "",
    building: address.other_name || "",
    businessName: address.business_name || address.biz_name || "",
    businessNameKana: address.business_name_kana || address.biz_kana || "",
    businessNameRoman:
      address.business_name_roma || address.business_name_roman || address.biz_roma || "",
    corporateNumber: String(address.corporate_number || ""),
    telephone: address.tel_number || "",
    website: address.url || "",
    usage: address.usage || "",
    fullAddress,
    kana: [address.pref_kana, address.city_kana, address.town_kana].filter(Boolean).join(" "),
    roman: [address.town_roma, address.city_roma, address.pref_roma].filter(Boolean).join(", "),
    latitude,
    longitude,
    locations,
  };
}

const DEMO_RESULTS = new Map(
  [
    {
      dgacode: "A7E2FK2",
      zip_code: "100-0005",
      pref_name: "東京都",
      city_name: "千代田区",
      town_name: "丸の内",
      block_name: "2丁目7-2",
      other_name: "部屋番号：サンプル1",
      address: "東京都千代田区丸の内2丁目7-2",
    },
    {
      dgacode: "JN4LKS2",
      zip_code: "530-0001",
      pref_name: "大阪府",
      city_name: "大阪市北区",
      town_name: "梅田",
      block_name: "3丁目2-2",
      other_name: "部屋番号：サンプル2",
      address: "大阪府大阪市北区梅田3丁目2-2",
    },
    {
      dgacode: "QN6GQX1",
      zip_code: "812-0012",
      pref_name: "福岡県",
      city_name: "福岡市博多区",
      town_name: "博多駅中央街",
      block_name: "9-1",
      other_name: "部屋番号：サンプル3",
      address: "福岡県福岡市博多区博多駅中央街9-1",
    },
    {
      dgacode: null,
      zip_code: "102-0072",
      pref_name: "東京都",
      pref_kana: "トウキョウト",
      pref_roma: "TOKYO",
      city_name: "千代田区",
      city_kana: "チヨダク",
      city_roma: "CHIYODA-KU",
      town_name: "飯田橋",
      town_kana: "イイダバシ",
      town_roma: "IIDABASHI",
    },
  ].map((address) => [normalizeCode(address.dgacode || address.zip_code), normalizeAddress(address)]),
);

export class DigitalAddressClient {
  constructor({
    baseUrl = process.env.JAPAN_POST_API_BASE_URL || "https://api.da.pf.japanpost.jp",
    clientId = process.env.JAPAN_POST_CLIENT_ID,
    clientSecret = process.env.JAPAN_POST_CLIENT_SECRET,
    sourceIp = process.env.JAPAN_POST_SOURCE_IP || "0.0.0.0",
    demoMode = process.env.DEMO_MODE !== "false",
    fetchImpl = globalThis.fetch,
  } = {}) {
    this.baseUrl = baseUrl.replace(/\/$/u, "");
    this.clientId = clientId;
    this.clientSecret = clientSecret;
    this.sourceIp = sourceIp;
    this.demoMode = demoMode;
    this.fetchImpl = fetchImpl;
    this.token = null;
    this.tokenExpiresAt = 0;
  }

  get configured() {
    return Boolean(this.clientId && this.clientSecret);
  }

  async lookup(input) {
    const { code, type } = classifyCode(input);

    if (!this.configured) {
      const demoResult = this.demoMode ? DEMO_RESULTS.get(code) : null;
      if (demoResult) {
        return { code, type, source: "demo", count: 1, page: 1, limit: 1, addresses: [demoResult] };
      }

      throw new DigitalAddressError(
        "現在は公式サンプルのみ検索できます。本番APIの設定後にすべての住所を検索できます。",
        503,
        "API_NOT_CONFIGURED",
      );
    }

    const token = await this.getToken();
    const url = new URL(`${this.baseUrl}/api/v2/searchcode/${encodeURIComponent(code)}`);
    url.searchParams.set("page", "1");
    url.searchParams.set("limit", "20");
    url.searchParams.set("choikitype", "1");
    url.searchParams.set("searchtype", "1");

    const response = await this.fetchWithTimeout(url, {
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
      },
    });
    const payload = await parseJsonResponse(response);

    if (!response.ok) {
      throw upstreamError(payload, response.status);
    }

    const addresses = Array.isArray(payload.addresses)
      ? payload.addresses.map(normalizeAddress).filter((address) => address.fullAddress)
      : [];

    if (addresses.length === 0) {
      throw new DigitalAddressError(
        "該当する住所が見つかりませんでした。",
        404,
        "ADDRESS_NOT_FOUND",
      );
    }

    return {
      code,
      type,
      source: "japan-post",
      count: toFiniteNumber(payload.count) ?? addresses.length,
      page: toFiniteNumber(payload.page) ?? 1,
      limit: toFiniteNumber(payload.limit) ?? addresses.length,
      addresses,
    };
  }

  async searchByAddress(input, { page = 1, limit = 20 } = {}) {
    const query = normalizeAddressQuery(input);
    const safePage = clampInteger(page, 1, 10_000, 1);
    const safeLimit = clampInteger(limit, 1, 100, 20);

    if (!this.configured) {
      const addresses = this.demoMode
        ? [...DEMO_RESULTS.values()].filter((address) => address.fullAddress.includes(query))
        : [];

      if (addresses.length > 0) {
        return {
          query,
          type: "address",
          source: "demo",
          matchLevel: 3,
          count: addresses.length,
          page: 1,
          limit: safeLimit,
          addresses,
        };
      }

      throw new DigitalAddressError(
        "本番APIの設定後に住所から郵便番号を検索できます。",
        503,
        "API_NOT_CONFIGURED",
      );
    }

    const token = await this.getToken();
    const response = await this.fetchWithTimeout(`${this.baseUrl}/api/v2/addresszip`, {
      method: "POST",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ freeword: query, page: safePage, limit: safeLimit }),
    });
    const payload = await parseJsonResponse(response);

    if (!response.ok) {
      throw upstreamError(payload, response.status);
    }

    const addresses = uniqueAddresses(flattenAddresses(payload.addresses).map(normalizeAddress));

    if (addresses.length === 0) {
      throw new DigitalAddressError(
        "該当する郵便番号が見つかりませんでした。",
        404,
        "ADDRESS_NOT_FOUND",
      );
    }

    return {
      query,
      type: "address",
      source: "japan-post",
      matchLevel: toFiniteNumber(payload.level),
      count: toFiniteNumber(payload.count) ?? addresses.length,
      page: toFiniteNumber(payload.page) ?? safePage,
      limit: toFiniteNumber(payload.limit) ?? safeLimit,
      addresses,
    };
  }

  async getToken() {
    if (this.token && Date.now() < this.tokenExpiresAt) {
      return this.token;
    }

    const response = await this.fetchWithTimeout(`${this.baseUrl}/api/v2/j/token`, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "x-forwarded-for": this.sourceIp,
      },
      body: JSON.stringify({
        grant_type: "client_credentials",
        client_id: this.clientId,
        secret_key: this.clientSecret,
      }),
    });
    const payload = await parseJsonResponse(response);

    if (!response.ok || !payload.token) {
      throw upstreamError(payload, response.status, "API認証に失敗しました。");
    }

    const expiresInSeconds = Math.max(60, Number(payload.expires_in) || 600);
    this.token = payload.token;
    this.tokenExpiresAt = Date.now() + Math.max(30, expiresInSeconds - 60) * 1000;
    return this.token;
  }

  async fetchWithTimeout(url, options) {
    try {
      return await this.fetchImpl(url, {
        ...options,
        signal: AbortSignal.timeout(8_000),
      });
    } catch (error) {
      if (error?.name === "TimeoutError") {
        throw new DigitalAddressError("住所検索がタイムアウトしました。", 504, "UPSTREAM_TIMEOUT");
      }
      throw new DigitalAddressError("住所検索サービスへ接続できませんでした。", 502, "UPSTREAM_UNAVAILABLE");
    }
  }
}

function toFiniteNumber(value) {
  if (value == null || (typeof value === "string" && value.trim() === "")) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function normalizeLocations(value) {
  if (!Array.isArray(value)) return [];

  return value
    .map((location, index) => {
      const rawLocation = location && typeof location === "object" ? location : {};
      return {
        name:
          rawLocation.name ||
          rawLocation.location_name ||
          rawLocation.label ||
          rawLocation.usage ||
          `入口 ${index + 1}`,
        latitude: toFiniteNumber(rawLocation.latitude ?? rawLocation.lat),
        longitude: toFiniteNumber(rawLocation.longitude ?? rawLocation.lng),
      };
    })
    .filter(
      (location) => Number.isFinite(location.latitude) && Number.isFinite(location.longitude),
    );
}

function flattenAddresses(value) {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => (Array.isArray(item) ? item : [item])).filter(Boolean);
}

function uniqueAddresses(addresses) {
  return [
    ...new Map(
      addresses
        .filter((address) => address.fullAddress)
        .map((address) => [`${address.postalCode}:${address.fullAddress}`, address]),
    ).values(),
  ];
}

function clampInteger(value, minimum, maximum, fallback) {
  const number = Number(value);
  return Number.isInteger(number) ? Math.min(maximum, Math.max(minimum, number)) : fallback;
}

async function parseJsonResponse(response) {
  try {
    return await response.json();
  } catch {
    return {};
  }
}

function upstreamError(payload, status, fallback = "住所検索サービスでエラーが発生しました。") {
  const safeStatus = status === 404 ? 404 : status === 400 ? 400 : status === 429 ? 429 : 502;
  const safeMessage =
    safeStatus === 404
      ? "該当する住所が見つかりませんでした。"
      : safeStatus === 400
        ? "入力されたコードを確認してください。"
        : safeStatus === 429
          ? "検索が混み合っています。少し待ってから再度お試しください。"
          : fallback;

  return new DigitalAddressError(safeMessage, safeStatus, payload.error_code || "UPSTREAM_ERROR");
}
