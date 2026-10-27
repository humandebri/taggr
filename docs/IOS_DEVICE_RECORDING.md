# 実機動画の撮影手順：iPhoneミラーリング＋screencapture

## 成功実績と今回の状況

2026年9月4日のDreamVault作業で、iPhone 15 / iOS 26.6.1の画面をこの方法で録画した。操作はMacのiPhoneミラーリング、録画はmacOSの `screencapture` によるウインドウ指定で行った。idbやQuickTimeのUSB画面入力を使った方法ではない。

-   セッション：`01a0324d-70e2-72f3-ab47-e42e5d472106`（Apple StoreのUI改善方針を整理）
-   完成動画：`/Volumes/KINGSTON/dreamvault/ios/AppStore/Review/DreamVault-AppReview-iPhone15-iOS26.6.1-final.mov`
-   成功時の収録コマンド：`screencapture -v -V26 -x -l42080 .../DreamVault-AppReview-iPhone15-iOS26.6.1-clean.mov`

2026年9月14日のTAGGR撮影では、録画パネルの操作とQuickTimeのUSB入力を試したが、このCLI方式はまだ再検証していない。USB入力とミラーリングの併用では、QuickTime側にロック画面が映った。この結果は、ミラーリングのウインドウ自体を録画できないことを意味しない。

## 1. 撮影準備

1. 対象の実機とアプリのビルドを確認する。端末確認はプロジェクト規則に従い `idb list-targets --json` から始める。idbが実機を認識しないことと、この録画方式の可否は別問題。
2. MacでiPhoneミラーリングを開き、対象のiPhoneを接続する。本体をロックし、Mac側に操作可能なアプリ画面が映ることを確認する。
3. QuickTimeのUSB画面録画は併用しない。Mac上のミラーリングウインドウを収録対象にする。
4. テストアカウント、撮影開始画面、撮影時間を準備する。パスワードは伏せ字にし、通知など撮影対象外の情報が映らないことを確認する。

## 2. 現在のウインドウIDを取得する

前回の `42080` は再利用しない。ミラーリングを開き直すとIDが変わるため、その都度取得する。

以下は前回使ったCoreGraphicsによる一覧取得を、ミラーリングだけに絞ったもの。Swiftが利用できるMacのターミナルで実行する。

```sh
swift -module-cache-path /private/tmp/taggr-recording-swift-cache -e '
import Foundation
import CoreGraphics
guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else { exit(2) }
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    if owner == "iPhoneミラーリング" || owner == "iPhone Mirroring" {
        print(window[kCGWindowNumber as String] ?? "",
              window[kCGWindowBounds as String] ?? "")
    }
}
'
```

出力のIDとウインドウ寸法から、本体画面を表示しているウインドウを選ぶ。候補が複数ある場合は、録画前に対象を確認する。権限不足や空の一覧を、対象が存在しない証拠とは扱わない。

## 3. 時間指定で録画する

次の `CURRENT_WINDOW_ID` を確認済みの数値に置き換える。出力先は未使用のファイル名にする。

```sh
taggr_window_id=CURRENT_WINDOW_ID
taggr_video_path="$PWD/ios/DerivedData/retirement-recording/TAGGR-deletion-confirmation.mov"
mkdir -p "$(dirname "$taggr_video_path")"
screencapture -v -V60 -x -l"$taggr_window_id" "$taggr_video_path"
```

-   リポジトリのルートで実行する。
-   `-v` は動画、`-V60` は60秒の収録時間、`-l` は対象ウインドウID。
-   実行中にミラーリングを操作する。エージェントの端末ツールでは短い初回待機時間で実行し、返された実行セッションを保持したままUI操作へ進む。
-   前回はCtrl-C停止で動画が保存されなかった。固定時間で自動終了させ、正常終了とファイル生成を確認する。
-   この手順を実行する際も、そのセッションの画面収録権限・ツール制約に従う。過去の成功記録は権限やツール制約を上書きしない。

## 4. TAGGRの撮影範囲

今回の依頼は「既存デモアカウントで、退会直前まで。実際には退会しない」。

1. サインインを動画に含める場合は、録画開始後にサインインする。すでにログイン済みの動画を、サインインを含む動画と説明しない。
2. Account画面でテストアカウントと必要クレジットを表示する。
3. Account内の最初の「Delete account」を開き、最終確認の説明を表示する。
4. **最終確認内の「Delete account」は押さない。** 説明を読める時間を確保し、録画の自動終了を待つ。

この動画は「最終確認まで」であり、退会完了を示す動画ではない。撮影のためのクレジット消費、プロフィール変更、停止API実行は行わない。

## 5. 保存した動画を確認する

ファイルの存在だけで成功としない。QuickTimeなどで冒頭・画面遷移・末尾を再生し、ロック画面や静止した画面だけになっていないことを確認する。

ffprobeが利用できる場合は、長さ・サイズ・映像形式も確認する。

```sh
ffprobe -v error \
  -show_entries format=duration,size \
  -show_entries stream=codec_name,width,height \
  -of default=noprint_wrappers=1 "$taggr_video_path"
```

前回は保存後にffmpegでH.264・30fpsへ変換し、再生検証を行った。今回も変換が必要な場合のみ、元動画を保持して別名で出力する。

```sh
ffmpeg -v error -i "$taggr_video_path" \
  -vf fps=30 -c:v libx264 -preset medium -crf 18 \
  -pix_fmt yuv420p -movflags +faststart -an \
  "${taggr_video_path%.mov}-final.mov"
```

## つまずいた場合

| 症状                        | 確認すること                                                   |
| --------------------------- | -------------------------------------------------------------- |
| ミラーリングが接続できない  | 本体がロックされているか、対象端末が正しいか                   |
| QuickTimeにロック画面が映る | USB入力を録画していないか。本手順はMac側のウインドウを録画する |
| 別のウインドウが録画される  | IDを取り直し、対象ウインドウを確認する                         |
| 動画が保存されない          | Ctrl-C等で中断せず、指定時間の正常終了を待ったか               |
| idbに実機が出ない           | idbの問題として切り分ける。本手順はidbの録画機能に依存しない   |
| 画面収録の権限エラー        | 実行環境の権限と承認規則を確認し、制約を迂回しない             |
