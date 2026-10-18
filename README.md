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

システム辞書、30分類、英語辞書を変換CLIから検索できます。固定参照のGNKG v3/v4を使う文節候補探索もCLIとC ABIに接続し、設定ON時の文節候補・残り読み確定までInputHarnessで検証しています。これは本家との全操作一致や実キーボード拡張の実機検証を意味しません。各配列の基本入力、候補、学習、設定・編集画面は引き続き開発中です。

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

v5の単独読み優先辞書も検証して`standalone.sud`へ変換します。優先フラグはスコアと独立しており、分類辞書の完全一致はN-best件数とは別に統合します。同点の主候補はUTF-16の表記順です。CLIの`standalone_priority_available`で搭載を確認できます。旧辞書は読めますが、この値がfalseのとき単独読み優先は利用できません。既定の生成処理は文節探索用GNKG v3/v4とMozcの採点資産も、元値を変えずに辞書世代へコピーします。

iOS Simulator/実機ビルドのresource folderは、リポジトリの隣にある`../sumire-data/bunsetsu-search/standard-mozc-scoring-auxiliary-english`です。アプリ用世代は次のように別の空ディレクトリへ生成します（既存世代は上書きしません）。

```sh
python3 Scripts/build_dictionary.py --english --english-reading \
  --output ../sumire-data/bunsetsu-search/standard-mozc-scoring-auxiliary-english
```

入力・出力のハッシュ、出典とライセンス通知は生成先の `manifest.json` と `licenses/` に保存します。各辞書の条件はプログラムのライセンスと別に確認が必要です。特に英語データの適用ライセンスには未確認事項があり、配布条件の確認完了を意味しません。

配列の追従用として JapaneseKeyboard dev `9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93`、変換参照として kotlin-kana-kanji-converter `d5bcefcf613b238966242a2aac3771ef9a18e12d` も使用しています。辞書生成元の固定リビジョンとは区別します。

絵文字・顔文字・記号カタログと肌色差分表も、同じ JapaneseKeyboard `9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93` を使用します。`build_symbol_catalog.py` はGit HEADと入力15ファイルのSHA-256を照合し、出力は指定した新規のリポジトリ外ディレクトリへ生成します。辞書用 `df1f383...` checkoutは切り替えず、記号用の別checkoutを使ってください。

```sh
git clone https://github.com/KazumaProject/JapaneseKeyboard.git /path/to/JapaneseKeyboard-9506
git -C /path/to/JapaneseKeyboard-9506 checkout --detach 9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93
python3 Scripts/build_symbol_catalog.py \
  --source /path/to/JapaneseKeyboard-9506 \
  --output /path/to/new-symbol-catalog-output
```

## CLI

```sh
./Scripts/sumire-cli にほんご
./Scripts/sumire-cli --categories all わたしはにほんごをにゅうりょくします
./Scripts/sumire-cli --omission かつこう
./Scripts/sumire-cli --list-categories
./Scripts/sumire-cli --categories medical,station --nbest 10 とうきょう
./Scripts/sumire-cli --bunsetsu きょうはとうきょうにいきます
printf '%s\n' にほんご とうきょう | ./Scripts/sumire-cli --categories all --stdin
```

標準出力は JSON、`--stdin` は1入力につき JSON 1行です。AI エージェントからも同じコマンドを利用できます。候補、スコア、辞書種別、UTF-16 の範囲、文節境界、探索完了状態を返します。`--lookup` は読みの完全一致検索です。`--bunsetsu` は固定GNKG v3/v4とMozc採点資産を使う専用候補探索です。システム辞書は常に有効、分類は初期状態で無効です。`complete: false` は探索予算または必要な文節資産がない状態を示します。本家の予測・読み訂正・候補統合までの同等性は未達成です。

C ABI の所有権・世代番号・結果の有効期間は `ConversionCore/src/c_api.h` を参照してください。

変換コアのhost benchmarkは同一の辞書・入力で実行し、集計値と入力別のp50/p95/p99、辞書manifestとCLIのSHA-256を出力します。`--categories none|all` で分類辞書を切り替え、`--disable-standalone-priority` で優先候補テーブルの効果を分けられます。`--omission` と `--predict-japanese` はそれぞれ省略入力・予測経路を測ります。

```sh
python3 ConversionCore/tests/benchmark.py \
  --cli "$HOME/sumire-build/release/sumire-cli" \
  --data "$HOME/sumire-data/cli-priority-v1" \
  --categories all --iterations 500
```

この測定はhost上の変換コア時間です。iOSのキーボード拡張、実機の入力遅延、OS cold-cacheや`phys_footprint`の測定値として扱いません。

## ビルドとテスト

