import test from "node:test";
import assert from "node:assert/strict";
import {
  DigitalAddressClient,
  DigitalAddressError,
  classifyCode,
  normalizeAddress,
  normalizeAddressQuery,
  normalizeCode,
} from "../src/digital-address-client.mjs";

test("デジタルアドレスの記号と全角文字を正規化する", () => {
  assert.equal(normalizeCode("＠ａ７ｅ－２ｆｋ２"), "A7E2FK2");
});

test("郵便番号とデジタルアドレスを分類する", () => {
  assert.deepEqual(classifyCode("100-0005"), { code: "1000005", type: "postal-code" });
  assert.deepEqual(classifyCode("100"), { code: "100", type: "postal-prefix" });
  assert.deepEqual(classifyCode("A7E-2FK2"), { code: "A7E2FK2", type: "digital-address" });
});

test("短すぎるコードを拒否する", () => {
  assert.throws(() => classifyCode("12"), (error) => {
    assert.ok(error instanceof DigitalAddressError);
    assert.equal(error.code, "INVALID_CODE");
    return true;
  });
});

test("住所検索文字列を正規化する", () => {
  assert.equal(normalizeAddressQuery("  新潟県  見附市嶺崎  "), "新潟県 見附市嶺崎");
});

test("APIレスポンスを画面用に正規化する", () => {
  assert.deepEqual(
    normalizeAddress({
      dgacode: "A7E2FK2",
      zip_code: "1000005",
      pref_name: "東京都",
      city_name: "千代田区",
      town_name: "丸の内",
      block_name: "2丁目7-2",
      latitude: null,
      longitude: "",
      business_name: "ロールプロジェクツ",
      business_name_kana: "ロールプロジェクツ",
      corporate_number: "1234567890123",
      tel_number: "0258-00-0000",
      url: "https://example.com/",
      locations: [{ name: "正面入口", latitude: "37.5", longitude: "138.9" }],
    }),
    {
      digitalAddress: "A7E2FK2",
      postalCode: "100-0005",
      prefecture: "東京都",
      city: "千代田区",
      town: "丸の内",
      block: "2丁目7-2",
      building: "",
      businessName: "ロールプロジェクツ",
      businessNameKana: "ロールプロジェクツ",
      businessNameRoman: "",
      corporateNumber: "1234567890123",
      telephone: "0258-00-0000",
      website: "https://example.com/",
      usage: "",
      fullAddress: "東京都千代田区丸の内2丁目7-2",
      kana: "",
      roman: "",
      latitude: 37.5,
      longitude: 138.9,
      locations: [{ name: "正面入口", latitude: 37.5, longitude: 138.9 }],
    },
  );
});

test("未設定時は公式サンプルをデモ検索できる", async () => {
  const client = new DigitalAddressClient({ clientId: "", clientSecret: "", demoMode: true });
  const result = await client.lookup("A7E-2FK2");

  assert.equal(result.source, "demo");
  assert.equal(result.addresses[0].prefecture, "東京都");
});

test("未設定時の任意コードは設定エラーになる", async () => {
  const client = new DigitalAddressClient({ clientId: "", clientSecret: "", demoMode: true });

  await assert.rejects(() => client.lookup("XXXXXXX"), (error) => {
    assert.equal(error.code, "API_NOT_CONFIGURED");
    assert.equal(error.status, 503);
    return true;
  });
});

test("ver2.0 APIでトークンを取得して住所を検索する", async () => {
  const requestedUrls = [];
  const fetchImpl = async (url) => {
    const requestedUrl = String(url);
    requestedUrls.push(requestedUrl);

    if (requestedUrl.endsWith("/api/v2/j/token")) {
      return Response.json({ token: "test-token", expires_in: 600 });
    }

    return Response.json({
      addresses: [
        {
          zip_code: "1000005",
          pref_name: "東京都",
          city_name: "千代田区",
          town_name: "丸の内",
        },
      ],
    });
  };
  const client = new DigitalAddressClient({
    clientId: "client-id",
    clientSecret: "client-secret",
    fetchImpl,
  });

  const result = await client.lookup("100-0005");

  assert.equal(result.source, "japan-post");
  assert.equal(result.addresses[0].fullAddress, "東京都千代田区丸の内");
  assert.equal(requestedUrls[0], "https://api.da.pf.japanpost.jp/api/v2/j/token");
  assert.match(requestedUrls[1], /^https:\/\/api\.da\.pf\.japanpost\.jp\/api\/v2\/searchcode\/1000005\?/u);
});

test("住所から郵便番号候補を検索する", async () => {
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url: String(url), options });

    if (String(url).endsWith("/api/v2/j/token")) {
      return Response.json({ token: "test-token", expires_in: 600 });
    }

    return Response.json({
      addresses: [
        {
          zip_code: "9540055",
          pref_name: "新潟県",
          city_name: "見附市",
          town_name: "嶺崎",
          pref_kana: "ニイガタケン",
          city_kana: "ミツケシ",
          town_kana: "ミネザキ",
        },
      ],
      level: 3,
      count: 1,
      page: 1,
      limit: 20,
    });
  };
  const client = new DigitalAddressClient({
    clientId: "client-id",
    clientSecret: "client-secret",
    fetchImpl,
  });

  const result = await client.searchByAddress("新潟県見附市嶺崎");

  assert.equal(result.type, "address");
  assert.equal(result.matchLevel, 3);
  assert.equal(result.addresses[0].postalCode, "954-0055");
  assert.equal(requests[1].url, "https://api.da.pf.japanpost.jp/api/v2/addresszip");
  assert.deepEqual(JSON.parse(requests[1].options.body), {
    freeword: "新潟県見附市嶺崎",
    page: 1,
    limit: 20,
  });
});
