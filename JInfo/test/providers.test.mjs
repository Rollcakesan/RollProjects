import test from "node:test";
import assert from "node:assert/strict";
import { ProviderError, normalizeLimit, normalizeQuery, parseAtomFeed, parseNdlFeed, parseWeatherDetail, searchMapPlaces } from "../src/providers.mjs";

test("normalizeQuery trims and normalizes spaces", () => {
  assert.equal(normalizeQuery("  個人\n 情報  "), "個人 情報");
});

test("normalizeQuery rejects short searches", () => {
  assert.throws(() => normalizeQuery("a"), ProviderError);
});

test("normalizeLimit applies defaults and caps large values", () => {
  assert.equal(normalizeLimit(undefined), 25);
  assert.equal(normalizeLimit("50"), 50);
  assert.equal(normalizeLimit("999"), 100);
});

test("searchMapPlaces maps GSI GeoJSON features", async () => {
  const result = await searchMapPlaces("見附市", async () => new Response(JSON.stringify([{
    geometry: { coordinates: [138.927277, 37.521152], type: "Point" },
    properties: { addressCode: "", title: "新潟県見附市嶺崎二丁目２番３号" },
    type: "Feature",
  }]), { status: 200 }));
  assert.equal(result.results[0].title, "新潟県見附市嶺崎二丁目２番３号");
  assert.equal(result.results[0].lat, 37.521152);
  assert.equal(result.results[0].lng, 138.927277);
});

test("parseAtomFeed extracts weather entries", () => {
  const result = parseAtomFeed(`
    <feed xmlns="http://www.w3.org/2005/Atom">
      <updated>2026-08-01T00:00:00Z</updated>
      <entry>
        <title>震源・震度に関する情報</title>
        <updated>2026-08-01T00:01:00Z</updated>
        <author><name>気象庁</name></author>
        <link type="application/xml" href="https://example.test/quake.xml" />
        <content type="text">最大震度3を観測しました。</content>
      </entry>
    </feed>
  `);
  assert.equal(result.updatedAt, "2026-08-01T00:00:00Z");
  assert.equal(result.entries[0].category, "地震");
  assert.equal(result.entries[0].publisher, "気象庁");
  assert.equal(result.entries[0].url, "https://example.test/quake.xml");
});

test("parseNdlFeed extracts open bibliographic metadata", () => {
  const result = parseNdlFeed(`
    <rss xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:openSearch="http://a9.com/-/spec/opensearchrss/1.0/" xmlns:dcterms="http://purl.org/dc/terms/">
      <channel>
        <openSearch:totalResults>25</openSearch:totalResults>
        <item>
          <title>吾輩は猫である</title>
          <link>https://ndlsearch.ndl.go.jp/books/example</link>
          <description><![CDATA[<ul><li>タイトル：吾輩は猫である</li><li>責任表示：夏目漱石</li></ul>]]></description>
          <dc:creator>夏目漱石</dc:creator>
          <dc:publisher>架空出版社</dc:publisher>
          <dcterms:issued>1905</dcterms:issued>
          <dc:identifier>978-1-234567-89-0</dc:identifier>
          <category>図書</category>
        </item>
      </channel>
    </rss>
  `);
  assert.equal(result.total, 25);
  assert.equal(result.items[0].title, "吾輩は猫である");
  assert.equal(result.items[0].creator, "夏目漱石");
  assert.match(result.items[0].description, /責任表示/);
});

test("parseWeatherDetail creates readable groups from JMA XML", () => {
  const result = parseWeatherDetail(`
    <Report>
      <Control><Title>土砂災害警戒情報</Title><PublishingOffice>気象庁</PublishingOffice></Control>
      <Head>
        <Title>新潟県土砂災害警戒情報</Title>
        <ReportDateTime>2026-08-01T03:07:00+09:00</ReportDateTime>
        <InfoType>発表</InfoType><InfoKind>土砂災害警戒情報</InfoKind>
        <Headline>
          <Text>安全な場所へ避難してください。</Text>
          <Information type="警戒地域"><Item><Kind><Name>警戒</Name></Kind><Areas><Area><Name>見附市</Name></Area><Area><Name>長岡市</Name></Area></Areas></Item></Information>
        </Headline>
      </Head>
      <Body><Comment><Text>崖や谷の近くでは特に注意してください。</Text></Comment></Body>
    </Report>
  `);
  assert.equal(result.title, "新潟県土砂災害警戒情報");
  assert.equal(result.publisher, "気象庁");
  assert.equal(result.informationGroups[0].type, "警戒地域");
  assert.deepEqual(result.informationGroups[0].entries[0].areas, ["見附市", "長岡市"]);
  assert.equal(result.notes[0], "崖や谷の近くでは特に注意してください。");
});
