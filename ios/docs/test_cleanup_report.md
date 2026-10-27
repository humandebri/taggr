# iOSテスト・実装整理の実施記録

## 対象と検証範囲

対象はiOSアプリ、XCTest、iOS検証スクリプト。SDK・バックエンド・通信形式・保存形式は変更していない。コミット・配布は実施していない。着手時の未コミット変更を `/private/tmp/taggr-ios-cleanup-before` に保存し、投票・下書き・監査の既存変更を基準にした。

作業中に別タスクによる検索・ブックマーク等の機能追加が同じ作業ツリーで進んだ。共有ツリーのビルドは一度、分割された `TaggrUser.swift` のXcode target未登録で失敗したため、着手時のコピーに今回の整理だけを反映した `/private/tmp/taggr-ios-cleanup-verified` で検証した。その後、別作業のtarget登録が反映された共有ツリーでもビルドと全テストを実行した。別作業のコードは変更していない。今回の整理だけの成功と統合時の失敗を以下に分けて記録する。検証ソースのハッシュは同ディレクトリの `source-manifest.json` に記録した。

## 保証の移行と処理削減

| 対象                     | 実施内容・残した保証                                                                                                                                                                                                          |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 通信fixture              | URLSession識別子とロック付きregistryでAPI・moderationを隔離。終了時にsessionと登録を破棄。署名・証明書fixtureを維持。2つのAPIを同時実行し、要求・応答が混線しないことを確認。                                                 |
| 状態と待機               | UserDefaults・Keychain・保存先をテストごとに隔離。Realmは認証済みの1件目を保留して2件目拒否と送信数1件を確認。期限切れは過去日時fixture、import競合はイベントで制御。                                                         |
| 投稿・編集・返信・repost | 直接実行テストを本番キューへ移行。送信完了と再取得完了を別々に待機。投稿先、返信先、空白、画像refs、patch、拡張、失敗時下書き維持、二重送信・アカウント変更・結果不明時の再送防止を維持。返信はsnapshot取得・反映経路へ移行。 |
| Candid                   | 実際に送信した要求を固定golden・固定期待値と比較。controller、送金先、金額、手数料、bucket引数を確認。テスト専用エンコーダを削除。                                                                                            |
| 画像・編集               | 本番変換入口へ統一し大画像反復を48MPの1枚へ集約。向き、透過、メタデータ除去、容量上限を維持。日本語IME、選択範囲、画像を含む履歴、古い非同期結果拒否を維持。                                                                  |
| 設定更新                 | ユーザー情報取得を1回に統合しwallet・storageへ利用。単独更新は自己完結。アカウント変更前の成功・失敗応答を反映しない。                                                                                                        |
| 投稿表示                 | 自動リンク変換を1回にし固定正規表現と解析済みブロックを再利用。本文・font・色・行間・Dynamic Type等が変わらなければ属性文字列を再構築しない。実表示テストでリンク・引用・文字サイズ・色の更新を確認。                         |
| 写真一覧                 | 表示評価内でgroupingを共有。永続的な表示キャッシュを追加せず制限変更を反映。                                                                                                                                                  |
| 検証コマンド             | 行数検査と呼出元、関数名・ソース断片・定型文の検査を整理。配布設定は解析結果で検証。completion/preflightの重複を除去。保留していた監査2件も追加承認後に適用済み。                                                             |

削除した旧実装: coordinatorの直接投稿・編集・repost、旧返信更新、Candidのテスト専用ラッパー、旧下書き編集API、旧画像バッチ変換入口、未使用ナビゲーションsetter・表示ヘルパー、無視される `reloadMode`、同値プロパティ。削除前に全参照を検索し、実際のSDK呼出・生成コード・自動呼出入口は維持した。

## 削除・統合・改名したテストの全一覧

以下は着手時に存在し整理後に同名で存在しない40件。保証の移行に伴う改名も含むため、40件すべてを保証の削除として数えない。各分類の理由と移行先は次のとおり。

### TaggrFeatureTests.swift

bucketの要求・応答は実通信のgolden比較へ統合。画像参照・marker操作は本文と画像データが残る履歴テストへ移行。内部キャッシュ分類、store自己代入、画像なしの自明なfilter、重複するfeed要求確認を削除。リンクと表示行数は実表示テストで確認する。

