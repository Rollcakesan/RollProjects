# RollProject

雑記・知識・記録をMarkdownで投稿し、番号付き返信で育てるテキスト限定のスレッド型記事サイトです。

## 機能

- GoogleログインとHttpOnly Cookieセッション
- 一意なユーザーIDと `/{ユーザーID}/{記事ID}` の公開URL
- Markdown対応のテキスト記事、著者による再編集
- 2番から続く番号付き返信スレッド
- 最終返信順の新着一覧とユーザー別記事一覧
- 本文を対象にしない、タイトル限定検索
- Cloud Run、Firestore、モバイル表示に対応

## ローカル起動

```bash
npm install
ROLLPROJECT_SESSION_SECRET=development-secret-at-least-32-characters \
GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com \
npm start
```

Cloud Run以外では `RollProject/.data/store.json` に保存します。Googleログインを実際に使う場合、OAuthクライアントの承認済みJavaScript生成元へローカルURLを登録してください。

## 検証

```bash
npm run check
npm test
```

## GCP

Cloud RunではFirestoreを使用します。実行サービスアカウントに `roles/datastore.user`、Secret Managerのセッション秘密鍵へのアクセスを付与します。`firestore.indexes.json` の複合インデックスも事前に反映してください。

```bash
gcloud firestore indexes composite create \
  --project=rollprojects \
  --database='(default)' \
  --collection-group=articles \
  --field-config=field-path=userId,order=ascending \
  --field-config=field-path=createdAt,order=descending

gcloud builds submit \
  --project=rollprojects \
  --config=deploy/cloudbuild.yaml \
  --substitutions=COMMIT_SHA=manual-$(date +%Y%m%d%H%M%S)
```

本番公開前に `rollproject-runtime` サービスアカウント、`rollproject-session-secret`、Firestoreデータベース、Google OAuthの承認済み生成元を用意します。ルートドメインのCloud Runドメインマッピングは既存サービスへの影響を確認してから切り替えてください。
