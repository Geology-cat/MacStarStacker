# MacStarStacker 開発ガイド（Claude Code 向け）

このファイルは `main` と `macos10.13` の両ブランチに同じ内容で置く。変更したら両ブランチへ反映すること。

## ブランチ構成

| ブランチ | 最低対応OS | アーキテクチャ | 位置づけ |
|---|---|---|---|
| `main` | macOS 14 | Universal（x86_64 + arm64） | 最新OS向け。新しいAPIを使って機能を拡充する |
| `macos10.13` | x86_64: macOS 10.12.6 / arm64: macOS 11 | Universal（x86_64 + arm64） | 古いMac向け。mainの機能をできるだけ追従させる（ブランチ名は10.13のまま） |

- 共通の土台は `e8adfca`（OpenCV・LibRawの自前ビルド化）。ここから2本に分かれている。
- **機能改善・追加・修正は、原則として両ブランチに入れる。**

## 両ブランチに変更を入れる手順

1. `main` で実装・テストしてコミットする（1つの変更を1コミットにまとめると cherry-pick しやすい）。
2. `macos10.13` に切り替えて、そのコミットを cherry-pick する。
   ```bash
   git switch macos10.13
   git cherry-pick <mainのコミット>
   ```
3. `macos10.13` でビルドとテストを行う。最低OSが10.12.6なので、10.12で使えないAPIは**コンパイルエラー**になる
   （Intel のMacでビルドしたとき。Apple シリコンのMacでは arm64 の macOS 11 向けになるため検出されない）。
   エラーになった箇所は下の「macOS 10.12 / 10.13 向けの制約」に従って直し、`git cherry-pick --continue` か追加コミットで対応する。
4. 両ブランチで全テストが通ったことを確認してから push する（失敗したテストがあれば、内容を確かめてから進める）。

守ること:
- **`main` を `macos10.13` へ丸ごとマージしない。** mainでは古いOS向けの分岐を削除しているため、マージすると10.13で必要な処理が消える。
- **`macos10.13` を `main` へマージしない。**
- 片方のブランチにしか入れない変更（例: macOS 14以降のAPIが必須で、10.12では代替できない機能）は、下の「ブランチ間の機能差分」に追記する。
- このファイル（CLAUDE.md）自体を変更したときも、両ブランチに cherry-pick する。

## macOS 10.12 / 10.13 向けの制約（`macos10.13` ブランチ）

- Xcode 14 以降の SwiftPM は、`platforms` に 10.13 より前を書いても 10.13 向けにビルドする。そのため `Package.swift` で
  コンパイラとリンカに対象（`-target x86_64-apple-macosx10.12.6`）を直接指定している。arm64 は `arm64-apple-macosx11.0`。
  ビルドするアーキテクチャは環境変数 `MSS_BUILD_ARCH`（無ければビルドしているMac）で決まる。`build_app.sh` はアーキテクチャごとに
  ビルドして lipo でまとめ、各アーキテクチャの最低OSを確かめる。
- 10.12で使えないAPIは `if #available(macOS XX, *)` で分岐し、古いOS向けの代替処理を用意する。代表例:
  - `UTType` / `allowedContentTypes`（11以降）→ `allowedFileTypes`、UTI文字列（`"public.jpeg"`）
  - `CIImage.oriented(_:)`（10.13以降）→ `oriented(forExifOrientation:)`
  - `NSPasteboard.PasteboardType.fileURL`（10.13以降）→ `NSPasteboard.PasteboardType("public.file-url")`
  - `Process.executableURL`・`run()`（10.13以降）→ 10.13未満は `launchPath`・`launch()`
  - `AVVideoCodecType.h264` / `.hevc`（10.13以降）→ `AVVideoCodecType(rawValue:)`。HEVCの書き出しとHEICの読み込みは10.13以降のみ
  - `CIRAWFilter`（12以降）→ 12未満はLibRawで現像、露出基準は旧来の `CIFilter(imageURL:options:)`
  - `loadViewIfNeeded()`（14以降）→ `_ = view`
  - `contentTintColor`（10.14以降）、ダークモード（10.14以降）
  - Swift Concurrency（async/await・actor、10.15以降）、SwiftUI・Combine（10.15以降）は使わない。並行処理はGCDで書く
- **RAWは常にLibRawで読み込む**（`ImageLoader`・光跡検出の `TrailCleaner.imageLoader`）。古いOSのRAWエンジンは
  新しい機種で失敗せずに小さな埋め込みプレビューを返すことがあるため、`NSImage(contentsOf:)` や `CIImage(contentsOf:)` で
  RAWを読む処理を新しく書かない。