iOS の開発環境は Xcode 27.1 / XcodeGen 2.46.0 です。Xcode プロジェクトは `project.yml` から生成し、生成物はコミットしません。

```sh
xcodegen generate
xcodebuild -project Sumire.xcodeproj -scheme Sumire -sdk iphonesimulator \
  -derivedDataPath "$HOME/sumire-build/ios" CODE_SIGNING_ALLOWED=NO build
```

`project.yml` はチェックアウトの隣の `../sumire-data/bunsetsu-search/standard-mozc-scoring-auxiliary-english` を辞書リソースとして参照します。前節のコマンドで生成してからXcodeGenを実行してください。`$HOME` 以外へチェックアウトした場合は、同じ相対位置へ生成するか、リソースパスを変更してください。ビルド時に参照コピーと辞書を自動ダウンロードしません。実機の署名設定は次の手順で行います。

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

空の entitlement ファイルを `CODE_SIGN_ENTITLEMENTS` に指定するビルドは、設定共有の検証には使用しません。拡張はフルアクセスOFFでも本体の共有設定・ユーザー辞書を読み取り、キーボード内で変更したサイズ・最後の配列などは拡張の私有領域へ保存します。本体で同じ項目を変更すると、その項目の古い私有値を取り除きます。署名成功後も、実機へ更新し、フルアクセスOFFのまま候補段数・配色の反映と拡張内変更の保存を確認する必要があります。学習・クリップボードの一括削除は、本体の共有データを削除した後、次に拡張を開いたときに私有データへも適用します。未確定入力を確定してから更新してください。共有を省いたビルドを完成版とは扱いません。

次の直接テストは実辞書・端末・署名なしで実行できます。GitHub Actions もこの範囲を対象にします。

```sh
cmake -S ConversionCore -B "$HOME/sumire-build/core-tests" -DCMAKE_BUILD_TYPE=Release
cmake --build "$HOME/sumire-build/core-tests"
ctest --test-dir "$HOME/sumire-build/core-tests" --output-on-failure
swift test --package-path Core --scratch-path "$HOME/sumire-build/swift-core"
python3 Scripts/check_offline.py
```

実辞書の候補比較は `ConversionCore/tests/compare_reference.py` で行います。最初の実行では、Android SDK と JDK を使って固定リビジョンの `KanaKanjiEngine.getCandidatesWithoutPrediction` から19読み×「分類なし／全分類」の38ケースを生成します。以後は同じ辞書・基準ファイルを指定して比較だけを再実行できます。

```sh
python3 ConversionCore/tests/compare_reference.py \
  --source .reference/JapaneseKeyboard \
  --cli ../sumire-build/conversion-quality/sumire-cli \
  --data ../sumire-data/cli-priority-v1 \
  --output ../sumire-validation/conversion-quality

python3 ConversionCore/tests/compare_reference.py \
  --cli ../sumire-build/conversion-quality/sumire-cli \
  --data ../sumire-data/cli-priority-v1 \
  --baseline ../sumire-validation/conversion-quality/baseline.jsonl \
  --output ../sumire-validation/conversion-quality-rerun
```

`ConversionCore/tests/reference/quality-policy.json` は、Android revision・adapter hash・baseline SHA-256・変換辞書 manifest hash と合格閾値を固定します。38件すべての探索完了、Top-1候補一致が36/38以上、Top-10候補リスト完全一致が36/38以上、参照元のTop-1候補がC++のTop-10に含まれる件数が38/38であることを合格条件とします。これは固定したAndroid経路との一致度であり、独立した実利用正解率ではありません。この評価集では予測、省略検索、ユーザー辞書、学習を無効にしており、それらの品質評価は別途必要です。入力別比較と合否レポートは指定した出力先だけに保存します。CTestにはrevision・ケース構成・hash・閾値の拒否テストも含みます。

実資産の検証・性能測定は同ディレクトリの対応スクリプトを利用します。参照元との候補一致率を、独立した正解集の正解率とは扱いません。

## 完成に向けた残作業

文節変換はInputHarnessの1ケースで先頭候補・残り読みの確定まで確認しましたが、本家の候補巡回や編集状況ごとの全遷移、実キーボード拡張での動作は未検証です。本家の全入力スタイル・特殊キー、記号／絵文字／顔文字／クリップボード画面、候補生成の品質と表示件数、外部辞書 ZIP の取り込み、App Groups の実機共有検証、各種設定の実入力への接続と互換性、実機・iPad 検証も残っています。

メモ等の他アプリでの未確定入力・修正・確定、入力から候補描画までの遅延、拡張の起動・メモリ、長時間試験はそれぞれ実環境で検証します。CLI や本体内テストの成功を、拡張全体の完成とは報告しません。ソースのオフライン検査も、実通信の計測を代替しません。
