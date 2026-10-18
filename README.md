# Sumire for iOS — 開発中

完全オフラインの日本語キーボードを iOS / iPadOS 18 以降へ移植しています。現在は開発・検証用の実装であり、日常利用版の完成条件は満たしていません。アプリと拡張にネットワーク処理を実装しない方針です。

## ブランチと並列開発

- `dev`：開発の統合先・リポジトリの既定ブランチ。
- `main`：検証した安定版。`dev → main` のリリース PR で反映します。
- 機能ごとに `dev` から作業ブランチと worktree を作成し、`dev` 向けの PR を提出します。親担当がレビュー・依存関係・統合テストを管理します。
- 生成辞書、ビルド出力、スクリーンショット、検証ログはリポジトリ外へ保存します。詳細は [AGENTS.md](AGENTS.md) を参照してください。

## 構成

- `ConversionCore/`：C++20、メモリマップ辞書、Viterbi / N-best、C ABI、JSON CLI。
- `Core/`：Swift の入力状態、配列、取り込み・保存、学習・バックアップ、文節投影など。
- `Shared/`・`Keyboard/`：UIKit 入力面とキーボード拡張。
- `App/`：SwiftUI 設定と UITextView 入力テスト画面。
- `Scripts/`：辞書生成、CLI 起動、アイコン生成、オフライン処理のソース検査。

システム辞書、30分類、英語辞書の生成・CLI 検索を実装しています。各配列の基本入力、候補、学習、設定・編集画面を開発中です。文節境界・文節選択モデル、基準色からの配色モデルには直接テストがありますが、モデルの存在だけで実入力画面との接続完了とは扱いません。

## 辞書の準備

CMake、C++20 コンパイラ、zlib、Python 3、Git が必要です。macOS では Unicode 処理に CoreFoundation、それ以外では ICU を使います。生成資産はコミットしません。

辞書生成元は次の固定リビジョンです。参照コピーを変更せず使用してください。

```sh
git clone https://github.com/KazumaProject/JapaneseKeyboard.git .reference/JapaneseKeyboard
git -C .reference/JapaneseKeyboard checkout --detach df1f38315bf56d860d32919a3eaed6a75499e91e
./Scripts/sumire-cli --setup
```

標準生成先は `$HOME/sumire-data/cli-priority-v1`、ビルド先は `$HOME/sumire-build/cli-release` です。`SUMIRE_CLI_DATA_DIR` / `SUMIRE_CLI_BUILD_DIR` で変更できます。生成先に既存の辞書がある場合、CLI ラッパーは再生成しません。別世代を作る場合は、空の出力先を指定します。

```sh
python3 Scripts/build_dictionary.py --english --english-reading \
  --output "$HOME/sumire-data/cli-next"
```

v5の単独読み優先辞書も検証して`standalone.sud`へ変換します。優先フラグはスコアと独立しており、分類辞書の完全一致はN-best件数とは別に統合します。同点の主候補はUTF-16の表記順です。CLIの`standalone_priority_available`で搭載を確認できます。旧辞書は読めますが、この値がfalseのとき単独読み優先は利用できません。システムv3/v4の文節経路優先と数値N-gram補正は未実装です。

入力・出力のハッシュ、出典とライセンス通知は生成先の `manifest.json` と `licenses/` に保存します。各辞書の条件はプログラムのライセンスと別に確認が必要です。特に英語データの適用ライセンスには未確認事項があり、配布条件の確認完了を意味しません。

配列の追従用として JapaneseKeyboard dev `9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93`、変換参照として kotlin-kana-kanji-converter `d5bcefcf613b238966242a2aac3771ef9a18e12d` も使用しています。辞書生成元の固定リビジョンとは区別します。

## CLI

```sh
./Scripts/sumire-cli にほんご
./Scripts/sumire-cli --categories all わたしはにほんごをにゅうりょくします
./Scripts/sumire-cli --omission かつこう
./Scripts/sumire-cli --list-categories
./Scripts/sumire-cli --categories medical,station --nbest 10 とうきょう
printf '%s\n' にほんご とうきょう | ./Scripts/sumire-cli --categories all --stdin
```

標準出力は JSON、`--stdin` は1入力につき JSON 1行です。AI エージェントからも同じコマンドを利用できます。候補、スコア、辞書種別、UTF-16 の範囲、文節境界、探索完了状態を返します。`--lookup` は読みの完全一致検索です。システム辞書は常に有効、分類は初期状態で無効です。`complete: false` は探索予算への到達を示します。本家の予測・読み訂正・候補統合までの同等性は未達成です。

C ABI の所有権・世代番号・結果の有効期間は `ConversionCore/src/c_api.h` を参照してください。

## ビルドとテスト

iOS の開発環境は Xcode 27.1 / XcodeGen 2.46.0 です。Xcode プロジェクトは `project.yml` から生成し、生成物はコミットしません。

```sh
xcodegen generate
xcodebuild -project Sumire.xcodeproj -scheme Sumire -sdk iphonesimulator \
  -derivedDataPath "$HOME/sumire-build/ios" CODE_SIGNING_ALLOWED=NO build
```