- 重い処理（RAWの現像など）はメインスレッドで行わない。古いMacでは1枚の現像に数秒以上かかる。
- Metalが使えないMacがある（`MetalStacker.create()` が nil を返す）。GPU処理には必ずCPUの代替経路を残す。
- H.265/HEVC の書き出しは `TimelapseSettings.OutputCodec.isAvailable` で使えるか判定する。
- Swiftランタイムをアプリに同梱するため、ビルドには **Xcode 16.x** を使う（新しいXcodeには古いmacOS向けの同梱用ランタイムが無い可能性がある）。

### 対象として想定する最古の環境
- Mac Pro（MacPro5,1、Mid 2010 / Mid 2012）+ macOS 10.13 High Sierra
  - GPUはMetal非対応（CPUでの合成になる）、HEVCのハードウェアエンコーダー無し
  - CPUはXeon（Westmere / Nehalem）。SSE4.2まで対応、**AVXは無い**。x86_64のコードをAVX前提でビルドしない
    （OpenCVの基準命令セットはSSE4.1。`-march=native` 等は使わない）
  - メモリは十分にある（32GB以上）
- カメラ: Canon EOS 6D / EOS 5D Mark IV（CR2）

## ビルド・テスト

依存ライブラリ（OpenCV 4.13.0・LibRaw 0.22.2）は `scripts/build_deps.sh <最低対応OS>` でソースからビルドし、
`MacStarStacker.swiftpm/Vendor/macos<最低対応OS>/` に置く（Git管理外）。ブランチごとに出力先が別なので、切り替えても再ビルド不要。
最低対応OSは `Package.swift` の `deploymentTarget`、`Info.plist` の `LSMinimumSystemVersion`、`build_app.sh` の `DEPLOYMENT_TARGET` の3箇所で揃える。

```bash
# main
scripts/build_deps.sh 14.0
swift test --package-path MacStarStacker.swiftpm

# macos10.13（最低OSは 10.12.6）
scripts/build_deps.sh 10.12.6
swift test --package-path MacStarStacker.swiftpm

# 配布用アプリ・DMG（dist/ に出力。どちらのブランチでも同じ名前になる）
bash MacStarStacker.swiftpm/build_app.sh
```

- 新星景モード（`NightscapeCompositor` / `Nightscape.mm`）を実データで確かめるときは、環境変数を指定して確認用テストを動かす
  （指定しないときはスキップされる）。合成結果（`nightscape.tiff`・`pixels.raw`）と自動判定の結果（`sky_alpha.png`）が書き出される。
  ```bash
  NIGHTSCAPE_SAMPLE_DIR=<RAWのフォルダ> NIGHTSCAPE_OUTPUT_DIR=<書き出し先> NIGHTSCAPE_BASE_INDEX=<基準の番号> \
    swift test --package-path MacStarStacker.swiftpm --filter NightscapeSampleTests/testComposeSampleFolder
  ```
  地上固定フレームを試すときは `NIGHTSCAPE_GROUND_FIXED=<地上固定フレームのパス（カンマ区切り）>` を足す
  （名前に「地上固定」を含むファイルは、指定しないときも Light に含めない）。
- `swift test` はビルドしているMacのアーキテクチャだけで動く。開発用のMacはIntelなので、arm64 版は実行して確認できない。
- 10.12 / 10.13 での実際の動作は、その仮想マシンか実機で確認する必要がある（CIでは実行できない）。

## 使い方ガイド（docs/manual）

- LaTeX（LuaLaTeX・jlreq）で書き、`docs/manual/build.sh` で `docs/MacStarStacker使い方ガイド.pdf` にする。両ブランチで同じ内容にする。
- 画面の説明を変える変更（ボタン・設定項目の追加や文言の変更など）をしたら、`DocumentationScreenshotTests` で
  スクリーンショットを撮り直し（README の「使い方ガイドの作成」）、本文と PDF も直す。撮影は `main` で行う。
- 公開リポジトリなので、スクリーンショットに個人の情報（アカウント名など）を写さない。

## ブランチ間の機能差分

| 項目 | main | macos10.13 |
|---|---|---|
| RAWの読み込み（プレビュー・通常合成・光跡検出・タイムラプス） | macOS のRAWエンジン | 常に LibRaw（撮影時の向きに回転。プレビューはバックグラウンドで読み込む） |
| RAWのプレビュー現像（`RawStackPipeline.render`） | CIRAWFilter（失敗時は LibRaw） | macOS 12以上は main と同じ、12未満は LibRaw |
| RAWの撮影情報 | ImageIO + ExifTool | ImageIO が読めない項目を LibRaw で補完したうえで ExifTool |
| HEVC書き出し | 常に選択可 | ハードウェアエンコーダーがあるMacのみ選択可 |
| Swiftランタイム | OS内蔵 | アプリに同梱（10.14.4未満用） |
| 最低対応OS（x86_64） | macOS 14 | macOS 10.12.6（10.12ではHEICの読み込みとHEVCの書き出しが使えない） |
