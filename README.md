# MacStarStacker

星景写真に特化したMacネイティブの画像スタッキング・コンポジットアプリケーションです。
Windows用ソフトウェア「Sequator」のように、星の日周運動を追尾しながら地上の風景を固定して合成する「空と地上の分離」スタッキングを実現します。

macOS 14 (Sonoma) 以降に対応しています（macOS 15.7でビルド・検証）。
配布DMGはUniversal版（Apple Silicon / Intel のどちらでもネイティブ動作）です。

> macOS 10.13 (High Sierra) 以降に対応した版は `macos10.13` ブランチで開発しています。

---

## 🌟 主な機能

1. **各社RAW画像・多彩なフォーマットに対応**:
   - Sony (`.arw`), Canon (`.cr2`, `.cr3`), Nikon (`.nef`), Fujifilm (`.raf`), OM System/Olympus (`.orf`), Panasonic (`.rw2`), Pentax (`.pef`), Adobe (`.dng`), TIFF, FITS, JPEG, PNG
2. **3つの合成方式とRAWのままの合成**:
   - 平均（ノイズ低減）・中央値・比較明（スタートレイル）で合成。
   - 全フレームがベイヤー配列のRAWなら、現像せずにセンサーデータのまま合成し、RAW (DNG) で書き出せます（ほかに16bit TIFF・32bit FITS・JPEG）。
3. **星だけを使った位置合わせ（アライメント）**:
   - 点光源（星）だけを検出し、星どうしの対応からホモグラフィを求めて位置合わせします。岩肌・木々・灯りなど地上の模様には合わせないため、固定撮影でも追尾撮影でも星が正しく重なります。
   - 空・地上マスクを描いた場合は、空の中の星だけで位置合わせします。
   - 比較明合成でも選べます（比較明合成の既定はOFF。ONにすると星は軌跡ではなく点になります）。
4. **空と地上の分離スタッキング**:
   - 機能をONにしたときだけ有効になるブラシツールで空と地上を塗り分け、星空は星に合わせて、地上風景は固定して合成。
   - 境界ぼかしを0〜100 pxで調整可能（0 pxで無効）。
5. **比較明合成における飛行機・人工衛星の光跡自動除去 & 流星保護レビュー**:
   - 比較明スタック時に、空を横切る飛行機（点滅ストロボ・航跡灯）や人工衛星（直線）を、時間方向の中央値/MAD・画像別ノイズ床・直線支持率・線方向の輝度積算などで検出して除去します。
   - **流星の救出レビュー**: 候補を一覧で確認し、流星など残したい光跡を保護できます。
6. **キャリブレーションフレーム減算**:
   - ダーク・フラット・バイアスフレームのマスター生成と自動減算。
7. **レンズプロファイルの自動抽出 & DNG埋め込み**:
   - 基準RAWのレンズ型番・メーカー・焦点距離・F値・カラーマトリクスを解析し、DNG書き出し時にAdobe Camera Raw向けのXMPメタデータ（`crs:LensProfileEnable="1"`）を埋め込みます。
8. **タイムラプス動画エクスポート（H.264 / HEVC）**:
   - 位置合わせを「なし／地上に合わせる（揺れ補正）／星に合わせる（星を固定）」から選択。どちらも最初のフレームに揃えます。
   - フリッカー除去・オートストレッチ・解像度（オリジナル／4K／1080p／720p）。
   - 再生速度はFPS指定・秒数指定のどちらでも、スライダーか数値の直接入力で指定できます。

### プレビューの操作
- 画像をドラッグしてつかんで動かします（マスク編集中は Space か Option を押しながらドラッグ）。
- ズームは −／＋ ボタン、Cmd＋スクロール、トラックパッドのピンチ（0.25〜10倍）。1:1 で元に戻します。
- Auto Stretch（表示用の明るさ持ち上げ）は既定でOFF。
- プレビューに表示中のファイルは、左のファイルリストで選択表示（太字・左端の帯）になります。

---

## 📁 ディレクトリ構成

```text
MacStarStacker/
├── dist/                              # 配布用バイナリ成果物 (.app, .dmg)
│   ├── MacStarStacker.app
│   └── MacStarStacker.dmg
├── docs/                              # ドキュメント（作り直し予定）
│   └── assets/                        # アイコン・画像素材
├── scripts/                           # 補助スクリプト
│   └── build_deps.sh                  # OpenCV・LibRawをUniversal静的ライブラリとしてビルド
├── MacStarStacker.swiftpm/            # Swift/C++ ソースコード & ビルド設定
│   ├── Package.swift
│   ├── build_app.sh                   # dist/ にビルド・パッケージングするスクリプト
│   ├── Vendor/                        # build_deps.sh の出力先（Git管理外）
│   └── Sources/
│       ├── MacSequator/               # AppKit UI, コントローラ, 画像処理エンジン
│       ├── OpenCVWrapper/             # OpenCV C++ ラッパー（星の位置合わせ・タイムラプスの揺れ補正・光跡除去）
│       └── LibRawBridge/              # LibRaw C ブリッジ（RAWのセンサーデータ読み込み・デモザイク）
├── CLAUDE.md                          # 開発手順（main と macos10.13 の両ブランチへの反映方法など）
├── .gitignore
└── README.md
```

---

## 🔨 ビルド方法

### 前提条件
- macOS 14 以降
- Xcode 16 以降（`xcode-select` でXcode本体を選択しておく）
- CMake・Ninja（依存ライブラリのビルド用）: `brew install cmake ninja`
- ExifTool (推奨): `brew install exiftool`

OpenCV 4.13.0 と LibRaw 0.22.2 は、`scripts/build_deps.sh` が公式GitHubからソースを取得し、
Universal（x86_64 + arm64）の静的ライブラリとして `MacStarStacker.swiftpm/Vendor/` にビルドします
（初回のみ数分〜十数分。以降はビルド済みのものを再利用）。Homebrew版のOpenCV・LibRawは使いません。

### 開発時のビルド・テスト
```bash
scripts/build_deps.sh 14.0
swift test --package-path MacStarStacker.swiftpm
```

### アプリケーションおよびDMGのビルド
```bash
cd MacStarStacker.swiftpm
bash build_app.sh
```
ビルドが完了すると、`dist/` 配下に `MacStarStacker.app` および `MacStarStacker.dmg` が自動生成されます。

---

## 📄 ライセンス
Copyright © 2026 MacStarStacker. All rights reserved.