`project.yml` はチェックアウトの隣の `../sumire-data/cli-priority-v1` を辞書リソースとして参照します。`$HOME` 以外へチェックアウトした場合は、その場所に生成資産へのシンボリックリンクを用意するか、リソースパスを変更してください。ビルド時に参照コピーと辞書を自動ダウンロードしません。実機の署名設定は次の手順で行います。

### 正式な実機署名と App Groups

本体 `com.kazumaproject.sumire.ios` と拡張 `com.kazumaproject.sumire.ios.keyboard` を同じ Team で署名し、両方の署名・プロファイルに `group.com.kazumaproject.sumire.ios` が必要です。共有の entitlement は `Shared/Sumire.entitlements` に定義しています。

2026-10-18 に Personal Team で、両方の App Group 対応プロファイルの発行と正式な Release 署名ビルドを確認しました。[Apple の対応表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)でも App groups は Apple Developer 列に対応表示があります。利用中のアカウント・プロファイルでの成立を確認してください。

個人の Team ID は、Git 管理しないローカル設定に保存できます。

```sh
cp project.signing.example.yml project.signing.local.yml
# project.signing.local.yml の YOUR_TEAM_ID を自分の Team ID に変更する
xcodegen generate --spec project.signing.local.yml
```

初回は生成した `Sumire.xcodeproj` を Xcode で開き、`Sumire` と `SumireKeyboard` の両ターゲットで次を確認します。

1. Signing & Capabilities の Automatically manage signing を有効にして、自分の Team を選択する。
2. App Groups に `group.com.kazumaproject.sumire.ios` があることを確認し、Xcode の登録・関連付け・プロファイル更新が完了するまで待つ。[Apple の設定手順](https://developer.apple.com/documentation/xcode/configuring-app-groups)も参照してください。
3. 下記のビルド後、本体と拡張の署名および embedded profile の App Groups を照合する。

今回の確認では、CLI に Team を渡した初回ビルドは App Groups を含まないプロファイルで失敗しました。Xcode で両ターゲットの Team を選択した後に、グループを含むプロファイルが再生成されました。以後は `project.yml` から再生成したプロジェクトでも、CLI の Team 指定で正式署名ビルドが成功しました。

```sh
xcodebuild -project Sumire.xcodeproj -scheme Sumire -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -derivedDataPath "$HOME/sumire-build/ios-device" build

# ローカル設定を使わず project.yml から生成した場合は、上記に
# DEVELOPMENT_TEAM=自分のTeamID を追加する

codesign -d --entitlements :- \
  "$HOME/sumire-build/ios-device/Build/Products/Release-iphoneos/Sumire.app"
codesign -d --entitlements :- \
  "$HOME/sumire-build/ios-device/Build/Products/Release-iphoneos/Sumire.app/PlugIns/SumireKeyboard.appex"
```

同じ2つの bundle の `embedded.mobileprovision` を `security cms -D -i ファイル名` で読み、`Entitlements` の `com.apple.security.application-groups` に同じグループが含まれることも確認します。プロファイル・署名情報はコミットしません。

空の entitlement ファイルを `CODE_SIGN_ENTITLEMENTS` に指定するビルドは、設定共有の検証には使用しません。署名成功後も、実機へ更新し、本体設定が共有領域に保存され、フルアクセスを許可した拡張で候補段数・配色が反映されることを確認する必要があります。未確定入力を確定してから更新してください。共有を省いたビルドを完成版とは扱いません。

次の直接テストは実辞書・端末・署名なしで実行できます。GitHub Actions もこの範囲を対象にします。

```sh
cmake -S ConversionCore -B "$HOME/sumire-build/core-tests" -DCMAKE_BUILD_TYPE=Release
cmake --build "$HOME/sumire-build/core-tests"
ctest --test-dir "$HOME/sumire-build/core-tests" --output-on-failure
swift test --package-path Core --scratch-path "$HOME/sumire-build/swift-core"
python3 Scripts/check_offline.py
```

実辞書の品質比較は `ConversionCore/tests/compare_reference.py`、実資産検証・性能測定は同ディレクトリの対応スクリプトを利用します。Android の候補比較には固定参照、Android SDK と JDK が必要です。参照元との候補一致率を、独立した正解集の正解率とは扱いません。

## 完成に向けた残作業

本家の全入力スタイル・特殊キー、記号／絵文字／顔文字／クリップボード画面、文節変換 UI、候補生成の品質と表示件数、外部辞書 ZIP の取り込み、App Groups の実機共有検証、各種設定の実入力への接続と互換性、実機・iPad 検証が残っています。

メモ等の他アプリでの未確定入力・修正・確定、入力から候補描画までの遅延、拡張の起動・メモリ、長時間試験はそれぞれ実環境で検証します。CLI や本体内テストの成功を、拡張全体の完成とは報告しません。ソースのオフライン検査も、実通信の計測を代替しません。
