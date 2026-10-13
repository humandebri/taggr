# iOSの手動確認

通常の共有scheme `TAGGR` は、下記4件を明示的に除外する。`TAGGR-ManualReview` は同じXCTest targetから4件だけを選択し、専用起動引数を設定する。通常テストの実行時間に、人の操作を待つ時間は含めない。

| 確認対象     | テスト                              |
| ------------ | ----------------------------------- |
| 認証         | `testSeedPhraseInteractiveUIReview` |
| プロフィール | `testProfileInteractiveUIReview`    |
| 通報         | `testModerationReportInteractiveUI` |
| Inbox        | `testInboxRetryInteractiveUI`       |

`idb list-targets --json` で対象UDIDを確認し、Xcodeで `TAGGR-ManualReview` schemeを選び、上表のテストを1件ずつ実行する。CLIから実行する場合も `-only-testing` で必ず1件を指定する。

```sh
qrun -- xcodebuild test \
  -project ios/TAGGR/TAGGR.xcodeproj \
  -scheme TAGGR-ManualReview \
  -destination 'platform=iOS Simulator,id=<対象UDID>' \
  -derivedDataPath .build/xcode \
  -parallel-testing-enabled NO \
  -only-testing:TAGGRTests/TaggrTests/testSeedPhraseInteractiveUIReview
```

表示された画面を操作し、確認した内容・実行日・端末・結果を記録する。テストの終了や文書中の `PASS` 表記だけでは、手動確認の完了を判定しない。
