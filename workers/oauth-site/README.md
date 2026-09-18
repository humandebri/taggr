# TAGGR iOSの通報・表示停止

既存Workerに通報受付と表示停止リスト配信だけを追加します。D1は1つ。専用管理画面、Access、メール送信、cron、アプリ全体の利用停止はありません。

## API

-   `POST /api/reports`: `{id, canisterID, userID, postID?, reason}`。UUID v4、対象IDは非負整数、理由1〜2000 Unicodeコードポイント、本文8KB以下。保存成功時に201 `{id,status:"received"}`。同一ID・同一内容の再送は成功、内容違いは409。認証不要・自動制限なし。
-   `GET /api/moderation?canisterID=...`: `{canisterID,version,postIDs,userIDs}`。成功応答はキャッシュ禁止。判断理由・通報本文は公開しません。別canisterや不正応答はiOSが採用しません。
-   通報はWorker標準のrate limiterでIPごと・Cloudflare拠点ごとに1分10回に制限します。共有回線で制限を共有する場合があります。厳密な全世界合計ではありません。IPはD1へ保存しません。標準仕様: https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/

## ローカル検証

```sh
npm test
npm run check
node node_modules/wrangler/bin/wrangler.js d1 migrations apply taggr-ios-moderation-local --env local --local
node node_modules/wrangler/bin/wrangler.js dev --env local --local --port 8791
```

ローカル環境は本番ドメインを継承しません。ローカル用DBだけを使用します。

## 運営者の操作

本番操作は承認された運営者が、既存Wrangler認証で実行します。通常の利用者やiOSアプリにDB管理権限は渡しません。まずローカルで確認し、本番では明示的に`--remote`を指定します。

```sh
node scripts/moderate.mjs --local list
node scripts/moderate.mjs --local show REPORT_UUID
node scripts/moderate.mjs --local hide 6qfxa-ryaaa-aaaai-qbhsq-cai post 42 '原文を確認した判断理由'
node scripts/moderate.mjs --local restore 6qfxa-ryaaa-aaaai-qbhsq-cai post 42 '解除理由'
node scripts/moderate.mjs --local close REPORT_UUID
node scripts/moderate.mjs --local history
```

`user`を指定するとそのユーザーのコンテンツを公式iOSアプリで非表示にします。ログインやウォレットは停止しません。`list`は最も古い未対応100件を表示し、対応完了から90日を超えた通報を削除します。100件が埋まっている場合は古い通報から処理して再取得します。`history`は直近100件の停止・解除を表示します。判断は追記形式で理由と時刻を残します。

運営者は毎日確認し、24時間以内に対応します。対象ID・作者・原文を確認してから停止を判断し、必要な対応を終えてから`close`します。通報件数だけで自動停止しません。履歴・通報理由は端末や共有ログへ不用意に転載しません。

## iOS

起動・復帰時と使用中60秒ごとにリストを取得します。成功したリストを端末へ保存し、停止・解除を表示中のコンテンツへ反映します。取得失敗時は以前のリストを保持し、初回失敗でもアプリを使い続けられます。新たな停止・解除の反映は通信復旧まで遅れます。規約同意・個別ブロック・NSFW非表示は独立して維持します。

## 公開前

1. 差分・対象テスト・実機用ビルドをレビューし、本番設定と公開の明示承認を得る。
2. 対象はWorker `taggr-oauth-site`、account `9029b5f9de5b2e820eaf4ed562bcb0e7`、ホスト `taggr.kasane.network`。専用D1 `taggr-ios-moderation` を新規作成して返されたdatabase_idを本番バインディングへ設定する。既存DBは流用しない。
3. rate limiter namespace `2026090901` が他用途に使われていないことを確認する。キーにも専用接頭辞を付けている。本番スキーマ適用とWorker公開を行い、APIと運営CLIを実データで検証する。テスト対象以外を停止しない。
4. APIの動作確認後にiOSへ反映し、通常利用・通報・非表示・解除を実機で確認する。署名・通信・Keychainは既存ICNativeClientを使用する。

公開前のWrangler dry-run成功は、本番D1の設定完了を意味しません。Workerを以前の版に戻すと通報は失敗し、新しい停止・解除が配信されなくなりますが、iOSの通常利用は止まりません。ロールバック時もD1の通報・判断記録を削除しません。