-   `testAccountImageThumbnailDecodeIsBoundedAndUsesADedicatedCache`
-   `testAccountImagesSkipPostsWithoutImages`
-   `testBucketHTTPRequestCandidMatchesWebIDL`
-   `testBucketHTTPResponseDecodesImageBody`
-   `testChildStoresKeepUnrelatedStateIndependent`
-   `testEditablePostImagesCanRemoveMarkdownReferences`
-   `testMarkdownTextKeepsPostTapSeparateWhenLinksArePresent`
-   `testPersonalFeedUsesSignedQueryWhenAuthenticated`
-   `testPostDraftDocumentInsertsAndMovesImageMarkers`
-   `testPostDraftSessionKeepsImageDataWhileTheSameBlobMarkerRemains`
-   `testTagFeedUsesPostsByTagsQuery`

### TaggrIdentityTests.swift

SDKのseed入力検証・保存セッション署名検証をアプリ側から削除。TAGGR設定、期限切れ認証、認証失敗時の状態保持をアプリの入口で確認する。

-   `testSeedPhraseRejectsEmptyInput`
-   `testStoredAuthSessionRejectsTamperedDelegationSignature`
-   `testStoredAuthSessionUsesRuntimeConfigurationAndValidSignature`

### TaggrPostPresentationTests.swift

選択範囲の整形はundo/redo重複を除いて改名。画像importの失敗・キャンセルはイベントで制御する実経路のテストへ統合。表示行数・リンク・引用はPostBodyの実表示とDynamic Typeのテストへ統合。

-   `testComposerFormatsSelectionAndUndoRedo`
-   `testImageImportFailureAndCancellationPreserveDocument`
-   `testInteractiveMarkdownLayoutStopsAtTenActualLines`

### TaggrStateTests.swift

全Realm取得と投稿先選択の重複を削除。実際のRealm取得・キュー投稿要求の検証を残す。

-   `testLoadAllRealmsListUsesAllRealmsQuery`
-   `testRootPostKeepsSelectedTimeline`

### TaggrTests.swift

SDKのPrincipal・CBOR・Request ID・署名・Keychain指定・金額型の直接検証とDIDLだけの確認を削除。Candidは送信された投稿・編集・送金・storage・bucket要求の固定golden/引数検証へ移行。エラーは必要な手数料・残高表示を確認し、storage保存は固定JSONからの復元を確認する。

-   `testBucketHeadersKeepAnonymousFieldIDsZeroAndOne`
-   `testCBORDecodesNestedByteSlice`
-   `testCBORSignedEnvelopeShape`
-   `testCMCSubaccountIdentifierUsesPrincipalSubaccount`
-   `testCandidGoldenFixtures`
-   `testCanisterStatusAcceptsAdditionalManagementFields`
-   `testGeneratedLedgerBindingsProduceCandidMessages`
-   `testICPAccountIdentifierAcceptsAccountOrPrincipal`
-   `testICPAmountParsesAndFormatsE8s`
-   `testIdentityStorePersistsOnlyMatchingRuntimeConfig`
-   `testIdentityStoreUsesWhenUnlockedKeychainProtection`
-   `testInstallBucketCodeCandidMatchesWebIDL`
-   `testLedgerTransferNestedErrorRecordsDecodeWithoutFlattening`
-   `testPostEnvelopeArrayNormalizesFeedRows`
-   `testPrincipalTextRoundTripAndRejectsBadChecksum`
-   `testRequestIdGoldenVector`
-   `testSignedEnvelopeSignatureVerifiesWithSessionPublicKey`
-   `testSignedEnvelopeUsesDelegationPublicKey`
-   `testStorageCandidEncodersProduceMessages`
-   `testStorageCreationStateRoundTripsThroughSettingsJSON`
-   `testUpdatePollingReadStateOmitsCanisterId`

## 検証結果

同一のiPhone 17 / iOS 26.5 / arm64 Simulator（UDID `A4C71745-1496-4F8A-AB5E-169AECC12430`）、Debug、並列実行なし、`test-without-building` で比較した。最終検証は前述の隔離コピーを使用した。

