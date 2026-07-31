# デジタルアドレスマップ

日本郵便の「郵便番号・デジタルアドレスAPI」とGoogle Maps Platformを組み合わせ、7桁のコードから住所と地図を表示するWebアプリです。

## 機能

- デジタルアドレス・郵便番号の自動判定と正規化
- 日本郵便APIのトークン取得・キャッシュ・住所検索
- Google Maps上への住所表示
- 住所コピー、共有URL、Google マップへの遷移
- 端末内だけに保存する検索履歴
- IP単位の簡易レート制限と結果キャッシュ
- スマートフォン・タブレット対応

## ローカル起動

```bash
cp .env.example .env
set -a && source .env && set +a
npm start
```

`http://localhost:8080`を開きます。日本郵便APIの資格情報がない場合、公式リファレンスに掲載されている3件のデジタルアドレスと郵便番号サンプルだけをローカルデモデータで検索できます。

ヘルスチェックは`GET /api/health`です。

## 環境変数

| 名前 | 用途 |
| --- | --- |
| `GOOGLE_MAPS_BROWSER_KEY` | Maps JavaScript API用ブラウザーキー |
| `JAPAN_POST_CLIENT_ID` | 日本郵便APIクライアントID |
| `JAPAN_POST_CLIENT_SECRET` | 日本郵便APIシークレットキー |
| `JAPAN_POST_API_BASE_URL` | APIベースURL。既定は本番環境 |
| `JAPAN_POST_SOURCE_IP` | トークン要求の`x-forwarded-for`値 |
| `DEMO_MODE` | 資格情報未設定時のサンプル検索。既定は`true` |

日本郵便の資格情報はCloud Runの平文環境変数には設定せず、Secret Managerから注入してください。Google Mapsブラウザーキーは公開される前提で、HTTPリファラーと利用APIを制限します。

## 検証

```bash
npm test
npm run check
```

## GCP構成

- Cloud Run: 静的UIとバックエンドAPI
- Secret Manager: 日本郵便API資格情報
- Maps JavaScript API: 地図表示とジオコーディング
- Artifact Registry / Cloud Build: コンテナのビルドと保存
- Cloud DNS: `daddressmap.rollprojects.com`

年間約2,000利用を想定し、Cloud Runは`min-instances=0`、`max-instances=2`、`256MiB`で運用します。

## デプロイ

```bash
gcloud builds submit \
  --project=rollprojects \
  --config=deploy/cloudbuild.yaml \
  --substitutions=COMMIT_SHA=manual-$(date +%Y%m%d%H%M%S)
```

初回は必要API、Artifact Registry、IAM、APIキー、Secret Managerを先に設定します。

## データ取り扱い

検索コードと住所はアプリのデータベースへ保存しません。直近の検索履歴はブラウザーの`localStorage`だけに保存します。バックエンドの結果キャッシュはインメモリで、インスタンス終了時に破棄されます。

## 公式資料

- [郵便番号・デジタルアドレスAPI](https://guide-biz.da.pf.japanpost.jp/api/)
- [APIリファレンス](https://biz.da.pf.japanpost.jp/apireference/digiadd-swagger-biz.html)
