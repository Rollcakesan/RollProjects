# Port

プロフィール、SNS、作品、ショップ、振込・送金先をひとつの公開ページにまとめるWebアプリです。

## 主な機能

- アクセスごとに並び替わる公開プロフィールフィード
- 順番を保った重複なしの無限スクロール
- リンクとサービス別表示
- Simple IconsのブランドSVG表示と略称フォールバック
- プロフィール、カバー、リンクサムネイル画像
- 銀行振込、PayPay、PayPal、Wise、決済リンクなどの表示とコピー
- Googleログインによる所有者認証
- HttpOnly Cookieによる全タブ共通のログインセッション
- 初回HTMLへ認証状態を埋め込むアプリ内SPA遷移
- セクション式編集画面と折りたたみ式リンク・送金先カード
- Discoverプロフィールの短時間キャッシュと未参照画像の自動削除
- Googleアカウント単位のプロフィール一覧
- プロフィールとアップロード画像の完全削除
- 公開プロフィールのOGP・SEO・サーバーレンダリング
- モバイル・タブレット・デスクトップ対応

Portは決済を処理しません。利用者が公開した振込先・送金先を表示するだけです。

## ローカル起動

```bash
npm start
```

`PROFILE_BUCKET`を設定しない場合、プロフィールと画像は`Port/.data`に保存されます。Googleログインには`GOOGLE_CLIENT_ID`と32文字以上の`PORT_SESSION_SECRET`が必要です。

## 検証

```bash
npm run check
npm test
```

## GCP構成

- Cloud Run: Web UI、プロフィールAPI、OGPレンダリング
- Cloud Storage: 公開アクセスを禁止したプロフィールJSONと画像
- Artifact Registry / Cloud Build: コンテナのビルドと保存
- Cloud DNS: `port.rollprojects.com`

## デプロイ

```bash
gcloud builds submit \
  --project=rollprojects \
  --config=deploy/cloudbuild.yaml \
  --substitutions=COMMIT_SHA=manual-$(date +%Y%m%d%H%M%S)
```

Cloud Runは`port-runtime@rollprojects.iam.gserviceaccount.com`で実行し、プロフィール保存バケットだけに`roles/storage.objectUser`を付与します。