| 測定                              |                        着手時 |      整理後（隔離コピー） |
| --------------------------------- | ----------------------------: | ------------------------: |
| XCTest                            | 310成功・手動4スキップ・失敗0 | 282成功・スキップ0・失敗0 |
| テスト本体のduration合計          |                      78.789秒 |                  57.123秒 |
| runner起動開始から最初のsuite開始 |                       6.487秒 |                  23.335秒 |
| qrunで測ったコマンド全体          |                         144秒 |                     175秒 |
| Simulator build-for-testing       |                    成功・41秒 |                成功・97秒 |

テスト本体の合計は21.665秒（約27.5%）短縮した。一方、起動待ちや終了処理等を含む総時間は31秒増加した。起動の値はXcode activity logの内側の `Launch TAGGRTests` 開始からsuite開始までで、OS単体のアプリ起動性能を示すものではない。各1回の計測で、別作業の負荷やDerivedDataの違いもあるため、総所要時間の改善は確認できたとは言えない。ビルド時間もキャッシュ条件が異なるため速度比較には使わない。

最終結果は `/private/tmp/taggr-ios-cleanup-verified/final-tests.xcresult`、集計値は同ディレクトリの `summary.json`、`test-tree.json`、`action-log.json` に保存した。

共有Web/iOS fixture: Markdown 14件・画像4件が成功。`swift-audit`、`review-preflight`、`local-aasa-check`、`bash -n scripts/test_ios_candid.sh`、`make format`、`cargo check --tests`、`cargo fmt --check`、`git diff --check`、未変更の `local-frontend-check` は成功。`ios:completion`（preflight、Simulator build、local AASA、reviewを含む）も成功した。最初は別タスクのビルドとbuild.dbが競合したため、独立した `IOS_DERIVED_DATA_PATH` で再実行し216秒で完了した。formatによる要求外の差分は残していない。

途中の失敗は、再取得Taskがテスト終了後まで残る問題、Dynamic Typeのfont取得、統合後のundo期待値、schemeのarchitecture指定を修正して再検証した。着手時の通常XCTestに失敗はなく、既存失敗を削除で隠していない。

### 別作業を含む共有ツリーの統合検証

2026-09-13 18:13〜18:15 JST実行時点の記録。Simulator `build-for-testing` は成功（95秒）。通常schemeは289件中287件成功、2件失敗、スキップ0。テスト本体58.087秒、runner起動からsuite開始12.371秒、コマンド全体146秒。同じ `.build/xcode` を使用したが、別作業の機能とテスト7件が追加されているため、今回の整理だけの速度比較とは区別する。

-   `TaggrParityTests.swift:51` の `testParityProfileAndLinksAPIContract`: 別作業で追加されたプロフィール・リンクAPIテスト。66 bytes同士の要求データ比較が不一致。
-   `TaggrTests.swift:30` の `testTokenAndWalletRoutesOpenAccount`: `/transactions` の期待値 `.settings` に対して `nil`。別作業でルートが `/transactions/<account>` に変更され、アカウントなしの既存テストと不一致になっている。

結果は `/private/tmp/taggr-ios-cleanup-integrated.xcresult`、集計は `/private/tmp/taggr-ios-cleanup-integrated-metrics` に保存した。2件を削除・期待値変更で隠さず、別作業の仕様確定と修正・再検証が必要な事項として残した。

## 未実施・保留

-   最新共有ツリーとの統合ビルド・全テストは、別作業のtarget登録完了後に必要。
-   `idb` の対象検出は成功したがXCTest起動はcompanionの接続断で失敗したため、同じ明示UDIDで `xcodebuild` を使用した。
-   手動確認4件と実機確認は未実施。通常schemeは4件を明示除外し、`TAGGR-ManualReview` のみ専用起動引数を設定。実行方法は [manual_review.md](manual_review.md) を参照。
-   `blockers.js` の文書内PASS検査、`local-frontend-check.js` のbundle内定型文検査の削除は、ユーザーの追加承認を受けて適用済み。前者は手動確認の案内を出し、既存の外部検査と失敗時の終了コードを維持する。後者はJavaScript構文解析へ置き換え、空・空白のみ・破損・欠損・構文不正bundleを拒否する。実際のdist検査と6ケースの限定検証が成功。blockersの分岐は外部コマンドを模擬して成功・失敗を確認し、本番への検査は実施していない。
