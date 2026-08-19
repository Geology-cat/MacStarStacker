# MacStarStacker

星景写真に特化したMacネイティブの画像スタッキング・コンポジットアプリケーションです。
Windows用ソフトウェア「Sequator」のように、星の日周運動を追尾しながら地上の風景を固定して合成する「空と地上の分離」スタッキングを実現します。

macOS 10.12 (Sierra) から 最新の macOS 15+ (Sequoia) まで完全対応しています。

---

## 🌟 主な機能

1. **各社RAW画像・多彩なフォーマットに対応**:
   - Sony (`.arw`), Canon (`.cr2`, `.cr3`), Nikon (`.nef`), Fujifilm (`.raf`), OM System/Olympus (`.orf`), Panasonic (`.rw2`), Pentax (`.pef`), Adobe (`.dng`), TIFF, FITS, JPEG, PNG
2. **レンズプロファイルの自動抽出 & DNG埋め込み**:
   - 基準RAWに紐づくレンズ型番（`LensModel`）、メーカー（`LensMake`）、焦点距離、F値、カラーマトリクスを解析。
   - スタック後の16-bit リニアDNG (Linear RAW) 出力時に、Adobe Camera Raw向けXMPメタデータ（`crs:LensProfileEnable="1"`）を完全埋め込み。Lightroom等で開いた瞬間にレンズ補正が自動適用されます。
3. **比較明合成における飛行機・人工衛星の光跡自動除去 & 流星保護レビュー**:
   - 比較明スタック（スタートレイル）時に、空を横切る飛行機（点滅ストロボ・航跡灯）や人工衛星（直線）を時空間差分と直線検出で自動検出・除去。
   - **流星（流れ星）の救出レビュー機能**: 事前解析により検出された光跡を一覧表示し、流星など残したい光跡をユーザーが確認・選択して保護可能。
4. **空と地上の分離スタッキング**:
   - 直感的なブラシツールで空と地上を塗り分けるだけで、星空は星の動きに合わせてスタックし、地上風景は固定してシームレスに合成。
5. **高精度アライメント (OpenCV)**:
   - AKAZE / ORB 特徴点検出と MAGSAC / RANSAC ホモグラフィ変換により、周辺部の歪みまで高精度に位置合わせ。
6. **キャリブレーションフレーム減算**:
   - ダークフレーム、フラットフレーム、バイアスフレームのマスター生成と自動ノイズ減算。
7. **タイムラプス動画エクスポート**:
   - アライメント・フリッカー除去・オートストレッチ付きの高品質タイムラプス動画（H.264 / HEVC）書き出し。
8. **macOS 10.12 Sierra 〜 最新macOS 完全対応**:
   - 純粋な AppKit / Cocoa UI と GCD（Grand Central Dispatch）による100%安定した動作。

---

## 📁 ディレクトリ構成

```text
MacStarStacker/
├── dist/                              # 配布用バイナリ成果物 (.app, .dmg)
│   ├── MacStarStacker.app
│   └── MacStarStacker.dmg
├── docs/                              # ドキュメント・仕様書・マニュアル
│   ├── specification.md               # アプリケーション詳細仕様書
│   ├── installation_guide.md          # インストール＆起動ガイド (Markdown)
│   ├── installation_guide.html        # インストール＆起動ガイド (HTML)
│   ├── user_manual.html               # ユーザーマニュアル (HTML)
│   ├── インストールと初回起動ガイド.pdf  # PDF形式ガイド
│   └── assets/                        # アイコン・画像素材
├── scripts/                           # 補助スクリプト
│   └── fix_dylib_bundling.py
├── MacStarStacker.swiftpm/            # Swift/C++ ソースコード & ビルド設定
│   ├── Package.swift
│   ├── build_app.sh                   # dist/ にビルド・パッケージングするスクリプト
│   └── Sources/
│       ├── MacSequator/               # AppKit UI, コントローラ, 画像処理エンジン
│       └── OpenCVWrapper/             # OpenCV C++ アライメントラッパー
├── .gitignore
└── README.md
```

---

## 🔨 ビルド方法

### 前提条件
- macOS 10.12 以降
- Xcode Command Line Tools (`xcode-select --install`)
- OpenCV (Homebrew): `brew install opencv`
- ExifTool (推奨): `brew install exiftool`

### アプリケーションおよびDMGのビルド
```bash
cd MacStarStacker.swiftpm
bash build_app.sh
```
ビルドが完了すると、`dist/` 配下に `MacStarStacker.app` および `MacStarStacker.dmg` が自動生成されます。

---

## 📄 ライセンス
Copyright © 2026 MacStarStacker. All rights reserved.
