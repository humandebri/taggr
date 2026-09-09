# 本番公開記録 — 2026-09-09

ユーザーの明示承認後、レビュー済みWorkerと専用D1を公開した。

- 対象: `taggr-oauth-site`、既存 `https://taggr.kasane.network`
- account: `9029b5f9de5b2e820eaf4ed562bcb0e7`
- 旧Worker: `4928253c-f1eb-4f79-85f6-a6dc4358a173`
- 新Worker: `9dce32c9-cfa5-436b-abc7-a3a21d804455`
- D1: `taggr-ios-moderation` / `352d9c96-1ed6-4542-b736-a86f097b6b26`（APAC）
- migration: `0001_moderation.sql` 適用成功
- bindings: `MODERATION_DB`、`REPORT_LIMITER`（namespace `2026090901`、10回/60秒）
- 契約変更、追加DNS、Access、メール送信設定なし。既存契約でリソース作成・公開成功。請求額や従量課金額がゼロであることは保証していない。

## 検証

- 実DB UUIDを設定したdry-run成功。レビュー後のコード変更なし。設定のUUID追加だけを確認し、deployment-sha256.jsonに公開時ハッシュを記録。
- 本番GET一覧200、POST通報201、同一ID再送201、CLIによる保存確認成功。
- 連番の実在投稿に影響しない最大安全整数ID `9007199254740991` をテスト対象にhide→一覧反映→restore→解除を確認。最終一覧はversion 2、停止対象なし。
- テスト通報 `ae5a9b2a-e655-4ae3-80bb-d0318b23f054` はclose済み。判断履歴は監査用に保持。実行記録はproduction-smoke.json。
- GET /api/reportsは405で非公開。公開一覧に通報本文や理由が含まれないことを確認。
- Playwright Chromiumでトップ・プライバシー・利用規約の導線と新しい記載を確認。専用セッションmodprod終了済み。
- git diff --check成功。公開バージョンの実bindingsをWranglerで再確認。

## 残る作業

iOS実機への更新は未実施。旧実機ビルドは旧APIを参照するため、今回のWorker公開だけではiOS側の修正は反映されない。実機での全タブ・通報・停止・解除の確認は残る。SDK公開、push、タグ、TestFlight/App Store配布は実施していない。

運営者はCLIで通報を確認し24時間以内に対応する。自動通知は設けていない。

## ロールバック

必要時は旧Workerバージョンへ戻す。D1と記録は削除しない。その場合、新iOSの通報受付と一覧更新が止まり、保存済み一覧が保持される。ロールバック自体は未実施。
