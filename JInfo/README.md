# JInfo

日本の公的機関がトークン不要で公開する5つのAPI・データ配信を、一つの画面で検索・閲覧できるWebアプリです。

## 機能

- 防災情報をトップページに表示し、気象庁XMLの詳細を読みやすい日本語画面へ変換
- e-Gov法令API Version 2による独立した法令検索ページ
- 国土地理院タイルによる独立した地図ページと標準・淡色・航空写真切り替え
- e-GovデータポータルAPIによる独立した行政オープンデータ検索ページ
- 国立国会図書館サーチAPIによる独立した資料検索ページ
- 提供元への負荷を抑えるサーバーキャッシュとIP単位の簡易レート制限
- スマートフォン・タブレット対応、SEO、PWAメタデータ

## ローカル起動

```bash
npm start
```

`http://localhost:8080`を開きます。環境変数やAPIキーは不要です。ヘルスチェックは`GET /api/health`です。

## 検証

```bash
npm test
npm run check
```

## GCP構成

- Cloud Run: 静的UI、公開API統合バックエンド、インメモリキャッシュ
- Artifact Registry / Cloud Build: コンテナのビルドと保存
- Cloud DNS: `jinfo.rollprojects.com`

年間約2,000利用を想定し、Cloud Runは`min-instances=0`、`max-instances=2`、`256MiB`で運用します。

## デプロイ

```bash
gcloud builds submit \
  --project=rollprojects \
  --config=deploy/cloudbuild.yaml \
  --substitutions=COMMIT_SHA=manual-$(date +%Y%m%d%H%M%S)
```

## データ利用

JInfoは検索語や位置情報をデータベースへ保存しません。外部APIの検索結果はCloud Runインスタンスのメモリに短時間キャッシュされ、インスタンス終了時に破棄されます。各画面には提供元へのリンクと出典を表示しています。

国立国会図書館サーチは、`dpid=open`を指定してPDMまたはCC0で利用できるオープンメタデータだけを検索します。
