# 問い合わせ先変更 — 2026-09-09

- ユーザー指定の @FF を問い合わせ先に設定。URL: https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/user/FF
- Accountの設定からTermsリンクとメールアドレスを削除。Privacy & supportにPrivacy PolicyとContact @FF on TAGGRを配置。初回同意画面のTermsリンクと同意処理は維持。
- 公開規約・プライバシーページからメールアドレスを削除し、プロフィールへの問い合わせリンクに変更。公開の投稿・返信と非公開のアプリ内通報を区別する案内を記載。
- 通報API・DB・表示停止処理に変更なし。Workerの9テスト成功。対象整形とdiff check成功。
- 実装者が変更箇所を確認後に公開。Worker version: 04c60945-ccfd-44b4-9755-a4cebaecc618
- PlaywrightでFFプロフィールの表示、公開プライバシー・規約のリンクとメール表示削除を確認。専用セッション終了済み。
- Swift 6 strict concurrencyの署名付きDebug実機ビルドとcodesign検証成功。
- iPhone 15、CoreDevice EF18B302-BBD0-5702-B540-9604CBA0E446へnetwork.taggr.iosを上書きインストール成功。ユーザーデータ削除なし。実機設定画面の目視・タップ検証は未実施（idbでは実機未検出）。
- SDK公開・push・タグ・TestFlight/App Store配布は未実施。
