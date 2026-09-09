# フレーズログイン：公開前レビュー

## 結果

TAGGRとICNativeClientの実装・検証・実装担当によるコードレビューを完了。今回の認証差分に未解消のレビュー指摘はありません。公開・push・タグ作成・アプリ配布は実施していません。

アプリ全体の配布準備には、比較環境でも再現した既存テスト15件の解消、本番の既存アカウントでの実機確認、所有者の明示承認、ライブラリ公開後の依存固定と再検証が残ります。

## レビュー対象と修正

- TAGGRが入力したフレーズをそのままUTF-8にし、SHA-256を15,000回適用。フレーズ処理はTAGGR内にあります。
- ICNativeClientの公開APIは32バイトのEd25519鍵を受け取り、ランダムなセッション鍵への署名済み委任を作成。ルート公開鍵がPrincipalを決定し、ルート秘密鍵は返却・保存されません。
- 既存の署名、委任先、有効期限、Keychainアクセス制御、証明書検証を使用。TAGGRのセッションは30日間で、期限切れ後はフレーズの再入力が必要です。
- 署名付きユーザー照会で既存アカウントを確認し、Keychain保存後に状態を反映。新規登録には進みません。保存・通信・照会失敗とキャンセルでは既存の状態を維持します。
- レビュー中に、新しいテストがホームフィード設定を残す点を修正。テスト終了時に以前の設定を復元し、認証11件を再実行しました。
- 結合テストで発見した既存の証明書fixtureのサブネットID不整合は、ルート鍵からIDを導出するよう修正。証明書検証は変更していません。

## 検証結果

| 検証 | 結果 |
| --- | --- |
| ICNativeClient `swift test` | 成功 |
| Swift 6 strict concurrency / warnings-as-errors | 成功 |
| iOS Debug結合ビルド | 成功 |
| iOS Releaseビルド、署名なし | 成功 |
| 最終認証テスト | 11件成功、失敗なし |
| テスト用データでの実画面操作 | 成功。選択、空入力無効化、誤入力エラー、キャンセル後の消去、正しいフレーズでのログイン |
| Playwright CLIによるWeb画面確認 | password入力欄で前後の空白・日本語・絵文字を保持。送信なし |
| iOS全体テスト | 246件成功、16件失敗 |
| 機能を除いた比較コピー | 239件成功、15件失敗。変更後の15件と一致 |
| 残りの1秒タイムアウトの単独再実行 | 成功。`testEnqueuedPostFinishesBeforeBackgroundReconciliation` |
| `cargo check` / 差分空白チェック / 対象文書の整形 | 成功 |

比較コピーは同じローカルICNativeClient（0.7.6ベース）と既存の作業中コードを使い、今回のフレーズ機能を除いたものです。正しいサブネットIDを使うテストfixtureは双方で共通です。0.7.5の配布版との全面的な比較ではありません。

ネイティブ操作対象はiPhone 17 Simulator、UDID `29047A70-52E0-4A50-971A-24E4F94C8C1E`。本番接続では既存の安全性ポリシー取得が失敗するため、XCTestでテスト用APIと安全性ポリシーを注入して実際のRootViewを表示し、idbで操作しました。実在する本番アカウントの認証情報は使用していません。

`idb xctest install` は接続エラーとなったため、テスト起動にはXcodeのxctestrunを使用しました。画面操作にはidbを使用しています。通常の自動テストでは対話用テストを除外し、対話用テストは起動引数 `--seed-phrase-ui-review` を指定した場合だけ動きます。

全体の静的監査には、既存の `CandidEncoder.swift` 参照、YouTube用WebKit検出、既に上限を超えているファイルの行数違反が残ります。前段で実行した `make format` は保護されたスキル・生成物への書込みで失敗したため、今回は変更対象文書を個別整形して確認しました。

### 比較環境でも再現した15件

- `testEditPostPassesPatchAndReloadsCurrentRoute()`
- `testEditPostUploadsImageBeforeEditPost()`
- `testEnqueuedPostDoesNotRefreshStaleFeedRoute()`
- `testEnqueuedPostKeepsRetryableAndUncertainDrafts()`
- `testFailedAndReplyPostsDoNotUpdateRealmPostingPreferences()`
- `testImagePostKeepsEnqueuedAPIWhenSessionChangesDuringUpload()`
- `testLedgerTransferNestedErrorRecordsDecodeWithoutFlattening()`
- `testPollHidePinAndDeleteUsePostUpdateMethods()`
- `testPostDraftDocumentInsertsAndMovesImageMarkers()`
- `testPostNavigationWithoutRecordedReturnUsesCurrentHomeFeed()`
- `testRealmFeedDoesNotReplaceLastHomeMode()`
- `testReplyPostPassesParentAndRefreshesDirectReplies()`
- `testRepostPassesExtensionBlob()`
- `testSubmitPostFromTagFeedReloadsTagFeed()`
- `testSubmitPostPassesRealmAndReloadsRealmFeed()`

## 確認用差分と再現方法

- [TAGGRの今回の変更](taggr.patch)
- [ICNativeClientの変更](icnativeclient.patch)
- [レビュー対象ファイルのSHA-256](source-sha256.json)
- [最終認証テスト](final-auth-tests.json)
- [画面操作テスト](ui-review.json)
- [全体テスト](full-suite.json)
- [比較テスト](baseline-suite.json)

検証用workspaceは `artifacts/seedphrase-validation/TAGGR.xcworkspace`。ローカルの `/Volumes/KINGSTON/ICP/ICNativeClient` を参照します。これは配布用の設定ではありません。

```sh
xcodebuild test \
  -workspace artifacts/seedphrase-validation/TAGGR.xcworkspace \
  -scheme TAGGR \
  -destination 'platform=iOS Simulator,id=29047A70-52E0-4A50-971A-24E4F94C8C1E' \
  -skipPackagePluginValidation \
  -skip-testing:TAGGRTests/TaggrTests/testSeedPhraseInteractiveUIReview
```

配布用プロジェクトはまだICNativeClient 0.7.5固定で、新APIを含みません。そのため、現時点の認証変更をビルドする際は検証用workspaceを使用してください。所有者の明示承認後、レビュー済みライブラリを公開し、その公開版へ依存を固定して通常のプロジェクトでも再ビルド・再検証します。アプリ配布には別途、承認された範囲と配布前の検証完了が必要です。
