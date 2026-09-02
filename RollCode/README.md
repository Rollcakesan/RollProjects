# RollCode

RollCodeは、macOS向けの小さなコードエディタです。フォルダを開き、複数ファイルをタブで編集し、同じウインドウのターミナルでコマンドを実行できます。

## 現在の機能

- フォルダツリーとファイル名フィルタ
- 複数タブ、未保存表示、保存・別名保存
- 行番号と軽量なシンタックスハイライト
- ファイル内検索と一致箇所のハイライト
- 作業フォルダを引き継ぐ内蔵zshセッション
- リサイズ可能なサイドバー、エディタ、ターミナル

## 開発

```sh
cd RollCode
xcodegen generate
open RollCode.xcodeproj
```

コマンドラインで確認する場合:

```sh
xcodebuild -project RollCode.xcodeproj -scheme RollCode -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```
